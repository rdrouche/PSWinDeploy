# Guide : installations par script et mode debug

Ce guide couvre deux fonctionnalites de PSWinDeploy :

1. Les installations d'applications **par script dedie** (cas complexes).
2. Le **mode debug** pour afficher les informations de diagnostic.

---

## 1. Installations par script dedie

### Quand l'utiliser

Le moteur d'installation standard suit une cascade : winget, puis Chocolatey,
puis un installeur exe/msi. Cela couvre la majorite des applications.

Mais certaines installations sont **trop complexes** pour ce moule : plusieurs
etapes, configuration post-installation, conditions particulieres, dependances,
fichiers de licence a deposer, cles de registre specifiques, etc.

Pour ces cas, on utilise une **installation par script** : un fichier `.ps1`
dedie qui fait TOUT le travail. C'est une methode **unique et exclusive** :
quand une application definit un `Script`, aucune autre methode n'est tentee
(pas de cascade winget/choco/exe). Le script est seul maitre a bord.

### Comment le declarer

Dans une etape `InstallApps` de la sequence, une application peut definir le
champ `Script` au lieu (ou en plus, mais il est prioritaire) des champs
WingetId / ChocoId / Installer :

```powershell
@{
    Id    = 'apps'
    Type  = 'InstallApps'
    Phase = 'Windows'
    Params = @{
        catalogApps = @(
            # Application standard (cascade winget -> choco)
            @{ Name = 'Google Chrome'; WingetId = 'Google.Chrome'; ChocoId = 'googlechrome' }

            # Application par SCRIPT dedie (methode unique)
            @{ Name = 'MonAppComplexe'; Script = 'installs\mon-app.ps1' }
        )
    }
}
```

### Les deux formes de chemin acceptees

Le champ `Script` accepte deux formes :

- **Chemin relatif** : `'installs\mon-app.ps1'`
  Resolu automatiquement sur le partage Logiciels (ex:
  `\\SERVEUR\Logiciels\installs\mon-app.ps1`).

- **Chemin UNC ou absolu complet** : `'\\IP\Logiciels\mon-app.ps1'` ou
  `'\\SERVEUR\Logiciels\mon-app.ps1'` ou `'C:\Deploy\scripts\mon-app.ps1'`
  Utilise tel quel, sans transformation.

Les deux fonctionnent. Le chemin absolu/UNC est pratique si le script est
ailleurs que sur le partage Logiciels par defaut.

### Convention de code de sortie

Le script doit respecter cette convention pour que le moteur interprete
correctement le resultat :

- `exit 0`    -> succes
- `exit 3010` -> succes, mais un redemarrage est necessaire (le moteur
                 enchainera le reboot et la reprise automatiquement)
- tout autre code -> echec (logge, le deploiement continue avec les etapes
                 suivantes)

### Exemple de script d'installation

```powershell
# mon-app.ps1 -- installation complexe d'exemple
param([string]$LicenseKey = '')

try {
    # 1. Copier l'installeur depuis le partage
    $src = '\\SERVEUR\Logiciels\MonApp\setup.exe'
    $dst = "$env:TEMP\setup.exe"
    Copy-Item $src $dst -Force

    # 2. Installer en silencieux
    $p = Start-Process $dst -ArgumentList '/S /v/qn' -Wait -PassThru
    if ($p.ExitCode -ne 0) { exit $p.ExitCode }

    # 3. Configuration post-installation (registre, fichiers...)
    Set-ItemProperty 'HKLM:\SOFTWARE\MonApp' -Name 'Configured' -Value 1 -Force

    # 4. Deposer la licence si fournie
    if ($LicenseKey) {
        Set-Content "$env:ProgramFiles\MonApp\license.dat" -Value $LicenseKey
    }

    exit 0
} catch {
    Write-Error $_
    exit 1
}
```

### Passer des arguments au script

Le champ `Args` (optionnel) est passe au script :

```powershell
@{ Name = 'MonApp'; Script = 'installs\mon-app.ps1'; Args = '-LicenseKey ABC-123' }
```

---

## 2. Mode debug

### A quoi ca sert

Le mode debug affiche des informations de **diagnostic detaillees** pendant le
deploiement : chemins scannes, contenu des dossiers, retours de fonctions,
nombre d'elements trouves, etc. Ces lignes sont prefixees par `[diag]`.

En utilisation normale (production), ces details ne sont pas affiches pour
garder une sortie lisible. On les active uniquement pour **diagnostiquer un
probleme** (ex: les drivers ne sont pas detectes, une selection se comporte
mal).

### Comment l'activer

Deux methodes, au choix :

**Methode 1 -- par la configuration (permanent)**

Dans `PSWinDeploy.psd1`, mettre :

```powershell
debugMode = $true
```

Absent ou `$false` = mode normal (recommande en production). C'est la valeur
par defaut.

**Methode 2 -- ponctuellement, au lancement**

Ajouter le switch `-DebugMode` a Start-Deploy.ps1 :

```powershell
.\Start-Deploy.ps1 -DebugMode
```

Le switch a la priorite : meme si la config dit `$false`, `-DebugMode` force
l'affichage pour cette execution.

### Ce que ca change

Sans debug (normal) :

```
[2b/6] Drivers : selection du modele a injecter...
  Partage drivers : \\SERVEUR\Drivers
[fenetre de selection]
```

Avec debug :

```
[2b/6] Drivers : selection du modele a injecter...
  Partage drivers : \\SERVEUR\Drivers
  [diag] Scan du dossier drivers : '\\SERVEUR\Drivers'
  [diag] 3 sous-dossier(s) trouve(s).
  [diag]  - dossier: 'Dell-1' (\\SERVEUR\Drivers\Dell-1)
  [diag]    -> 5 fichier(s) .inf
  [diag]  - dossier: 'HP-2' (...)
  [diag]    -> 8 fichier(s) .inf
  [diag]  - dossier: 'WinPE' (...)
  [diag]    -> exclu (WinPE)
  [diag] 2 modele(s) retenu(s).
[fenetre de selection]
```

Le mode debug est precieux pour comprendre pourquoi quelque chose ne se passe
pas comme prevu, sans avoir a modifier le code.
