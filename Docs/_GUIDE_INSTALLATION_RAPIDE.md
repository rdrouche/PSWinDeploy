# Installation de PSWinDeploy

## Prérequis pour l'installation

### Obligatoires

- Un serveur Windows Serveur en Workgroup ou domaine avec une adresse IP fixe et idéalement une partition dédié
- Installer Windows ADK
- Installer Windpws ADK Winpe

```powershell
winget install -e --id Microsoft.WindowsADK --source winget
winget install -e --id Microsoft.WindowsADK.WinPEAddon --source winget

```

### Optionnels

- Un serveur Linux ou WSL avec Docker et Docker Compose pour l'interface Web


## Installation de PSWinDeploy

Commencer par télécharger l'archive disponible sur [Github](https://github.com/rdrouche/PSWinDeploy/).

Une fois l'archive décompression commencer par exécuter le script `Unblock-PSWinDeploy.ps1`

Ensuite lancer l'assistant de d'installation de configuration de PSWinDeploy : `Initialize-PSWinDeploy.ps1`

## Démarrage rapide

Pour commencer, vous devez avoir disposition un ISO de l'OS Windows que vous souhaitez installer sur le serveur.

Aller dans le dossier d'installation de PSWinDeploy et lancer le fichier : `PSWinDeploy-Console.ps1'

### Ajouter un système d'exploitation

Entrer la lettre E pour exporter un ISO

```
  WINPE
    [W]  Construire le WinPE
        Assistant build (packages, drivers, ISO, WIM PXE)
    [E]  Exporter une image WIM
        Depuis un ISO Windows

```

Suivre l'assistant qui va vous guider pour exporter le fichier wim.

```
  +----------------------------------------------------------+
  |                PSWinDeploy -- Export WIM                 |
  +----------------------------------------------------------+

  [~]  Extrait une edition Windows depuis un ISO ou WIM source.
  [~]  Produit un fichier .wim optimise pret pour le deploiement.

  ISO Windows --> plusieurs editions --> WIM unique par edition
  Avantages : WIM plus petit, index unique, DISM plus rapide.


  +----------------------------------------------------------+
  |                    Etape 1 -- Source                     |
  +----------------------------------------------------------+

  [?]  Source : [1] Monter un ISO  [2] Fichier WIM/ESD existant :
```

> Si le fichier ISO est la racine du lecteur, il serait détecté automatiquement

Le fichier extrait se trouve dans le dossier `Shares\Images` et le fichier `os-catalogue.psd1` est automatique généré.

### Générer l'environnement de boot WinPE

De retour au menu principale de la console fait le choix : `W` pour l'ancer l'assistant.

Valider le choix `1` et suivre l'assistant.

```
  ==========================================================
     PSWinDeploy -- Assistant de construction WinPE
  ==========================================================

  Mode de construction :
    [1] RAPIDE        -- valeurs par defaut, aucune question (recommande)
    [2] PERSONNALISE  -- choisir chaque option pas a pas

  [?]  Votre choix [1] :

  [OK] Mode RAPIDE : construction avec les valeurs par défaut
```

L'assistant génère deux fichiers qui sont dans le dossier : `WinPE\ISO` : 
- ISO
- WIM pour WDS

### Déployer Windows

Le déploiement se fait en deux phases : 
- P1 : se charge de déployer Windows sur l'ordinateur
- P2 : personnalisation


> La phase 2 peut être automatiser ou manuelle

Démarrer sur l'ISO et suivre l'assistant.

> La documentation est en cours de rédaction, vous trouverez plus d'aide dans les fichiers qui se trouve dans le dossier [Docs](https://github.com/rdrouche/PSWinDeploy/tree/main/Docs)