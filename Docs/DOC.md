# PSWinDeploy -- Reference rapide

## Console

```powershell
E:\PSWinDeploy\PSWinDeploy-Console.ps1
```

| Touche | Action | Utilisation |
|--------|--------|-------------|
| D | Gerer les sequences | Creer/editer sequences .psd1 de deploiement |
| W | Build WinPE | Construire ISO bootable |
| E | Exporter WIM | Extraire image depuis ISO |
| S | Sante | Rapport etat du systeme |
| V | Drivers | Inventaire et structure drivers |
| L | Journaux | Logs deploiements |
| N | Notifications | Mail / Teams |
| M | Mise a jour | Update depuis archive ou dossier |
| U | Debloquer | Supprimer Zone.Identifier |
| I | Re-initialiser | Relancer Initialize |

## Fichiers importants

| Fichier | Role |
|---------|------|
| `PSWinDeploy.psd1` | Configuration principale |
| `secrets.vault.psd1` | Credentials (vault Plain) |
| `Initialize-PSWinDeploy.ps1` | Installation initiale |
| `Update-PSWinDeploy.ps1` | Mise a jour |
| `Unblock-PSWinDeploy.ps1` | Deblocage Zone Internet |
| `Build-WinPE.ps1` | Build WinPE (genere par Initialize) |
| `Start-API.ps1` | Lancer l'API Pode |

## Modules PowerShell

| Module | Role |
|--------|------|
| `Config.psm1` | Lecture PSWinDeploy.psd1 |
| `NetShare.psm1` | Connexion SMB, vault, New-SmbMapping |
| `WinPE-Builder.psm1` | Build WinPE (copype, DISM, packages) |
| `TaskSequence.psm1` | Execution sequences de deploiement |
| `ProfileManager.psm1` | Gestion profils deploiement |
| `DiskSelector.psm1` | Choix et partitionnement disque |
| `WIM-Manager.psm1` | Gestion images WIM |
| `Notify.psm1` | Notifications mail et Teams |

## Scripts

| Script | Role | Contexte |
|--------|------|---------|
| `Start-Deploy.ps1` | Point d'entree deploiement | WinPE |
| `Deploy-Assistant.ps1` | Editeur sequences | Serveur |
| `Build-WinPE-Assistant.ps1` | Assistant build WinPE | Serveur |
| `Export-WIMImage.ps1` | Export image WIM | Serveur |

## Commandes DISM utiles (debug)

```cmd
# Voir les images dans un WIM
dism /Get-WimInfo /WimFile:"E:\PSWinDeploy\WinPE\Workspace\media\sources\boot.wim"

# Monter/demonter
dism /Mount-Image /ImageFile:boot.wim /Index:1 /MountDir:C:\mount
dism /Unmount-Image /MountDir:C:\mount /Commit
dism /Unmount-Image /MountDir:C:\mount /Discard

# Voir les packages installes dans le WIM monte
dism /Image:C:\mount /Get-Packages
```

## Vault PSD1 -- structure complete

```powershell
# E:\PSWinDeploy\Deploy\secrets.vault.psd1
@{
    # Acces partages depuis WinPE
    winpeUser          = 'S-PS-DEP-1\svc-winpe'
    winpePassword      = 'MotDePasseSVC'

    # Jonction domaine (utilise par TaskSequence JoinDomain)
    domainJoinUser     = 'CORP\svc-djoin'
    domainJoinPassword = 'MotDePasseDomain'

    # Compte admin local (defini apres installation)
    localAdminPassword = 'Admin@Local!2024'

    # Compte autologon temporaire (phase post-installation)
    deployPassword     = 'TempDeploy123'
}
```

## Sequence PSD1 -- types de steps complets

```powershell
Steps = @(
    # Partitionner le disque
    @{ Id='s01'; Type='FormatDisk'
       Params=@{ DiskNumber=-1; FirmwareType='UEFI' } }
    # -1 = choix operateur au boot

    # Appliquer Windows
    @{ Id='s02'; Type='ApplyWIM'
       Params=@{ WimPath='\\SRV\Images\Win11.wim'; Index=1; TargetDrive='W:' } }

    # Joindre domaine
    @{ Id='s03'; Type='JoinDomain'
       Params=@{ Domain='corp.local'; OU='OU=Postes,DC=corp,DC=local' } }

    # Windows Update
    @{ Id='s04'; Type='InstallUpdates'
       Params=@{ Categories=@('Security','Critical') } }

    # Applications
    @{ Id='s05'; Type='InstallApps'
       Params=@{ Apps=@('7zip','chrome','office365') } }

    # Script custom
    @{ Id='s06'; Type='RunScript'
       Params=@{ Path='\\SRV\Scripts\post-deploy.ps1' } }

    # Drivers OS
    @{ Id='s07'; Type='InjectDrivers'
       Params=@{ Path='\\SRV\Drivers\Dell\OptiPlex-7090' } }

    # Admin local
    @{ Id='s08'; Type='SetLocalAdmin'
       Params=@{ Source='vault'; Key='localAdminPassword' } }

    # Reboot
    @{ Id='s09'; Type='Reboot'
       Params=@{ DelaySeconds=10; Message='Redemarrage...' } }
)
```

## Drivers WinPE -- structure

```
\\S-PS-DEP-1\Drivers\
  WinPE\Net\         NIC (Intel I225, Realtek 8125...)
  WinPE\Storage\     NVMe (Samsung, Intel RST, AMD...)
  WinPE\Sys\         Chipset, USB 3.x (optionnel)
  Dell\OptiPlex-7090\  Drivers OS complets
  HP\EliteBook-840\
  Lenovo\ThinkPad-T14\
```

Sources drivers fabricants :
- Dell : Dell Command | Update (extraire les .cab)
- HP : HP SoftPaq Download Manager
- Lenovo : Lenovo System Update
