#!/usr/bin/env bash
set -euo pipefail

echo "=== Déploiement du workflow de mise à jour Hister ==="

if [ "$EUID" -ne 0 ]; then
    echo "Erreur : ce script doit être exécuté avec les droits root." >&2
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# 1. Vérification / Création du fichier config.json
if [ ! -f /usr/local/bin/config.json ]; then
    if [ -f "$SCRIPT_DIR/config.json.example" ]; then
        echo "Création de /usr/local/bin/config.json depuis le modèle..."
        cp "$SCRIPT_DIR/config.json.example" /usr/local/bin/config.json
        chmod 600 /usr/local/bin/config.json
        echo "⚠️ Pensez à éditer /usr/local/bin/config.json avec vos identifiants ntfy."
    fi
else
    echo "Fichier de configuration existant conservé (/usr/local/bin/config.json)."
fi

# 2. Installation du script exécutable
echo "Installation de update-hister.sh dans /usr/local/bin/..."
install -m 755 "$SCRIPT_DIR/update-hister.sh" /usr/local/bin/update-hister.sh

# 3. Installation des unités systemd
echo "Installation des unités systemd..."
install -m 644 "$SCRIPT_DIR/systemd/hister-update.service" /etc/systemd/system/hister-update.service
install -m 644 "$SCRIPT_DIR/systemd/hister-update.timer" /etc/systemd/system/hister-update.timer

# 4. Activation du timer
echo "Activation et rechargement de Systemd..."
systemctl daemon-reload
systemctl enable --now hister-update.timer

echo "=== Installation terminée avec succès ==="
systemctl list-timers hister-update.timer
