# NetSwitch Pro

**Gestionnaire de profils réseau IP pour Windows**

Changez instantanément de configuration IP (adresse statique, masque, passerelle, DNS) en un clic. Idéal pour les techniciens IT, développeurs et utilisateurs multi-réseaux.

![Windows](https://img.shields.io/badge/Windows-10%2F11-0078D4?style=flat)
![Admin requis](https://img.shields.io/badge/admin-requis-red?style=flat)
![Thème sombre](https://img.shields.io/badge/theme-dark-222222?style=flat)

---

## Fonctionnalités

- **Profils réseau** — Créez et gérez autant de profils IP statiques que nécessaire (IP, masque, passerelle, DNS primaire/secondaire)
- **Groupes** — Organisez vos profils en groupes, renommez-les, supprimez-les
- **Application en 1 clic** — Double-clic sur un profil pour l'appliquer immédiatement
- **Bouton DHCP rapide** — Repassez en DHCP sur n'importe quelle carte réseau en un clic depuis la sidebar
- **Rollback automatique** — La config précédente est sauvegardée avant chaque apply, un bouton `↩ Rollback` apparaît dans la barre de statut pour restaurer en cas de problème
- **Icône system tray** — Tourne en arrière-plan, appliquez un profil sans ouvrir l'app
- **Historique** — Conserve les 20 derniers profils appliqués
- **Import / Export** — Partagez vos profils via JSON
- **Mise à jour automatique** — Vérifie les nouvelles versions sur GitHub au démarrage
- **Thème sombre** — Interface personnalisée vert/noir

---

## Installation

1. Téléchargez `NetSwitchPro.exe` depuis la page [Releases](https://github.com/Nothinx-44/NetSwitch-Pro/releases)
2. Double-cliquez sur **`NetSwitchPro.exe`**
3. Acceptez l'élévation UAC (droits administrateur requis)

> Aucune installation requise — exécutable autonome.

---

## Utilisation

| Action | Comment |
|--------|---------|
| Créer un profil | Clic sur **+ Nouveau client**, remplir les champs, **Enregistrer** |
| Appliquer un profil | Double-clic sur le client dans la liste, ou sélectionner + **Appliquer maintenant** |
| Importer la config actuelle | Sélectionner la carte réseau, clic sur **Importer config actuelle** |
| Passer en DHCP | Sélectionner la carte dans le dropdown sidebar, clic sur **→ DHCP** |
| Rollback | Clic sur **↩ Rollback** dans la barre de statut après un apply |
| Groupes | Clic sur **+ Groupe**, assigner un client via le champ Groupe du formulaire |
| Fermer | La fenêtre se minimise dans le tray — clic droit sur l'icône pour quitter |

---

## Données

Les profils sont stockés dans `%APPDATA%\NetSwitchPro\` :
- `clients.json` — profils réseau
- `groups.json` — groupes
- `history.json` — historique des 20 derniers applies

> Si vous veniez d'une version précédente, vos données sont migrées automatiquement au premier lancement.

---

## Prérequis

- Windows 10 / 11
- Droits administrateur

---

## Compilation depuis les sources

```powershell
# Installer PS2EXE
Install-Module -Name PS2EXE -Scope CurrentUser

# Compiler
Invoke-PS2EXE -InputFile "NetSwitchPro.ps1" -OutputFile "NetSwitchPro.exe" `
              -Title "NetSwitch Pro" -Version "1.2.0.0" `
              -RequireAdmin -NoConsole -DPIAware
```

---

## Auteur

**Nothinx-44** — [github.com/Nothinx-44/NetSwitch-Pro](https://github.com/Nothinx-44/NetSwitch-Pro)
