# PSWinDeploy - Reference des types de steps de sequence

Ce document liste TOUS les types de steps disponibles dans une sequence, avec
leurs parametres et des exemples. Une sequence est un fichier .psd1 contenant
une liste de steps executes dans l'ordre.

## Structure generale d'une sequence

```powershell
@{
    Id      = 'identifiant-sequence'
    Name    = 'Nom lisible'
    Version = '1.0.0'
    Steps   = @(
        @{
            Id          = 'step-01'           # identifiant unique du step
            Type        = 'RunScript'         # type (voir ci-dessous)
            Name        = 'Description'        # libelle affiche
            Phase       = 'Windows'           # 'WinPE' ou 'Windows' (defaut WinPE)
            Enabled     = $true               # step actif ?
            RebootAfter = 'Never'             # 'Never' | 'IfRequired' | 'Always'
            Params      = @{ }                # parametres specifiques au type
        }
    )
}
```

### Le champ Phase (IMPORTANT)

- `Phase = 'WinPE'`   : execute en phase 1 (WinPE). C'est le DEFAUT si absent.
- `Phase = 'Windows'` : execute en phase 2 (apres le 1er reboot, Windows demarre).

En mode SIMPLE (recommande), la phase 1 est geree en dur par le moteur. Vos
sequences doivent donc declarer `Phase = 'Windows'` sur tous les steps.

### Le champ RebootAfter

- `'Never'`      : pas de reboot apres ce step (defaut conseille pour scripts).
- `'IfRequired'` : reboot si le step le demande (exit 3010 ou reboot Windows en
  attente). Recommande pour InstallUpdates et InstallApps.
- `'Always'`     : reboot systematique apres ce step (ex: JoinDomain).

---

## Types de steps PHASE 2 (Windows) -- les plus utiles

### JoinDomain -- Jonction au domaine Active Directory

Joint la machine a un domaine AD. Lit `DomainName` / `DomainOU` depuis la config
globale (PSWinDeploy.psd1) si les parametres du step sont vides. Les credentials
viennent du vault (`domainJoinUser` / `domainJoinPassword`).

```powershell
@{ Id='join'; Type='JoinDomain'; Name='Jonction domaine'; Phase='Windows';
   RebootAfter='Always';
   Params=@{
       domain  = 'corp.example.local'                       # ou vide -> config
       ou      = 'OU=PCs,DC=corp,DC=example,DC=local'       # ou vide -> config
       newName = ''                                          # renommer (vide=non)
   } }
```

### InstallUpdates -- Mises a jour Windows

Recherche, telecharge et installe les MAJ Windows via l'API COM native. Pose un
reboot si necessaire (utilisez RebootAfter='IfRequired').

```powershell
@{ Id='updates'; Type='InstallUpdates'; Name='Mises a jour Windows';
   Phase='Windows'; RebootAfter='IfRequired'; Params=@{} }
```

### InstallApps (alias InstallSoftware) -- Installation d'applications

Installe des applications en cascade winget -> choco -> exe/msi. Chocolatey est
installe automatiquement si requis et absent.

**Trois facons de declarer les apps (de la plus simple a la plus detaillee) :**

1. Par NOM, resolu depuis le catalogue (le plus simple) :
```powershell
@{ Id='apps'; Type='InstallApps'; Phase='Windows'; RebootAfter='IfRequired';
   Params=@{ apps = @('Google Chrome', '7-Zip') } }
```
   Les noms sont cherches dans le catalogue (CataloguePath du psd1) qui fournit
   WingetId/ChocoId/Installer. Pas besoin de repeter les details.

2. Par objets riches (si pas de catalogue, ou pour surcharger) :
```powershell
@{ Id='apps'; Type='InstallApps'; Phase='Windows';
   Params=@{ catalogApps = @(
       @{ Name='Chrome'; WingetId='Google.Chrome'; ChocoId='googlechrome' }
   ) } }
```

3. Option pour forcer winget (eviter choco) :
```powershell
   Params=@{ apps = @('Google Chrome'); noChoco = $true }
```
   Avec noChoco, si winget echoue, l'app n'est PAS installee via choco.

Le moteur initialise winget automatiquement (enregistrement du package App
Installer) pour qu'il fonctionne en deploiement.

```powershell
@{ Id='apps'; Type='InstallApps'; Name='Applications'; Phase='Windows';
   RebootAfter='IfRequired';
   Params=@{
       catalogApps = @(
           @{ Name='Chrome';  WingetId='Google.Chrome'; ChocoId='googlechrome' }
           @{ Name='7-Zip';   WingetId='7zip.7zip' }
           @{ Name='Metier';  Installer='\\serveur\Logiciels\App\setup.msi'; Args='/quiet'; RebootAfter=$true }
       )
       # OU forme simple :
       # apps = @('Google.Chrome', '7zip.7zip')
   } }
```

### RunScript -- Execution d'un script PowerShell

