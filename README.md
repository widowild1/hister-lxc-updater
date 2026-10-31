# Hister Updater for Proxmox LXC

Solution d'automatisation durcie pour la mise à jour continue, la compilation et la maintenance du moteur de recherche personnel [Hister](https://github.com/asciimoo/hister) au sein d'un conteneur LXC Debian/Ubuntu sous Proxmox VE.

---

## 🌟 Fonctionnalités

- **Mise à jour incrémentale intelligente** : Vérifie l'état de la branche `master` et interrompt immédiatement l'exécution sans impact système si aucun nouveau commit n'est détecté.
- **Maintenance système intégrée** : Actualisation des dépôts APT et mise à niveau non-interactive (`apt-get upgrade`) avec résolution des conflits de paquets (NodeSource / npm).
- **Contrôle de sécurité préventif** : Détection des vulnérabilités npm (`npm audit`) et tentative de remédiation automatique avant compilation.
- **Gestion des ressources LXC** : Vérification stricte de l'espace disque disponible sur `/tmp` (seuil de 1 Go) et nettoyage post-build des caches (`go clean`, `apt autoremove`).
- **Verrouillage d'exécution (`flock`)** : Empêche toute exécution concurrente risquant de corrompre l'arborescence de build.
- **Remplacement atomique & Downtime zéro** : Déploiement sans conflit *Text file busy* via `install -m 755` et redémarrage propre.
- **Auto-guérison & Rollback** : Restauration automatique du binaire précédent (`.bak`) en cas d'erreur de compilation, de crash systemd ou d'échec du healthcheck HTTP/HTTPS.
- **Healthcheck applicatif tolérant** : Vérification HTTP/HTTPS sur le port configuré (supporte les certificats auto-signés et les redirections 3xx / 401).
- **Notifications instantanées (ntfy)** : Alertes de succès et d'échec enrichies (hash de commit, tags, priorités, alerte de reboot requis si `/var/run/reboot-required` est présent).
- **Ordonnancement robuste (Systemd Timer)** : Remplacement de cron avec rattrapage automatique (`Persistent=true`) et journalisation centralisée dans `journald`.

---

## 📂 Structure du dépôt

```text
.
├── config.json.example            # Modèle de configuration (ntfy, healthcheck)
├── update-hister.sh              # Script principal de mise à jour durci
├── systemd/
│   ├── hister-update.service     # Définition du service Systemd oneshot
│   └── hister-update.timer       # Planificateur quotidien Systemd (03:00)
├── install.sh                    # Script d'installation automatique
├── .gitignore                    # Fichiers exclus du versionnement
└── README.md                     # Documentation complète
```

---

## ⚙️ Prérequis

- Un conteneur LXC Proxmox VE sous **Debian 12+** ou **Ubuntu 22.04+**.
- Droits `root` (ou utilisateur avec privilèges `sudo`).
- Go et Node.js installés (ou laissés au script qui les installera via APT).
- Instance ou topic [ntfy](https://ntfy.sh) configuré.

---

## 🚀 Installation rapide

### 1. Cloner le dépôt dans le conteneur LXC

```bash
git clone https://github.com/<votre-user>/hister-lxc-updater.git /root/hister-lxc-updater
cd /root/hister-lxc-updater
```

### 2. Configurer les paramètres

Copiez le modèle de configuration vers `/usr/local/bin/config.json` et restreignez ses permissions :

```bash
cp config.json.example /usr/local/bin/config.json
chmod 600 /usr/local/bin/config.json
nano /usr/local/bin/config.json
```

Exemple de contenu :
```json
{
  "ntfy_url": "https://ntfy.sh/mon_topic_secret",
  "ntfy_token": "",
  "healthcheck_url": "https://127.0.0.1:4433/"
}
```

> **Note :** Si vous utilisez le port HTTPS par défaut avec un certificat interne, `healthcheck_url` doit débuter par `https://`. Le script accepte automatiquement les certificats auto-signés.

### 3. Exécuter le script d'installation

```bash
chmod +x install.sh
sudo ./install.sh
```

Le script d'installation :
1. Copie `update-hister.sh` dans `/usr/local/bin/` avec les droits `755`.
2. Déploie `hister-update.service` et `hister-update.timer` dans `/etc/systemd/system/`.
3. Recharge le démon systemd et active le timer quotidien.

---

## 🧪 Tests et Exploitation

### Lancer un test manuel immédiat

```bash
sudo systemctl start hister-update.service
```

### Suivre l'exécution en direct

```bash
journalctl -u hister-update.service -f
# Ou via l'identifiant logger système :
journalctl -t hister-update -f
```

### Vérifier le statut du planificateur

```bash
systemctl list-timers hister-update.timer
```

---

## 🛠️ Dépannage fréquent

| Symptôme | Cause probable | Résolution |
|---|---|---|
| `go: module cache not found: neither GOMODCACHE nor GOPATH is set` | Systemd s'exécute sans variable `$HOME`. | Assurez-vous que `Environment="HOME=/root"` est présent dans `hister-update.service`. |
| `nodejs Conflicts npm` | Conflit entre le paquet NodeSource et Debian `npm`. | `update-hister.sh` n'installe que `nodejs` (qui embarque déjà `npm`). |
| Échec healthcheck sur port 4433 | Hister écoute en HTTPS avec certificat auto-signé. | Spécifier `https://` dans `config.json`. Le script utilise `curl -k` pour accepter le certificat. |
| Sortie immédiate sans log | Le binaire est déjà au dernier commit. | Comportement normal. Pour forcer un rebuild de test : `rm -f /tmp/hister/hister`. |

---

## 📄 Licence

Ce projet est sous licence MIT. Libre à vous de le redistribuer et de l'adapter à vos besoins.
