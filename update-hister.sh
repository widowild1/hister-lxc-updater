#!/usr/bin/env bash
set -euo pipefail

# 1. Verrouillage d'exécution concurrente (flock)
LOCKFILE="/var/lock/hister-update.lock"
mkdir -p "$(dirname "$LOCKFILE")"
exec 200>"$LOCKFILE"
if ! flock -n 200; then
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] Une autre instance est déjà active. Sortie."
    exit 0
fi

# 2. Environnement et chemins (gestion du cache Go en non-interactif)
export HOME="${HOME:-/root}"
export GOPATH="${GOPATH:-$HOME/go}"
export PATH="/usr/local/go/bin:/usr/bin:/bin:/usr/local/bin:$GOPATH/bin:$PATH"

REPO_DIR="/tmp/hister"
REPO_URL="https://github.com/asciimoo/hister.git"
TARGET_BIN="$(command -v hister 2>/dev/null || echo "/usr/local/bin/hister")"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${CONFIG_FILE:-$SCRIPT_DIR/config.json}"

REQUIRED_PKGS=(git curl build-essential golang nodejs jq)
REQUIRED_BINS=(git curl gcc go node npm jq)

log() {
    local msg="[$(date '+%Y-%m-%d %H:%M:%S')] $*"
    echo "$msg"
    logger -t hister-update "$*" 2>/dev/null || true
}

SUDO=""
if [ "$EUID" -ne 0 ]; then
    SUDO="sudo"
fi

# 3. Sécurisation et lecture de config.json
if [ ! -f "$CONFIG_FILE" ]; then
    log "Erreur critique : fichier de configuration '$CONFIG_FILE' introuvable." >&2
    exit 1
fi
chmod 600 "$CONFIG_FILE" 2>/dev/null || true

get_json_val() {
    local key="$1"
    if command -v jq >/dev/null 2>&1; then
        jq -r ".$key // empty" "$CONFIG_FILE"
    else
        grep -oP '"'"$key"'"\s*:\s*"\K[^"]*' "$CONFIG_FILE" || true
    fi
}

NTFY_URL=$(get_json_val "ntfy_url")
NTFY_TOKEN=$(get_json_val "ntfy_token")
HEALTHCHECK_URL=$(get_json_val "healthcheck_url")
HEALTHCHECK_URL="${HEALTHCHECK_URL:-https://127.0.0.1:4433/}"

# 4. Contrôle d'espace disque (minimum 1 Go disponible sur /tmp)
FREE_DISK_MB=$(df -m /tmp | awk 'NR==2 {print $4}')
if [ "$FREE_DISK_MB" -lt 1024 ]; then
    log "Erreur critique : espace disque insuffisant sur /tmp (${FREE_DISK_MB} Mo libres, 1024 Mo minimum requis)." >&2
    exit 1
fi

# 5. Procédure de rollback et capture des erreurs
rollback() {
    log "Rollback enclenché..."
    if [ -f "${TARGET_BIN}.bak" ]; then
        log "Restauration de la version de secours ${TARGET_BIN}.bak..."
        $SUDO install -m 755 "${TARGET_BIN}.bak" "$TARGET_BIN"
        $SUDO systemctl restart hister || true
        log "Restauration effectuée."
    else
        log "Aucun binaire .bak disponible pour le rollback."
    fi
}

notify_error() {
    local line="$1"
    local exit_code="$2"
    log "Erreur critique à la ligne $line (code sortie : $exit_code)."
    rollback

    if [ -n "$NTFY_URL" ]; then
        local auth=()
        [ -n "$NTFY_TOKEN" ] && auth=(-H "Authorization: Bearer $NTFY_TOKEN")
        curl -s "${auth[@]}"             -H "Title: Échec mise à jour hister"             -H "Priority: high"             -H "Tags: warning,x"             -d "Échec de mise à jour sur $(hostname) (ligne $line, code $exit_code). Rollback automatique appliqué."             "$NTFY_URL" >/dev/null 2>&1 || true
    fi
}
trap 'notify_error $LINENO $?' ERR

# 6. Vérification Git rapide sur master
if [ ! -d "$REPO_DIR/.git" ]; then
    log "Dépôt absent de /tmp, clonage initial..."
    rm -rf "$REPO_DIR"
    git clone --branch master --single-branch "$REPO_URL" "$REPO_DIR"
    cd "$REPO_DIR"
    OLD_COMMIT="none"
else
    cd "$REPO_DIR"
    git checkout master --quiet
    OLD_COMMIT=$(git rev-parse HEAD 2>/dev/null || echo "none")
    log "Vérification des nouveaux commits..."
    git pull origin master --quiet
fi

NEW_COMMIT=$(git rev-parse HEAD 2>/dev/null || echo "none")

