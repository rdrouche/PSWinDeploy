# PSWinDeploy v0.6.9

Remplacement de MDT en PowerShell moderne. Deploiement Windows depuis WinPE via partages SMB, vault de secrets, sequences PSD1.

## Architecture

```
[Serveur S-PS-DEP-1]          [Machine cible]
  PSWinDeploy-Console.ps1       Boot WinPE ISO/PXE
  ??? [D] Gerer sequences  ?    \\S-PS-DEP-1\Deploy\Sequences\*.psd1
  ??? [W] Build WinPE      ?    WinPE-amd64.iso
  ??? [E] Export WIM       ?    \\S-PS-DEP-1\Images\*.wim
  ??? [V] Vault            ?    secrets.vault.psd1

[WinPE]
  Start-Deploy.ps1
  ??? Connexion SMB (vault PSD1 ? svc-winpe)
  ??? Liste sequences .psd1
  ??? Choix disque cible
  ??? Execution sequence ? Windows installe
```

## Prerequis

| Composant | Version | Usage |
|-----------|---------|-------|
| Windows Server / Windows 10+ | -- | Serveur de deploiement |
| PowerShell | 5.1 | Obligatoire (PS 7 non requis) |
| ADK Windows 11 | 10.0.26100+ | copype.cmd, DISM, oscdimg |
| WinPE Add-on | Meme version ADK | Architecture amd64 |
| Docker Desktop | -- | Interface Web (optionnel) |

Telecharger ADK : https://learn.microsoft.com/windows-hardware/get-started/adk-install
(Cocher : Deployment Tools + Windows PE Add-on)

## Installation

```powershell
# 1. Extraire l'archive
Expand-Archive PSWinDeploy_v0.6.9.zip E:\

# 2. Debloquer les fichiers (si telecharges depuis Internet)
# AVANT d'extraire :
Unblock-File PSWinDeploy_v0.6.9.zip
# OU apres extraction :
E:\PSWinDeploy\Unblock-PSWinDeploy.ps1

# 3. Initialiser
E:\PSWinDeploy\Initialize-PSWinDeploy.ps1
```

L'assistant Initialize :
- Cree les dossiers d'installation
- Cree les partages SMB (Images, Deploy, Drivers, Logiciels, Scripts, Logs)
- Configure PSWinDeploy.psd1
- Cree le compte svc-winpe

## Configuration (PSWinDeploy.psd1)

```powershell
@{
    Version          = '0.6.9'
    ServerFQDN       = 'S-PS-DEP-1'          # Nom/IP du serveur
    WinPEShareServer = 'S-PS-DEP-1'          # Pour le WinPE
    WinPEShareUser   = 'S-PS-DEP-1\svc-winpe'
    VaultPath        = 'C:\Deploy\secrets.vault.psd1'
    VaultMethod      = 'Plain'               # Plain recommande (multi-operateurs)
    AdkPath          = 'C:\Program Files (x86)\Windows Kits\10\Assessment and Deployment Kit'
    WinPEAddonPath   = '...\Windows Preinstallation Environment'
    ImageShare       = '\\S-PS-DEP-1\Images'
    DeployShare      = '\\S-PS-DEP-1\Deploy'
    WinPELocale      = 'fr-FR'
    Architecture     = 'amd64'
}
```

## Vault de secrets

Format PSD1 (recommande, editable a la main) :

```powershell
# secrets.vault.psd1
@{
    winpeUser         = 'S-PS-DEP-1\svc-winpe'
    winpePassword     = 'MonMotDePasse'
    domainJoinUser    = 'CORP\djoin'
    domainJoinPassword = 'MotDePasseDomaine'
    localAdminPassword = 'AdminLocal!'
}
```

Format JSON legacy supporte pour compatibilite.

**Modes vault :**
- `Plain` : vault en clair, protege par droits reseau + acces physique - **recommande pour equipe**
- `AES`   : chiffre, mot de passe requis au boot WinPE - 1 operateur seulement

## Sequences de deploiement

Format PSD1 - exemple `Win11-Domaine.psd1` :

```powershell
@{
    Id      = 'win11-domaine'
    Name    = 'Windows 11 Pro - Poste domaine'
    Version = '1.0.0'
    Metadata = @{
        OS       = 'Windows 11 Pro'
        Locale   = 'fr-FR'
        Domain   = 'corp.local'
        Timezone = 'Romance Standard Time'
    }
    Steps = @(
        @{ Id='s01'; Type='FormatDisk'; Params=@{ DiskNumber=-1; FirmwareType='UEFI' } }
        @{ Id='s02'; Type='ApplyWIM';   Params=@{ WimPath='\\S-PS-DEP-1\Images\Win11.wim'; Index=1 } }
        @{ Id='s03'; Type='JoinDomain'; Params=@{ Domain='corp.local' } }
        @{ Id='s04'; Type='InstallUpdates' }
        @{ Id='s05'; Type='InstallApps'; Params=@{ Apps=@('7zip','chrome') } }
    )
}
```