Execute un script. Le code de sortie pilote le reboot : exit 0 = ok, exit 3010
= reboot demande (le moteur reboote puis REPREND a l'etape suivante). Les appels
a Restart-Computer dans le script sont neutralises (transformes en exit 3010)
pour que le moteur gere le reboot proprement.

```powershell
@{ Id='script'; Type='RunScript'; Name='Mon script'; Phase='Windows';
   RebootAfter='Never';
   Params=@{ Path='C:\Deploy\Scripts\MonScript.ps1'; Shell='PowerShell' } }
```

### CopyFiles -- Copie de fichiers

```powershell
@{ Id='copy'; Type='CopyFiles'; Name='Copier fichiers'; Phase='Windows';
   Params=@{ Source='\\serveur\Deploy\Files\config'; Destination='C:\ProgramData\App' } }
```

### SetRegistry -- Modification du registre

```powershell
@{ Id='reg'; Type='SetRegistry'; Name='Cle registre'; Phase='Windows';
   Params=@{ Path='HKLM:\SOFTWARE\MaSociete'; Name='Param'; Value='1'; Type='DWord' } }
```

### SetComputerName -- Renommer la machine

```powershell
@{ Id='rename'; Type='SetComputerName'; Name='Renommer'; Phase='Windows';
   RebootAfter='Always'; Params=@{ newName='PC-COMPTA-01' } }
```

### WaitForNetwork -- Attendre le reseau

```powershell
@{ Id='net'; Type='WaitForNetwork'; Name='Attendre reseau'; Phase='Windows';
   Params=@{ TimeoutSeconds=60 } }
```

### Reboot -- Reboot explicite

Force un reboot a ce point de la sequence (reprise automatique apres).

```powershell
@{ Id='reboot'; Type='Reboot'; Name='Redemarrage'; Phase='Windows' }
```

### ShowWizard -- Ouvrir l'assistant post-installation

Ouvre le menu de l'assistant (comme s'il n'y avait pas de sequence). Permet de
derouler une sequence PUIS de proposer l'assistant pour continuer (apps,
scripts, MAJ a la volee). A placer en general en fin de sequence.

```powershell
@{ Id='wizard'; Type='ShowWizard'; Name='Assistant'; Phase='Windows' }
```

### Cleanup -- Nettoyage de fin de deploiement

Supprime les fichiers sensibles de C:\Deploy (vault, config, scripts, modules,
runtime, state) et la tache de reprise. Conserve C:\Deploy\Logs. A placer en
DERNIER step (RebootAfter='Never').

```powershell
@{ Id='cleanup'; Type='Cleanup'; Name='Nettoyage final'; Phase='Windows';
   RebootAfter='Never'; Params=@{ keepLogs=$true } }
```

---

## Types de steps PHASE 1 (WinPE) -- avance / rare

En mode SIMPLE, ces etapes sont gerees EN DUR par le moteur. Vous n'avez
normalement PAS besoin de les mettre dans une sequence. Documentes pour
information / mode TaskSequence avance.

- **FormatDisk** : partitionne et formate le disque (GPT/UEFI).
  `Params=@{ targetDrive=0 }`
- **ApplyWIM** : applique l'image Windows sur la partition.
  `Params=@{ wimPath='...'; index=1 }`
- **InjectDrivers** : injecte des pilotes (DISM /Add-Driver) offline.
  `Params=@{ driverPath='\\serveur\Drivers' }`
- **SetLocale** : configure la langue / le clavier / le fuseau.
  `Params=@{ locale='fr-FR'; timezone='Romance Standard Time' }`
- **ApplyUnattend** : genere et applique un unattend.xml.

---

## Sequences pre-existantes (exemples fournis)

### _default.psd1 -- sequence de test minimale

Contient un seul step RunScript qui cree C:\test\test.txt (validation, sans
reboot). Sert a verifier que la chaine phase 2 fonctionne.

### Affectation d'une sequence a un poste

Ordre de priorite (du plus specifique au plus general) :
1. `by-name\<COMPUTERNAME>.psd1` -- par nom de machine (le plus simple)
2. `by-mac\<MAC>.psd1`           -- par adresse MAC
3. `_default.psd1`               -- defaut general

Exemples :
- `\\serveur\Deploy\Sequences\by-name\PC-COMPTA-01.psd1`
- `\\serveur\Deploy\Sequences\by-mac\00155D8A2C01.psd1`
- `\\serveur\Deploy\Sequences\_default.psd1`

---

## Exemple complet : sequence poste standard

```powershell
@{
    Id    = 'poste-standard'
    Name  = 'Poste standard entreprise'
    Steps = @(
        @{ Id='s1'; Type='JoinDomain';     Name='Domaine';  Phase='Windows'; RebootAfter='Always';
           Params=@{ domain='corp.local'; ou='OU=PCs,DC=corp,DC=local' } }
        @{ Id='s2'; Type='InstallUpdates'; Name='MAJ';      Phase='Windows'; RebootAfter='IfRequired'; Params=@{} }
        @{ Id='s3'; Type='InstallApps';    Name='Apps';     Phase='Windows'; RebootAfter='IfRequired';
           Params=@{ catalogApps=@( @{ Name='Chrome'; WingetId='Google.Chrome' } ) } }
        @{ Id='s4'; Type='RunScript';      Name='Config';   Phase='Windows'; RebootAfter='Never';
           Params=@{ Path='C:\Deploy\Scripts\Config-Poste.ps1' } }
        @{ Id='s5'; Type='Cleanup';        Name='Nettoyage'; Phase='Windows'; RebootAfter='Never'; Params=@{ keepLogs=$true } }
    )
}
```