if [ -f "./hister" ] && [ -f "$TARGET_BIN" ] && [ "$OLD_COMMIT" = "$NEW_COMMIT" ]; then
    log "Binaire à jour et aucun commit neuf : aucune action requise."
    exit 0
fi

log "Nouvelle version détectée (commit ${NEW_COMMIT:0:7}). Début des opérations..."

# 7. Mise à niveau du système d'exploitation et dépendances
if command -v apt-get >/dev/null 2>&1; then
    log "Mise à niveau complète du système (apt upgrade)..."
    export DEBIAN_FRONTEND=noninteractive
    $SUDO apt-get update -qq
    $SUDO apt-get upgrade -y -qq         -o Dpkg::Options::="--force-confdef"         -o Dpkg::Options::="--force-confold"
    $SUDO apt-get install -y -qq --no-install-recommends "${REQUIRED_PKGS[@]}"
else
    for bin in "${REQUIRED_BINS[@]}"; do
        if ! command -v "$bin" >/dev/null 2>&1; then
            log "Erreur : outil requis '$bin' introuvable." >&2
            exit 1
        fi
    done
fi

# 8. Audit et correction préventive npm
NPM_VULN_STATUS=""
while IFS= read -r pkg_json; do
    pkg_dir="$(dirname "$pkg_json")"
    log "Analyse des vulnérabilités npm dans $pkg_dir..."
    (
        cd "$pkg_dir"
        if ! npm audit --omit=dev > /tmp/npm_audit.log 2>&1; then
            log "Vulnérabilités npm détectées. Tentative d'auto-correction (npm audit fix)..."
            npm audit fix --omit=dev 2>/dev/null || true
            NPM_VULN_STATUS=" (vulnérabilités npm auditées)"
        fi
    )
done < <(find "$REPO_DIR" -maxdepth 2 -name "package.json")

# 9. Compilation de hister
cd "$REPO_DIR"
log "Compilation de l'application..."
if [ ! -f "./manage.sh" ]; then
    log "Erreur : ./manage.sh introuvable." >&2
    exit 1
fi
./manage.sh build

# 10. Sauvegarde et remplacement atomique de l'exécutable
if [ -f "$TARGET_BIN" ]; then
    log "Sauvegarde du binaire existant (${TARGET_BIN}.bak)..."
    $SUDO cp "$TARGET_BIN" "${TARGET_BIN}.bak"
fi

log "Installation du nouveau binaire dans $TARGET_BIN..."
$SUDO install -m 755 ./hister "$TARGET_BIN"

# 11. Redémarrage du service et contrôle applicatif
log "Redémarrage du service hister..."
$SUDO systemctl restart hister
sleep 2

if ! systemctl is-active --quiet hister; then
    log "Échec : hister.service n'est pas actif."
    exit 1
fi

log "Exécution du healthcheck applicatif sur $HEALTHCHECK_URL..."
HEALTHCHECK_OK=false
HTTP_CODE="000"
for i in {1..6}; do
    HTTP_CODE=$(curl -k -s -o /dev/null -w "%{http_code}" "$HEALTHCHECK_URL" || echo "000")
    if [[ "$HTTP_CODE" =~ ^(200|301|302|303|307|308|401|403)$ ]]; then
        HEALTHCHECK_OK=true
        break
    fi
    sleep 2
done

if [ "$HEALTHCHECK_OK" = false ]; then
    log "Échec : hister ne répond pas correctement ($HEALTHCHECK_URL a retourné le code HTTP $HTTP_CODE)."
    exit 1
fi

# 12. Nettoyage des résidus post-compilation
log "Nettoyage des caches et résidus..."
if command -v apt-get >/dev/null 2>&1; then
    $SUDO apt-get autoremove -y -qq
    $SUDO apt-get clean
fi
go clean -cache 2>/dev/null || true

# 13. Contrôle de redémarrage système
REBOOT_NOTE=""
if [ -f "/var/run/reboot-required" ]; then
    REBOOT_NOTE=" ⚠️ Redémarrage système requis."
fi

# 14. Notification ntfy de succès
log "Envoi de la notification de succès..."
SHORT_HASH="${NEW_COMMIT:0:7}"
AUTH_HEADER=()
[ -n "$NTFY_TOKEN" ] && AUTH_HEADER=(-H "Authorization: Bearer $NTFY_TOKEN")

curl -s     "${AUTH_HEADER[@]}"     -H "Title: Mise à jour hister réussie"     -H "Priority: default"     -H "Tags: white_check_mark,package"     -d "Hister mis à jour avec succès sur $(hostname) (commit ${SHORT_HASH})${NPM_VULN_STATUS}.${REBOOT_NOTE}"     "$NTFY_URL" >/dev/null 2>&1 || log "Avertissement : échec d'envoi ntfy."

log "Mise à jour terminée avec succès."
"$TARGET_BIN" --version 2>/dev/null || true