Deposer dans `\\S-PS-DEP-1\Deploy\Sequences\`

**Types de steps disponibles :**

| Type | Description |
|------|-------------|
| `FormatDisk` | Partitionner (UEFI ou BIOS). DiskNumber=-1 = choix au boot |
| `ApplyWIM` | Appliquer une image Windows |
| `JoinDomain` | Joindre Active Directory |
| `InstallUpdates` | Windows Update |
| `InstallApps` | Applications depuis catalogue |
| `RunScript` | Script PowerShell post-deploiement |
| `SetLocalAdmin` | Definir mot de passe administrateur local |
| `InjectDrivers` | Drivers depuis `\\S-PS-DEP-1\Drivers\FABRICANT\MODELE\` |
| `Reboot` | Redemarrer avec compteur |
| `WaitNetwork` | Attendre la connectivite reseau |

## Console d'administration

```
PSWinDeploy-Console.ps1
  [D] Gerer les sequences    Creer/editer des sequences .psd1
  [W] Construire le WinPE    Build ISO/PXE avec packages et drivers
  [E] Exporter une image WIM Depuis un ISO Windows monte
  [S] Sante du systeme       Rapport ADK, partages, vault, WDS
  [V] Drivers                Structure, inventaire, verification
  [L] Journaux               Consulter, rechercher, nettoyer
  [N] Notifications          Mail et Teams Webhook
  [M] Mise a jour            Depuis archive .zip ou dossier
  [U] Debloquer les scripts  Supprimer Zone.Identifier
  [I] Re-initialiser         Relancer Initialize
```

## Build WinPE

```powershell
# Depuis la console [W] ou directement :
E:\PSWinDeploy\Build-WinPE.ps1
```

L'assistant Build-WinPE :
1. Locale et architecture (fr-FR / amd64)
2. Packages (WMI, NetFx, Scripting, PowerShell, StorageWMI, EnhancedStorage)
3. Drivers reseau/stockage depuis `\\S-PS-DEP-1\Drivers\WinPE\`
4. Vault WinPE (mode Plain recommande)
5. Chemin workspace et ISO de sortie

**Resultat :** `E:\PSWinDeploy\WinPE\ISO\WinPE-amd64.iso`

Contenu du WIM injecte :
```
X:\Deploy\
  Scripts\Start-Deploy.ps1
  Modules\NetShare\, Config\, TaskSequence\, ...
  secrets.vault.psd1
```

## Flux de deploiement WinPE

```
Boot ISO/PXE
  ??? startnet.cmd
        ??? wpeutil SetKeyboardLocale fr-FR
        ??? Start-Deploy.ps1 -NetworkShare \\S-PS-DEP-1\Deploy
              ??? Connexion SMB (svc-winpe via vault)
              ?     Fallback automatique sur IP si DNS absent
              ??? Liste \\S-PS-DEP-1\Deploy\Sequences\*.psd1
              ??? Operateur choisit la sequence
              ??? Si DiskNumber=-1 : operateur choisit le disque
              ??? Execution sequence step par step
```

## Structure des partages SMB

```
\\S-PS-DEP-1\
  Images\       *.wim  (images Windows a deployer)
  Deploy\
    Sequences\  *.psd1 (sequences de deploiement)
    Modules\    modules PS copies depuis le serveur
    Logs\       journaux de deploiement
  Drivers\
    WinPE\Net\     drivers NIC pour WinPE
    WinPE\Storage\ drivers NVMe/SATA pour WinPE
    WinPE\Sys\     drivers chipset/USB pour WinPE
    Dell\MODELE\   drivers OS complets par modele
    HP\MODELE\
    Lenovo\MODELE\
  Logiciels\    installeurs apps (.msi, .exe)
  Scripts\      scripts post-deploiement
  Logs\         journaux centralises
```

## Mise a jour

```powershell
# Option 1 : depuis le dossier source extrait
E:\PSWinDeploy_v0.6.9\PSWinDeploy\Update-PSWinDeploy.ps1
# -> Detecte l'installation automatiquement

# Option 2 : depuis l'installation
E:\PSWinDeploy\Update-PSWinDeploy.ps1 -ArchivePath 'D:\PSWinDeploy_v0.6.9.zip'

# Option 3 : depuis la console [M]

# Modes :
# [1] Tout mettre a jour (recommande) - force la copie de tous les fichiers
# [2] Composant par composant
# [3] Simulation (DryRun)
```

**Fichiers JAMAIS ecrases :** `PSWinDeploy.psd1`, `secrets.vault.psd1`, `Shares\`, `Profiles\`

## Depannage

### WinPE ne se connecte pas aux partages

```cmd
# Depuis la console debug WinPE :
ping 10.0.8.111                              # IP du serveur
net use \\10.0.8.111\Deploy                  # Test manuel
powershell -c "Test-NetConnection 10.0.8.111 -Port 445"
```

Causes frequentes :
- Pare-feu Windows sur le serveur bloquant le port 445
- Partage `Deploy` non cree (relancer Initialize)
- Compte `svc-winpe` expire ou verrouille

### copype.cmd echoue

Verifier que le **WinPE Add-on** est installe (pas seulement l'ADK) :
```
C:\Program Files (x86)\Windows Kits\10\...\Windows Preinstallation Environment\amd64\
```
Si absent : reinstaller depuis https://learn.microsoft.com/windows-hardware/get-started/adk-install

### Get-NetAdapter absent en WinPE

Normal - ce module n'existe pas en WinPE. PSWinDeploy utilise WMI + ipconfig a la place.

### Encodage AZERTY au boot WinPE

Rebuild le WinPE - l'assistant configure `wpeutil SetKeyboardLocale fr-FR` dans `startnet.cmd`.

## Versions

| Version | Date | Changements principaux |
|---------|------|----------------------|
| 0.6.9 | 2026-06 | New-SmbMapping, vault PSD1, AZERTY WinPE, fallback IP, sequences PSD1 |
| 0.6.5 | 2026-06 | Unblock-PSWinDeploy, Update-PSWinDeploy, menu Drivers |
| 0.6.0 | 2026-06 | Fix copype DandISetEnv, MakeWinPEMedia, encodage DISM FR |
| 0.5.0 | 2026-05 | Version initiale publique |
