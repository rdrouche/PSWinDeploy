# PSWinDeploy

**Un remplacement moderne de MDT, écrit en PowerShell.**
Déploiement Windows de bout en bout depuis WinPE : partitionnement, application du WIM, injection des drivers, puis post-installation pilotée par séquences — le tout supervisé depuis une interface web.

![PowerShell](https://img.shields.io/badge/PowerShell-5.1-5391FE?logo=powershell&logoColor=white)
![Windows](https://img.shields.io/badge/Windows-WinPE%20%7C%2010%2B-0078D6?logo=windows&logoColor=white)
![Docker](https://img.shields.io/badge/Web%20UI-Docker-2496ED?logo=docker&logoColor=white)
![Version](https://img.shields.io/badge/version-0.6.9-f0a830)

> ⚠️ **Projet en développement actif.** PSWinDeploy est fonctionnel et utilisé en environnement de test, mais l'API et certains formats peuvent encore évoluer. À éprouver avant toute mise en production.

---

## Pourquoi ?

MDT n'est plus activement développé, repose sur des composants vieillissants et reste difficile à versionner ou à automatiser proprement. PSWinDeploy repart d'une base simple et lisible :

- **Tout est du PowerShell 5.1** (présent nativement sur Windows, aucun runtime à installer).
- **Configuration en clair** (`.psd1` versionnables, séquences lisibles, pas de base de données opaque).
- **Partages SMB standard** pour les images, drivers, logiciels et scripts.
- **Une interface web** pour suivre les déploiements, gérer le catalogue d'applications et les séquences, et consulter des statistiques.

---

## Architecture en deux phases

Le déploiement est découpé en deux temps distincts, ce qui simplifie le débogage et le suivi.

```
   PHASE 1 — WinPE (Start-Deploy.ps1)        PHASE 2 — Windows (moteur de séquences)
   ┌──────────────────────────────┐          ┌──────────────────────────────────┐
   │ • Sélection du disque         │          │ • Jonction domaine (optionnelle)  │
   │ • Partitionnement / format    │   reboot │ • Windows Update                  │
   │ • Application du WIM           │ ───────► │ • Installation des logiciels      │
   │ • Injection des drivers       │          │ • Scripts de configuration        │
   │ • Préparation phase 2         │          │ • Assistant interactif (option)   │
   └──────────────────────────────┘          └──────────────────────────────────┘
              │                                            │
              └───────────── heartbeats ───────────────────┘
                                  ▼
                       API Pode  ◄────►  Interface web (Docker)
                  (source de vérité)      Suivi · Stats · Catalogue
```

- **Phase 1** s'occupe de tout ce qui précède le premier démarrage de Windows.
- **Phase 2** est pilotée par une **séquence** (`.psd1`) : une liste d'étapes typées (jonction domaine, logiciels, scripts…).
- Les deux phases envoient des **heartbeats** à l'API, qui alimentent le suivi temps réel et les statistiques.

---

## Composants

| Composant | Rôle |
|-----------|------|
| **Console PowerShell** (`PSWinDeploy-Console.ps1`) | Centre de contrôle côté serveur : santé, vault, séquences, drivers, build WinPE, HTTPS. |
| **API Pode** (`API/Deploy-API.ps1`) | API REST : sert le catalogue, les séquences, reçoit les heartbeats, historise. Source de vérité. |
| **Interface web** (`Web/`, Docker) | Suivi des déploiements, statistiques, édition du catalogue d'applications et des séquences. |
| **Moteur de séquences** (`Modules/TaskEngine`) | Exécute les étapes de la phase 2 sur la machine cible. |
| **Vault de secrets** | Stocke les mots de passe (compte WinPE, admin local, jonction domaine), en clair ou chiffré AES. |

---

## Prérequis

| Composant | Version | Usage |
|-----------|---------|-------|
| Windows Server / Windows 10+ | — | Serveur de déploiement |
| PowerShell | 5.1 | Obligatoire (PowerShell 7 non requis) |
| Windows ADK | 10.0.26100+ | `copype`, DISM, `oscdimg` |
| WinPE Add-on | même version que l'ADK | Architecture amd64 ou arm64 |
| Module Pode | 2.13+ | API REST (installé automatiquement) |
| Docker | — | Interface web (optionnelle) |

ADK est requis

---

## Installation

```powershell
# 1. Débloquer l'archive si téléchargée depuis Internet
Unblock-File .\PSWinDeploy_v0.6.9.zip

# 2. Extraire où vous voulez (ex : E:\PSWinDeploy)
Expand-Archive .\PSWinDeploy_v0.6.9.zip E:\

# 3. Lancer l'assistant d'installation (en administrateur)
E:\PSWinDeploy\Initialize-PSWinDeploy.ps1
```

L'assistant guide pas à pas : dossier d'installation, partages SMB, compte d'accès WinPE, jonction domaine, mots de passe (saisis ou générés aléatoirement), WinPE, et génère la configuration ainsi qu'un token d'API. Il peut être relancé sans risque.

À la fin, il affiche le **token d'API** et les **mots de passe générés** — à conserver.

---

## Démarrage rapide

```powershell
# Démarrer l'API
E:\PSWinDeploy\Start-API.ps1

# Ouvrir la console d'administration
E:\PSWinDeploy\PSWinDeploy-Console.ps1

# Construire l'ISO WinPE (depuis la console : [W], ou directement)
E:\PSWinDeploy\Build-WinPE.ps1
```

Puis, côté machine cible : démarrer sur l'ISO WinPE (ou via PXE), et le déploiement se lance.

---

## Interface web

L'interface tourne dans un conteneur Docker. Le backend détient les secrets (token d'API, mot de passe admin) ; le navigateur ne reçoit qu'un cookie de session.

```bash
cd Web/
# Renseigner Web/.env (pré-rempli par l'assistant : URL et token de l'API)
# Générer le hash du mot de passe admin sur http://<hôte>:8088/hash
docker compose up -d
```

Accessible sur `http://<hôte>:8088`. Elle propose :

- **Suivi** — déploiements en cours, en temps réel, phase 1 et phase 2.
- **Statistiques** — volumes par jour / semaine / mois / année, durées, avec pagination et purge.
- **Catalogue** — applications déployables (winget / choco / exe-msi).
- **Séquences** — visualisation et édition des séquences de post-installation.
- **Scripts & Drivers** — exploration des partages.

Le mot de passe administrateur est stocké sous forme de **hash scrypt** (jamais en clair, ni dans la configuration ni dans les logs).

---

## Séquences de post-installation

Une séquence est un fichier `.psd1` décrivant les étapes de la phase 2. Exemple minimal :

```powershell
@{
    Id   = 'ts-exemple'
    Name = 'Poste standard'
    Metadata = @{ Os = 'Windows'; Locale = 'fr-FR' }
    Steps = @(
        @{ Id = 'pi-01'; Type = 'WaitForNetwork'; Name = 'Attendre le réseau'; Enabled = $true }
        @{ Id = 'pi-02'; Type = 'JoinDomain';     Name = 'Jonction domaine';   Enabled = $true }
        @{ Id = 'pi-03'; Type = 'InstallSoftware'; Name = 'Logiciels';         Enabled = $true; Params = @{ Source = '\\SERVEUR\Logiciels' } }
        @{ Id = 'pi-04'; Type = 'RunScript';      Name = 'Réglages';           Enabled = $true; Params = @{ Path = '\\SERVEUR\Scripts\Config.ps1' } }
    )
}
```

Les séquences peuvent être **génériques**, ou **nominatives** (par nom de machine ou par adresse MAC), et résolues automatiquement au déploiement. Des modèles prêts à l'emploi sont fournis dans `Sequences/`.

---

## Sécurité

- **Secrets** isolés dans un vault (clair protégé par les droits SMB, ou chiffré AES).
- **API** protégée par token ; les écritures exigent l'en-tête correspondant.
- **Interface web** : secrets côté serveur uniquement, session par cookie httpOnly, mot de passe admin haché (scrypt).
- **HTTPS optionnel** sur l'API (certificat auto-signé généré depuis la console, ou fourni) pour chiffrer le trafic.

---

## Structure du dépôt

```
PSWinDeploy/
├── Initialize-PSWinDeploy.ps1   Assistant d'installation
├── PSWinDeploy-Console.ps1      Console d'administration
├── PSWinDeploy.psd1             Configuration générée
├── API/                         API REST (Pode)
├── Modules/                     Modules PowerShell (moteur, WinPE, drivers…)
├── Scripts/                     Start-Deploy, build WinPE, utilitaires
├── Sequences/                   Séquences de post-installation (modèles inclus)
├── Catalogue/                   Catalogue d'applications
├── Web/                         Interface web (frontend React + backend Node, Docker)
└── Docs/                        Documentation détaillée
```

---

## Documentation

Une documentation détaillée est disponible dans [`Docs/`](Docs/) (architecture API/web, types d'étapes, guides de séquences, débogage). Une refonte avec un site dédié est prévue.

---

## Statut & feuille de route

PSWinDeploy est en développement actif. Quelques pistes envisagées :

- Mode « en attente » en phase 2 : pousser une séquence à la volée depuis l'interface vers un poste qui attend.
- Suppression/édition de séquences depuis l'interface.
- Authentification OIDC pour l'interface web.
- Internationalisation.

---


<p align="center"><sub>PSWinDeploy — déploiement Windows en PowerShell, sans MDT.</sub></p>
