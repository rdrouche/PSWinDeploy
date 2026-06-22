<#
.SYNOPSIS
    Start-Deploy.ps1 -- Point d'entree principal du deploiement depuis WinPE
.DESCRIPTION
    Script lance au boot WinPE (via startnet.cmd) ou apres reboot (via RunOnce).
    Orchestre :
      1. Initialisation de l'environnement (reseau, modules, logs)
      2. Assistant pre-deploiement (si pas de sequence pre-configuree)
      3. Execution de la task sequence
      4. Reprise apres reboot (-Resume)
.PARAMETER SequencePath
    Chemin vers le fichier task-sequence.json.
    Si absent, cherche sur le partage reseau et propose une liste.
.PARAMETER Resume
    Mode reprise apres reboot -- relit le state.psd1 et continue.
.PARAMETER NetworkShare
    Partage reseau source des sequences et images (ex: \\SERVEUR\Deploy).
.PARAMETER Unattended
    Mode silencieux -- pas d'assistant interactif (doit avoir SequencePath + diskNumber dans la sequence).
.EXAMPLE
    # Lance depuis startnet.cmd :
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File X:\Deploy\Scripts\Start-Deploy.ps1

    # Reprise apres reboot (RunOnce) :
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File C:\Deploy\Scripts\Start-Deploy.ps1 -Resume
#>

[CmdletBinding()]
param(
    [string]$SequencePath   = '',
    [switch]$Resume,
    [switch]$PostInstallWizard,   # Lance UNIQUEMENT l'assistant post-install (fenetre visible)
    [string]$NetworkShare   = '\\SERVEUR\Deploy',
    [string]$NetworkShareFallback = '',   # IP resolue au build (ex: \\\\192.168.1.10\\Deploy)
    [string]$ImageShare           = '',    # Partage Images (ex: \\SERVEUR\\Images)
    [switch]$Unattended,

    # -- Credentials partage reseau (acces SMB depuis WinPE) ------------------
    # Auto  : tente vault X:\Deploy\secrets.vault (ou $VaultPath si fourni) -> vars env -> prompt operateur
    # Plain : credentials en clair, comme MDT Bootstrap.ini (-ShareUser/-SharePassword)
    # Skip  : net use deja fait dans startnet.cmd avant ce script
    # Vault : force lecture depuis vault (-VaultPassword si AES)
    # Prompt: demande toujours a l'operateur
    # Env   : lit PSWINDEX_SHARE_USER / PSWINDEX_SHARE_PASSWORD
    [ValidateSet('Auto','Plain','Vault','Prompt','Skip','Env')]
    [string]$CredentialMode  = 'Auto',
    [string]$ShareUser,        # Mode Plain : compte reseau (ex: DEPLOYSRV\svc-winpe)
    [string]$SharePassword,    # Mode Plain : mot de passe du compte
    [string]$VaultPassword,    # Modes Vault/Auto : mot de passe AES du vault WinPE
    [string]$VaultPath = ''    # Chemin du vault injecte dans le WIM (ex: X:\Deploy\secrets.vault)
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# -----------------------------------------------------------------------------
# BOOTSTRAP -- Chemins et imports
# -----------------------------------------------------------------------------

# En WinPE le script est sur X:\Deploy\Scripts\ (copie par WinPE-Builder)
# Apres reboot il est sur C:\Deploy\Scripts\
$ScriptRoot = $PSScriptRoot
if (-not $ScriptRoot) { $ScriptRoot = Split-Path $MyInvocation.MyCommand.Path -Parent }

# Remonte a la racine PSWinDeploy
$DeployRoot  = Split-Path $ScriptRoot -Parent          # C:\Deploy  ou  X:\Deploy
$ModulesRoot = Join-Path $DeployRoot 'Modules'
# ImageShare : parametre ou deduction depuis NetworkShare
if (-not $ImageShare -and $NetworkShare) {
    # \\SERVEUR\Deploy -> \\SERVEUR\Images
    $ImageShare = $NetworkShare -replace '\\Deploy$', '\Images' `
                                -replace '\\Deploy\\', '\Images\'
    if ($ImageShare -eq $NetworkShare) {
        # Pas pu deduire -- utiliser sous-dossier Images
        $ImageShare = "$NetworkShare\Images"
    }
}

function Import-DeployModule {
    param([string]$Name)
    $modPath = Join-Path $ModulesRoot "$Name\$Name.psm1"
    if (Test-Path $modPath) {
        Import-Module $modPath -Force -Global
    } else {
        Write-Warning "Module introuvable : $modPath"
    }
}

function Connect-DeployShares {
    <#
    Connecte les partages reseau via NetShare.psm1.
    Mode Skip : net use deja fait dans startnet.cmd, on verifie juste l'acces.
    #>
    param([string]$Mode, [string]$User, [string]$Pass, [string]$VaultPwd, [string]$VaultPath = '')

    $server = $null
    if ($NetworkShare -match '\\\\([^\\]+)\\') { $server = $Matches[1] }

    if ($Mode -eq 'Skip') {
        Write-Info "Mode Skip -- partages geres par startnet.cmd"
        if (Test-Path $NetworkShare -ErrorAction SilentlyContinue) {
            Write-OK "Partage $NetworkShare accessible"
            return $true
        }
        Write-Warn "Partage $NetworkShare inaccessible (mode Skip)"
        return $false
    }

    Import-DeployModule 'NetShare'

    # Diagnostic ping avant tentative SMB
    if ($server -and $server -ne 'SERVEUR') {
        $pingTarget = $server
        $pingOk = $false
        try {
            $pingResult = & ping -n 1 -w 1000 $pingTarget 2>&1 | Out-String
            $pingOk = $pingResult -match 'TTL='
        } catch {}
        if ($pingOk) {
            Write-Info "[NetShare] Ping $pingTarget : OK"
        } else {
            Write-Warn "[NetShare] Ping $pingTarget : ECHEC -- serveur inaccessible ou ICMP bloque"
            Write-Warn "[NetShare] Verifier : routage reseau, VLAN, pare-feu sur le serveur de deploiement"
        }
    }

    # Fallback IP : depuis le parametre -NetworkShareFallback (resolu au build)
    # OU par resolution DNS en temps reel
    $serverIP = $null
    if ($NetworkShareFallback -match '\\\\([\d.]+)\\') {
        $serverIP = $Matches[1]
        Write-Info "[NetShare] IP fallback pre-resolue au build : $serverIP"
    } elseif ($server -and $server -ne 'SERVEUR') {
        try {
            $dns = [System.Net.Dns]::GetHostAddresses($server) |
                   Where-Object { $_.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetwork } |
                   Select-Object -First 1
            if ($dns) {
                $serverIP = $dns.IPAddressToString
                Write-Info "[NetShare] Serveur $server resolu en direct : $serverIP"
            }
        } catch {
            Write-Warn "[NetShare] Resolution DNS $server echouee"
        }
    }

    try {
        $nsParams = @{ Mode = $Mode }
        if ($server)   { $nsParams.Server             = $server }
        if ($serverIP) { $nsParams.ServerIPFallback    = $serverIP }
        if ($User)     { $nsParams.Username      = $User }
        if ($Pass)     { $nsParams.SharePassword = $Pass }
        if ($VaultPwd) { $nsParams.VaultPassword = $VaultPwd }

        # Localisation du vault WinPE
        # VaultPath param > X:\Deploy > DeployRoot
        $vaultCandidates = @()
        if ($VaultPath) { $vaultCandidates += $VaultPath }
        $vaultCandidates += 'X:\Deploy\secrets.vault.psd1'
        $vaultCandidates += 'X:\Deploy\secrets.vault'
        $vaultCandidates += (Join-Path $DeployRoot 'secrets.vault.psd1')
        $vaultCandidates += (Join-Path $DeployRoot 'secrets.vault')
        foreach ($vp in $vaultCandidates) {
            if (Test-Path $vp -ErrorAction SilentlyContinue) { $nsParams.VaultPath = $vp; break }
        }

        $result = Connect-DeployShare @nsParams
        return ($result.ConnectedShares.Count -gt 0)
    } catch {
        # Retry avec IP fallback si disponible
        if ($serverIP) {
            Write-Warn "Connexion par nom echouee -- retry via IP : $serverIP"
            try {
                $nsParamsIP = @{ Mode = $Mode }
                $nsParamsIP.Server = $serverIP
                if ($User)     { $nsParamsIP.Username      = $User }
                if ($Pass)     { $nsParamsIP.SharePassword = $Pass }
                if ($VaultPwd) { $nsParamsIP.VaultPassword = $VaultPwd }
                if ($nsParams.VaultPath) { $nsParamsIP.VaultPath = $nsParams.VaultPath }
                $result2 = Connect-DeployShare @nsParamsIP
                if ($result2.ConnectedShares.Count -gt 0) {
                    Write-OK "Connexion etablie via IP fallback : $serverIP"
                    return $true
                }
            } catch {
                Write-Err "Retry IP aussi echoue : $_"
            }
        }
        Write-Err "Connexion partages echouee : $_"
        Write-Warn "Deploiement possible si partages accessibles par autre moyen."
        return $false
    }
}

# -----------------------------------------------------------------------------
# FONCTIONS LOCALES
# -----------------------------------------------------------------------------


function Invoke-ScratchWizard {
    <#
    Assistant interactif WinPE -- retourne le chemin du PSD1 genere.
    IMPORTANT : toutes les sorties parasites doivent etre supprimees avec | Out-Null
    car cette fonction est appelee via $path = Invoke-ScratchWizard
    #>

    # Charger DiskSelector
    $dsMod = Join-Path $ModulesRoot 'DiskSelector\DiskSelector.psm1'
    if (Test-Path $dsMod -EA SilentlyContinue) {
        Import-Module $dsMod -Force -EA SilentlyContinue | Out-Null
    }

    Write-Host ""
    Write-Info "Deploiement interactif -- repondez aux questions."
    Write-Host ""

    # Detecter le mode avance : lire directement le PSD1 de config (WinPE n'a pas le module Config)
    $advancedMode = $false
    $cfgCandidates = @(
        "$NetworkShare\PSWinDeploy.psd1",
        'X:\Deploy\PSWinDeploy.psd1',
        'C:\Deploy\PSWinDeploy.psd1'
    )
    if (Get-Command Resolve-PSWDShareHost -EA SilentlyContinue) {
        $cfgCandidates = @($cfgCandidates | ForEach-Object { Resolve-PSWDShareHost -Path $_ })
    }
    foreach ($cfgP in $cfgCandidates) {
        if ($cfgP -and (Test-Path $cfgP -EA SilentlyContinue)) {
            try {
                $wc = Import-PowerShellDataFile $cfgP -EA Stop
                if ($wc.ContainsKey('AdvancedMode')) {
                    $advancedMode = [bool]$wc['AdvancedMode']
                    if ($advancedMode) { Write-Info "Mode avance ACTIF (depuis $cfgP)" }
                }
                break
            } catch {}
        }
    }
    $advNoAutoLogon = $false
    $advSkipUnattend = $false
    $advNoPhase2 = $false
    $advCopyUnattend = $false
    $advNoReboot = $false
    $advNoCopyDeploy = $false
    $advNoRunOnce = $false

    # Le mode avance est determine UNIQUEMENT par la config (AdvancedMode dans
    # PSWinDeploy.psd1). Plus de demande interactive : gain d'interaction.
    if ($advancedMode) { Write-Info "Mode avance ACTIF (options de diagnostic disponibles)." }

    # ?? 1. IMAGE OS ?????????????????????????????????????????????????????????
    Write-Step "Etape 1/5 -- Image Windows"
    $selectedWim   = ''
    $selectedIndex = 1
    $imgSharePath  = if ((Get-Variable -Name 'ImageShare' -Scope Script -EA SilentlyContinue) -and $script:ImageShare) { $script:ImageShare } else { "$NetworkShare\Images" }
    # Resoudre le chemin si basculement DNS->IP (le catalogue peut contenir le nom DNS)
    if (Get-Command Resolve-PSWDShareHost -EA SilentlyContinue) {
        $imgSharePath = Resolve-PSWDShareHost -Path $imgSharePath
    }

    # Lire catalogue ou scanner les WIM
    $osImages = @()
    $catPath  = Join-Path $imgSharePath 'os-catalogue.psd1'
    if (Test-Path $catPath -EA SilentlyContinue) {
        try {
            $cat = Import-PowerShellDataFile $catPath -EA Stop
            if ($cat.Images) { $osImages = @($cat.Images) }
        } catch {}
    }
    if ($osImages.Count -eq 0 -and (Test-Path $imgSharePath -EA SilentlyContinue)) {
        $osImages = @(Get-ChildItem $imgSharePath -Filter '*.wim' -EA SilentlyContinue |
                      ForEach-Object { @{ Name=$_.BaseName; FileName=$_.Name; FullPath=$_.FullName; SizeGB=[Math]::Round($_.Length/1GB,1) } })
    }

    if ($osImages.Count -gt 0) {
        Write-Host ""
        for ($i = 0; $i -lt $osImages.Count; $i++) {
            $img  = $osImages[$i]
            $name = if ($img.Name)   { $img.Name }   else { $img.FileName }
            $size = if ($img.SizeGB) { "  ($($img.SizeGB) GB)" } else { '' }
            Write-Host "  [$($i+1)] $name$size" -ForegroundColor White
        }
        Write-Host ""
        Write-Host "  [?]  Image [1] : " -ForegroundColor Yellow -NoNewline
        $c = (Read-Host).Trim()
        $idx = if ($c -match '^\d+$' -and [int]$c -ge 1 -and [int]$c -le $osImages.Count) { [int]$c - 1 } else { 0 }
        $img = $osImages[$idx]

        $selectedWim = if ($img.FullPath) { $img.FullPath }
                       elseif ($img.FilePath) { $img.FilePath }
                       else { Join-Path $imgSharePath $img.FileName }
        # Resoudre le chemin si basculement DNS->IP
        if (Get-Command Resolve-PSWDShareHost -EA SilentlyContinue) {
            $selectedWim = Resolve-PSWDShareHost -Path $selectedWim
        }
        # Normaliser les backslashes multiples (catalogue peut contenir des doublons)
        $isUncWim = $selectedWim.StartsWith('\\')
        while ($selectedWim.Contains('\\')) { $selectedWim = $selectedWim.Replace('\\', '\') }
        if ($isUncWim -and -not $selectedWim.StartsWith('\\')) { $selectedWim = '\' + $selectedWim }

        # Editions disponibles
        try {
            $eds = @(Get-WindowsImage -ImagePath $selectedWim -EA SilentlyContinue)
            if ($eds.Count -gt 1) {
                Write-Host ""
                foreach ($ed in $eds) {
                    Write-Host "  [$($ed.ImageIndex)] $($ed.ImageName)" -ForegroundColor White
                }
                Write-Host "  [?]  Edition [1] : " -ForegroundColor Yellow -NoNewline
                $ei = (Read-Host).Trim()
                $selectedIndex = if ($ei -match '^\d+$') { [int]$ei } else { 1 }
            }
        } catch {}
        $imgName = if ($img.Name) { $img.Name } else { $img.FileName }
        Write-OK "Image : $imgName  Edition $selectedIndex"
    } else {
        Write-Warn "Aucune image WIM sur $imgSharePath"
        Write-Host "  [?]  Chemin UNC vers le .wim : " -ForegroundColor Yellow -NoNewline
        $selectedWim = (Read-Host).Trim().Trim('"').Trim("'")
    }

    # ?? 2. NOM MACHINE ???????????????????????????????????????????????????????
    Write-Host ""; Write-Step "Etape 2/5 -- Identite"
    Write-Host "  [i]  Laissez VIDE pour que Windows genere un nom aleatoire unique." -ForegroundColor DarkGray
    Write-Host "       (recommande pour deploiements multiples avec jonction AD)" -ForegroundColor DarkGray
    Write-Host "  [?]  Nom de la machine [auto] : " -ForegroundColor Yellow -NoNewline
    $machineName = (Read-Host).Trim()
    if ([string]::IsNullOrWhiteSpace($machineName)) {
        $machineName = ''
        Write-OK "Machine : (nom genere automatiquement par Windows)"
    } else {
        Write-OK "Machine : $machineName"
    }

    # ?? 3. DOMAINE ????????????????????????????????????????????????????????????
    # La jonction au domaine NE se demande PLUS ici (phase 1). Elle se fait en
    # phase 2 via un step JoinDomain dans la sequence du poste, ou via l'assistant
    # interactif (option "Construire a la volee"). Plus simple et coherent.
    $joinDomain = $false
    $domainName = ''
    $domainOU   = ''

    # ?? 4. CONFIG ?????????????????????????????????????????????????????????????
    Write-Host ""; Write-Step "Etape 4/5 -- Configuration"
    # Les mises a jour Windows sont desormais gerees par les scripts PostDeploy
    # (Scripts\PostDeploy\10-windows-update.ps1), executes en phase 2. Plus
    # besoin de le demander ici.
    Write-Host "  [i]  MAJ Windows : gerees par les scripts post-deploiement (phase 2)" -ForegroundColor DarkGray

    $selectedApps    = @()
    $selectedScripts = @()
    # Les applications et scripts NE sont PLUS demandes ici (phase 1). Tout se
    # configure en phase 2 : soit une sequence affectee au poste (by-name /
    # by-mac / _default), soit l'assistant interactif apres le reboot.
    # On INFORME juste si une sequence est deja affectee a ce poste.
    try {
        $seqDirInfo = Get-Cfg 'SequencesPath'
        if ($seqDirInfo -and (Get-Command Test-PostInstallSequenceExists -EA SilentlyContinue)) {
            $seqInfo = Test-PostInstallSequenceExists -SeqDir $seqDirInfo
            if ($seqInfo.Found) {
                Write-OK "Sequence de phase 2 affectee a ce poste : $($seqInfo.By) -> $(Split-Path $seqInfo.Path -Leaf)"
            } else {
                Write-Info "Aucune sequence affectee a ce poste. L'assistant sera propose apres le reboot."
            }
        }
    } catch {}

    # ?? 5. DISQUE ?????????????????????????????????????????????????????????????
    # ?? OPTIONS AVANCEES (mode avance uniquement) ??????????????????????????????
    if ($advancedMode) {
        Write-Host ""
        Write-Host "  +-----------------------------------------------------------+" -ForegroundColor Yellow
        Write-Host "  |              OPTIONS AVANCEES (diagnostic)                |" -ForegroundColor Yellow
        Write-Host "  +-----------------------------------------------------------+" -ForegroundColor Yellow
        Write-Host "  Ces options servent a diagnostiquer les problemes de boot (BSOD)." -ForegroundColor DarkGray
        Write-Host ""
        Write-Host "  [?]  Desactiver l'autologon unattend ? [o/N]" -ForegroundColor Yellow -NoNewline
        Write-Host "  (teste si l'autologon cause le BSOD) : " -ForegroundColor DarkGray -NoNewline
        $advNoAutoLogon = (Read-Host).Trim().ToLower() -in @('o','oui','y','yes')

        Write-Host "  [?]  Sauter completement l'unattend ? [o/N]" -ForegroundColor Yellow -NoNewline
        Write-Host "  (deploie le WIM brut, OOBE standard) : " -ForegroundColor DarkGray -NoNewline
        $advSkipUnattend = (Read-Host).Trim().ToLower() -in @('o','oui','y','yes')

        Write-Host "  [?]  Deployer SANS lancer la phase 2 ? [o/N]" -ForegroundColor Yellow -NoNewline
        Write-Host "  (autologon OK, mais ne lance pas Start-Deploy -Resume) : " -ForegroundColor DarkGray -NoNewline
        $advNoPhase2 = (Read-Host).Trim().ToLower() -in @('o','oui','y','yes')

        Write-Host "  [?]  Copier l'unattend genere pour debug ? [o/N]" -ForegroundColor Yellow -NoNewline
        Write-Host "  (sauve une copie horodatee sur le partage) : " -ForegroundColor DarkGray -NoNewline
        $advCopyUnattend = (Read-Host).Trim().ToLower() -in @('o','oui','y','yes')

        Write-Host "  [?]  PAS de reboot automatique en fin de deploiement ? [o/N]" -ForegroundColor Yellow -NoNewline
        Write-Host "  (tu lanceras 'wpeutil reboot' toi-meme -- diagnostic) : " -ForegroundColor DarkGray -NoNewline
        $advNoReboot = (Read-Host).Trim().ToLower() -in @('o','oui','y','yes')

        Write-Host "  --- Diagnostic BSOD : desactiver des operations suspectes ---" -ForegroundColor DarkCyan
        Write-Host "  [?]  NE PAS copier Deploy sur la cible (Copy-DeployToTarget) ? [o/N] : " -ForegroundColor Yellow -NoNewline
        $advNoCopyDeploy = (Read-Host).Trim().ToLower() -in @('o','oui','y','yes')

        Write-Host "  [?]  NE PAS configurer RunOnce (manip ruche offline) ? [o/N] : " -ForegroundColor Yellow -NoNewline
        $advNoRunOnce = (Read-Host).Trim().ToLower() -in @('o','oui','y','yes')

        if ($advNoAutoLogon) { Write-Warn "Autologon DESACTIVE pour ce deploiement (diagnostic)" }
        if ($advSkipUnattend) { Write-Warn "Unattend SAUTE pour ce deploiement (test WIM brut)" }
        if ($advNoPhase2)     { Write-Warn "Phase 2 NON lancee (autologon temoin seulement)" }
        if ($advCopyUnattend) { Write-Warn "L'unattend genere sera copie sur le partage pour debug" }
        if ($advNoReboot)     { Write-Warn "PAS de reboot auto -- tu devras taper 'wpeutil reboot' manuellement" }
        if ($advNoCopyDeploy) { Write-Warn "Copy-DeployToTarget DESACTIVE (diagnostic) -- phase 2 indisponible" }
        if ($advNoRunOnce)    { Write-Warn "Set-DeployRunOnce DESACTIVE (diagnostic) -- pas de manip ruche offline" }
    }

    Write-Host ""; Write-Step "Etape 5/5 -- Disque cible"
    Show-DiskSummary | Out-Null
    $diskNum = Select-TargetDisk

    # ?? RECAPITULATIF + CONFIRMATION ??????????????????????????????????????????
    Write-Host ""
    Write-Host "  +----------------------------------------------------------+" -ForegroundColor Cyan
    Write-Host "  |                   RECAPITULATIF                          |" -ForegroundColor Cyan
    Write-Host "  +----------------------------------------------------------+" -ForegroundColor Cyan
    Write-Host "  Image   : $(Split-Path $selectedWim -Leaf)  [index $selectedIndex]" -ForegroundColor White
    Write-Host "  Machine : $machineName" -ForegroundColor White
    Write-Host "  Domaine : $(if($domainName){$domainName}else{'Standalone'})" -ForegroundColor White
    if ($advancedMode -and ($advNoAutoLogon -or $advSkipUnattend -or $advNoPhase2 -or $advCopyUnattend -or $advNoReboot -or $advNoCopyDeploy -or $advNoRunOnce)) {
        $advTxt = @()
        if ($advSkipUnattend) { $advTxt += 'sans unattend' }
        if ($advNoAutoLogon)  { $advTxt += 'sans autologon' }
        if ($advNoPhase2)     { $advTxt += 'sans phase 2' }
        if ($advCopyUnattend) { $advTxt += 'copie unattend debug' }
        if ($advNoReboot)     { $advTxt += 'sans reboot auto' }
        if ($advNoCopyDeploy) { $advTxt += 'sans copy-deploy' }
        if ($advNoRunOnce)    { $advTxt += 'sans runonce' }
        Write-Host "  AVANCE  : $($advTxt -join ', ')" -ForegroundColor Yellow
    }
    Write-Host "  Disque  : $diskNum  [SERA EFFACE]" -ForegroundColor Red
    Write-Host ""
    Write-Host "  [?]  CONFIRMER ? [o/N] : " -ForegroundColor Red -NoNewline
    if (-not ((Read-Host).Trim().ToLower() -in @('o','oui','y','yes'))) {
        Write-Warn "Annule."
        exit 0
    }

    # ?? GENERATION PSD1 ???????????????????????????????????????????????????????
    $seqTs   = Get-Date -Format 'HHmmss-fff'
    $seqId   = "scratch-$seqTs"
    $seqName = "Scratch $machineName"
    $tmpDir  = if (Test-Path 'X:\Windows\Temp' -EA SilentlyContinue) { 'X:\Windows\Temp' } else { $env:TEMP }
    $tmpSeq  = Join-Path $tmpDir "$seqId.psd1"

    # Construire les steps
    $wimEsc = $selectedWim.Replace("'", "''")
    $pLines = @(
        '@{'
        "    Id      = '$seqId'"
        "    Name    = '$seqName'"
        "    Version = '1.0'"
        "    metadata = @{ noReboot = `$$(if($advNoReboot){'true'}else{'false'}); noCopyDeploy = `$$(if($advNoCopyDeploy){'true'}else{'false'}); noRunOnce = `$$(if($advNoRunOnce){'true'}else{'false'}) }"
        '    Steps   = @('
        # FormatDisk
        '        @{'
        "            Id      = 's01'"
        "            Name    = 'Partitionner le disque'"
        "            Type    = 'FormatDisk'"
        '            Enabled = $true'
        '            Params  = @{'
        "                diskNumber   = $diskNum"
        "                firmwareType = 'UEFI'"
        '            }'
        '        }'
        # ApplyWIM
        '        @{'
        "            Id      = 's02'"
        "            Name    = 'Appliquer Windows'"
        "            Type    = 'ApplyWIM'"
        '            Enabled = $true'
        '            Params  = @{'
        "                wimPath     = '$wimEsc'"
        "                index       = $selectedIndex"
        "                targetDrive = 'W:'"
        '            }'
        '        }'
    )

    # ApplyUnattend : nom + domaine via answer file (au lieu de SetComputerName + JoinDomain)
    # Mode avance : sauter completement l'unattend si demande (test WIM brut)
    if (-not $advSkipUnattend) {
        $pLines += '        @{'
        $pLines += "            Id      = 's03'"
        $pLines += "            Name    = 'Configuration Windows (unattend)'"
        $pLines += "            Type    = 'ApplyUnattend'"
        $pLines += '            Enabled = $true'
        $pLines += '            Params  = @{'
        $pLines += "                targetDrive = 'W:'"
        if ($machineName) {
            $mnEsc = $machineName.Replace("'", "''")
            $pLines += "                computerName = '$mnEsc'"
        }
        # NOTE : la jonction au domaine NE passe PLUS par l'unattend (fragile).
        # Elle est faite par une sequence JoinDomain en phase 2 (plus fiable).
        # On ne met donc PAS domain/ou ici.
        # Mode avance : desactiver l'autologon (diagnostic BSOD)
        if ($advNoAutoLogon) {
            $pLines += '                noAutoLogon = $true'
        } elseif ($advNoPhase2) {
            # Autologon OK mais on NE lance PAS la phase 2 : on met une commande
            # temoin inoffensive (comme le test qui boote). Permet d'isoler si
            # c'est la phase 2 (Start-Deploy -Resume) qui cause le BSOD.
            $pLines += "                phase2Command = 'cmd /c echo PHASE2-DESACTIVEE-MODE-AVANCE > C:\phase2-skipped.txt'"
        } else {
            $pLines += "                phase2Command = 'powershell -NoProfile -ExecutionPolicy Bypass -File C:\Deploy\Scripts\Start-Deploy.ps1 -Resume'"
        }
        # Mode avance : demander la copie de l'unattend genere pour debug
        if ($advCopyUnattend) {
            $pLines += '                debugCopyUnattend = $true'
        }
        $pLines += '            }'
        $pLines += '        }'
    } else {
        Write-Warn "Step ApplyUnattend non genere (mode avance : skipUnattend)" | Out-Null
    }

    # (MAJ Windows : desormais via scripts PostDeploy en phase 2, plus de step ici)

    # InstallApps (optionnel)
    if ($selectedApps.Count -gt 0) {
        $appsEscaped = @()
        foreach ($a in $selectedApps) {
            $aEsc = $a.Replace("'", "''")
            $appsEscaped += "'$aEsc'"
        }
        $appsStr = $appsEscaped -join ', '
        $pLines += '        @{'
        $pLines += "            Id      = 's06'"
        $pLines += "            Name    = 'Installer les applications'"
        $pLines += "            Type    = 'InstallApps'"
        $pLines += '            Enabled = $true'
        $pLines += "            Params  = @{ apps = @($appsStr) }"
        $pLines += '        }'
    }

    # Scripts (optionnel)
    $sIdx = 7
    foreach ($sp in $selectedScripts) {
        $spEsc = $sp -replace "'", "''"
        $pLines += "        @{ Id='s0$sIdx'; Name='Script post-deploiement'; Type='RunScript'; Enabled=`$true; Params=@{ path='$spEsc' } }"
        $sIdx++
    }

    # Reboot final (sauf si mode avance 'pas de reboot auto')
    if ($advNoReboot) {
        Write-Warn "Step Reboot final NON genere -- tu devras taper 'wpeutil reboot' a la fin"
    } else {
        $pLines += "        @{ Id='s99'; Name='Redemarrage'; Type='Reboot'; Enabled=`$true; Params=@{ delaySeconds=10 } }"
    }
    $pLines += '    )'
    $pLines += '}'

    # ================= CHEMIN SIMPLE (lineaire, sans TaskSequence) =================
    # Par defaut on utilise le deploiement SIMPLE : il reproduit exactement le test
    # qui BOOTE (Test-ModuleDirect), sans dispatcher ni gestion d'etat complexe.
    # Beaucoup plus fiable et debogable.
    # Phase 1 = TOUJOURS SIMPLE (lineaire). Le mode TaskSequence en WinPE causait
    # un BSOD ; la TaskSequence s'execute desormais en phase 2 (Windows). Plus de
    # choix a faire ici.
    $useSimple = $true

    if ($useSimple) {
        Write-OK "Phase 1 : deploiement SIMPLE (lineaire)"
        # Importer le module SimpleDeploy
        # Resoudre le dossier Modules sans dependre d'une variable script (StrictMode).
        # En WinPE les scripts sont dans X:\Deploy\Scripts et les modules X:\Deploy\Modules.
        $modulesDir = Join-Path (Split-Path $PSScriptRoot -Parent) 'Modules'
        if (-not (Test-Path $modulesDir -EA SilentlyContinue)) {
            foreach ($cand in @('X:\Deploy\Modules','C:\Deploy\Modules')) {
                if (Test-Path $cand -EA SilentlyContinue) { $modulesDir = $cand; break }
            }
        }
        $sdMod = Join-Path $modulesDir 'SimpleDeploy\SimpleDeploy.psm1'
        if (-not (Test-Path $sdMod)) { $sdMod = Join-Path (Split-Path $PSScriptRoot -Parent) 'Modules\SimpleDeploy\SimpleDeploy.psm1' }
        Import-Module $sdMod -Force

        # Construire les parametres unattend (sauf si skip)
        $uParams = @{}
        if (-not $advSkipUnattend) {
            # ComputerName : obligatoire pour New-UnattendXml. Si vide, generer WIN-xxxxx
            if ($machineName) {
                $uParams.ComputerName = $machineName
            } else {
                $suffix = -join ((48..57) + (65..90) | Get-Random -Count 7 | ForEach-Object { [char]$_ })
                $uParams.ComputerName = "WIN-$suffix"
            }
            # Mot de passe admin local : lire le vault directement (autonome).
            # IMPORTANT : on lit UNIQUEMENT la cle 'localAdminPassword'. On NE
            # retombe PAS sur winpePassword (= mot de passe du compte de service
            # WinPE, RIEN A VOIR avec l'admin local de la machine deployee).
            # Confondre les deux donnait un mauvais mot de passe (Azerty18).
            $localPwd = $null
            # Chercher le vault, quel que soit son nom (avec ou sans .psd1).
            $vaultCandidates = @(
                'X:\Deploy\secrets.vault.psd1', 'X:\Deploy\secrets.vault',
                'C:\Deploy\secrets.vault.psd1', 'C:\Deploy\secrets.vault',
                (Join-Path (Split-Path $modulesDir -Parent) 'secrets.vault.psd1'),
                (Join-Path (Split-Path $modulesDir -Parent) 'secrets.vault')
            )
            foreach ($vc in $vaultCandidates) {
                if ($vc -and (Test-Path $vc -EA SilentlyContinue)) {
                    try {
                        # Import-PowerShellDataFile lit le CONTENU PSD1 quel que
                        # soit le nom de fichier (l'extension n'a pas d'importance).
                        $vht = Import-PowerShellDataFile $vc -EA Stop
                        if ($vht.ContainsKey('localAdminPassword') -and $vht['localAdminPassword']) {
                            $localPwd = $vht['localAdminPassword']
                            Write-OK "Mot de passe admin local lu depuis le vault : $vc"
                            break
                        }
                    } catch {
                        Write-Warn "Lecture vault echouee ($vc) : $_"
                    }
                }
            }
            if ($localPwd) {
                $uParams.LocalAdminPassword = $localPwd
            } else {
                Write-Warn "Cle 'localAdminPassword' introuvable dans le vault."
                Write-Warn "Le mot de passe par defaut du module sera utilise."
                Write-Warn "Ajoute 'localAdminPassword = ...' dans secrets.vault."
            }

            # Autologon + phase 2 : pour enchainer la phase 2, il faut l'autologon.
            # L'autologon s'active en passant AutoLogonUser + AutoLogonPassword.
            if ($advNoAutoLogon) {
                # Pas d'autologon : on ne passe ni AutoLogonUser ni FirstLogonCommand
            } else {
                $uParams.AutoLogonUser = 'Administrator'
                if ($localPwd) { $uParams.AutoLogonPassword = $localPwd }
                if ($advNoPhase2) {
                    $uParams.FirstLogonCommand = 'cmd /c echo PHASE2-DESACTIVEE > C:\phase2-skipped.txt'
                } else {
                    # Lancer la phase 2 dans une FENETRE POWERSHELL VISIBLE (pas un
                    # cmd noir muet) : l'operateur voit le deroulement. On cree le
                    # dossier Logs, on demarre une transcription (pour garder une
                    # trace meme si la fenetre se ferme), puis on lance la reprise.
                    # 'start' detache une vraie fenetre powershell de la session OOBE.
                    $p2Cmd = 'mkdir C:\Deploy\Logs 2>nul & start "" powershell -NoExit -NoProfile -ExecutionPolicy Bypass -Command "Start-Transcript -Path C:\Deploy\Logs\phase2-boot.log -Append; & C:\Deploy\Scripts\Start-Deploy.ps1 -Resume"'
                    $uParams.FirstLogonCommand = "cmd /c `"$p2Cmd`""
                }
            }
            # Jonction domaine : faite par sequence JoinDomain en phase 2 (pas unattend).
        }

        # -- Sequence de PHASE 2 : RESOLUE APRES LE REBOOT, pas ici. --
        # En phase 2 (Windows), la sequence est resolue par MAC (by-mac\<MAC>.psd1)
        # ou _default.psd1 sur le partage, OU via l'assistant interactif. On ne
        # choisit plus rien en WinPE : pas de menu, pas de recherche ici.
        $phase2Seq = ''
        # La jonction au domaine est un STEP 'JoinDomain' a placer dans la sequence
        # du poste (by-name / by-mac / _default), PAS une sequence separee generee
        # ici. C'est plus simple et coherent : un seul fichier, un seul flux.
        if ($joinDomain -and $domainName) {
            Write-Info "Jonction domaine demandee : ajoutez un step 'JoinDomain' en 1er"
            Write-Info "dans votre sequence (by-name/by-mac/_default). Le domaine/OU sont"
            Write-Info "lus depuis PSWinDeploy.psd1 (DomainName/DomainOU)."
        }
        Write-Info "Sequence de phase 2 : resolue apres le reboot (par nom / MAC / _default / assistant)."

        # Config pour la phase 2 : on transmet le serveur + l'IP. Les chemins
        # detailles viennent de PSWinDeploy.psd1 (copie sur la cible).
        $deployCfg = @{
            NetworkShare = $NetworkShare
        }
        if ($NetworkShareFallback) { $deployCfg.NetworkShareFallback = $NetworkShareFallback }
        if ($ImageShare)           { $deployCfg.ImageShare = $ImageShare }
        # Reporter les chemins LOGIQUES depuis PSWinDeploy.psd1 (source unique).
        # Relire la config projet ici (scope sur, independant du reste).
        $projCfg = @{}
        foreach ($cp in @("$NetworkShare\PSWinDeploy.psd1", 'X:\Deploy\PSWinDeploy.psd1', 'C:\Deploy\PSWinDeploy.psd1')) {
            $cpr = if (Get-Command Resolve-Share -EA SilentlyContinue) { Resolve-Share $cp } else { $cp }
            if ($cpr -and (Test-Path $cpr -EA SilentlyContinue)) {
                try { $projCfg = Import-PowerShellDataFile $cpr -EA Stop; break } catch {}
            }
        }
        $srvName = ''
        if ($NetworkShare -match '\\\\([^\\]+)\\') { $srvName = $Matches[1] }
        if ($srvName) { $deployCfg.Server = $srvName }
        # Chemins logiques (peuvent etre des string OU des @{DNS;IP}) -- on les
        # reporte tels quels ; Resolve-Share les resoudra en phase 2.
        foreach ($key in @('SequencesPath','ScriptShare','SoftwareShare','CataloguePath','ProfilesPath','DeployShare','ImageShare','DriverShare','LogShare')) {
            if ($projCfg.ContainsKey($key) -and $projCfg[$key]) { $deployCfg[$key] = $projCfg[$key] }
        }
        # Table de mapping nom DNS -> IP. Priorite : WinPEShareServerIP de la config.
        $hostMap = @{}
        if ($srvName -and $projCfg.ContainsKey('WinPEShareServerIP') -and $projCfg['WinPEShareServerIP']) {
            $hostMap[$srvName] = $projCfg['WinPEShareServerIP']
        } elseif ($srvName -and $NetworkShareFallback -match '\\\\([\d.]+)\\') {
            $hostMap[$srvName] = $Matches[1]
        }
        if ($hostMap.Count -gt 0) { $deployCfg.ShareHostMap = $hostMap }
        # Trace : montrer ce qui sera transmis a la phase 2
        Write-Info "Config phase 2 : Share=$NetworkShare Fallback=$(if($NetworkShareFallback){$NetworkShareFallback}else{'(aucun)'})"
        if (-not $NetworkShareFallback) {
            Write-Warn "Pas d'IP fallback : si le DNS ne resout pas en phase 2, l'acces au partage echouera."
        }

        Invoke-SimpleDeploy -WimPath $selectedWim -Index $selectedIndex -DiskNumber $diskNum `
            -UnattendParams $uParams -CopyDeploy:(-not $advNoCopyDeploy) -NoReboot:$advNoReboot `
            -ModulesRoot $modulesDir -SequencePath $phase2Seq -DeployConfig $deployCfg

        # Retourner un marqueur : le flux principal ne doit PAS lancer la TaskSequence
        return 'SIMPLE-DONE'
    }
    # ================= FIN CHEMIN SIMPLE =================

    # Ecrire avec BOM UTF-8
    $utf8Bom = New-Object System.Text.UTF8Encoding $true
    [System.IO.File]::WriteAllText($tmpSeq, ($pLines -join "`r`n"), $utf8Bom)

    if (-not (Test-Path $tmpSeq -EA SilentlyContinue)) {
        throw "Echec creation PSD1 : $tmpSeq"
    }

    Write-OK "Sequence PSD1 generee : $seqId ($(@($pLines | Where-Object { $_ -match ""Type\s*=""}).Count) etapes)"
    return $tmpSeq
}

function Write-Banner {
    $v = '0.2.0'

# =============================================================================
# ASSISTANT FROM SCRATCH -- WinPE interactif style MDT
# =============================================================================

    Clear-Host
    Write-Host ""
    Write-Host "  ######+ #######+##+    ##+##+###+   ##+######+ #######+######+ ##+      ######+ ##+   ##+" -ForegroundColor Cyan
    Write-Host "  ##+==##+##+====+##|    ##|##|####+  ##|##+==##+##+====+##+==##+##|     ##+===##++##+ ##++" -ForegroundColor Cyan
    Write-Host "  ######++#######+##| #+ ##|##|##+##+ ##|##|  ##|#####+  ######++##|     ##|   ##| +####++ " -ForegroundColor Cyan
    Write-Host "  ##+===+ +====##|##|###+##|##|##|+##+##|##|  ##|##+==+  ##+===+ ##|     ##|   ##|  +##++  " -ForegroundColor DarkCyan
    Write-Host "  ##|     #######|+###+###++##|##| +####|######++#######+##|     #######++######++   ##|   " -ForegroundColor DarkCyan
    Write-Host "  +=+     +======+ +==++==+ +=++=+  +===++=====+ +======++=+     +======+ +=====+    +=+   " -ForegroundColor DarkCyan
    Write-Host ""
    Write-Host "  Remplacement MDT -- Deploiement Windows moderne en PowerShell   v$v" -ForegroundColor Gray
    Write-Host ""
}

function Write-Step { param([string]$Msg) Write-Host "  [>>] $Msg" -ForegroundColor Magenta }
function Write-Info { param([string]$Msg) Write-Host "  [~]  $Msg" -ForegroundColor Cyan }
function Write-OK   { param([string]$Msg) Write-Host "  [OK] $Msg" -ForegroundColor Green }
function Write-Warn { param([string]$Msg) Write-Host "  [!]  $Msg" -ForegroundColor Yellow }
function Write-Err  { param([string]$Msg) Write-Host "  [X]  $Msg" -ForegroundColor Red }

function Test-IsWinPE {
    <#Detecte si on tourne dans WinPE (X: existe, pas de C:\Windows\System32)#>
    return (Test-Path 'X:\Windows') -or
           ($env:SystemDrive -eq 'X:') -or
           (-not (Test-Path 'C:\Windows\System32\ntoskrnl.exe'))
}

function Initialize-Network {
    <#Lance wpeinit si WinPE et attend la connexion reseau#>
    if (Test-IsWinPE) {
        Write-Info "WinPE detecte -- initialisation reseau (wpeinit)..."
        try { & wpeinit.exe 2>&1 | Out-Null; Start-Sleep 3 }
        catch { Write-Warn "wpeinit non disponible" }
    }

    # Attente interface reseau active (max 30s)
    # Get-NetAdapter n est pas disponible en WinPE -- utiliser WMI
    $timeout = 30; $elapsed = 0
    while ($elapsed -lt $timeout) {
        # Methode 1 : WMI (disponible dans WinPE si WinPE-WMI installe)
        $nic = $null
        try {
            $nic = Get-WmiObject Win32_NetworkAdapter -ErrorAction SilentlyContinue |
                   Where-Object { $_.NetConnectionStatus -eq 2 -and $_.PhysicalAdapter -eq $true } |
                   Select-Object -First 1
        } catch {}

        # Methode 2 : netsh (toujours disponible en WinPE)
        if (-not $nic) {
            $ipconfig = & ipconfig 2>&1 | Out-String
            if ($ipconfig -match 'IPv4.*: \d+\.\d+\.\d+\.\d+') {
                Write-OK "Reseau actif (IPv4 detecte)"
                return $true
            }
        }

        if ($nic) {
            $nicName = $nic.Name
            Write-OK "Reseau : $nicName"
            return $true
        }

        Start-Sleep 3; $elapsed += 3
        Write-Info "Attente reseau... ($elapsed s / $timeout s)"
    }
    Write-Warn "Pas de reseau apres ${timeout}s"
    return $false
}



function Select-SequenceFile {
    <#
    Propose la liste des sequences et profils disponibles.
    Retourne le chemin du fichier choisi OU 'SCRATCH' pour l'assistant interactif.
    #>
    param([string]$SearchRoot)

    $sequences = @()

    # Chercher UNIQUEMENT dans Sequences\ et Profiles\ -- pas recursivement
    # (recurse attraperait les .psd1 des modules PowerShell)
    $searchDirs = @()
    foreach ($base in @($SearchRoot, $DeployRoot, 'X:\Deploy', 'D:\Deploy', 'C:\Deploy')) {
        if (Test-Path $base -ErrorAction SilentlyContinue) {
            $searchDirs += Join-Path $base 'Sequences'
            $searchDirs += Join-Path $base 'Profiles'
        }
    }

    $moduleNames = @('DiskSelector','NetShare','Notify','ProfileManager',
                     'TaskSequence','WIM-Manager','WinPE-Builder','Config')

    foreach ($dir in ($searchDirs | Select-Object -Unique)) {
        if (-not (Test-Path $dir -ErrorAction SilentlyContinue)) { continue }
        $found = @(Get-ChildItem $dir -Filter '*.psd1' -ErrorAction SilentlyContinue) +
                 @(Get-ChildItem $dir -Filter '*.psd1' -ErrorAction SilentlyContinue)
        foreach ($f in $found) {
            if ($moduleNames -contains $f.BaseName) { continue }
            if ($f.Name -match '^(state|config|secrets|catalogue)') { continue }
            $sequences += $f
        }
    }

    # ?? MENU ??????????????????????????????????????????????????????????????????
    Write-Host ""
    Write-Host "  +----------------------------------------------------------+" -ForegroundColor Cyan
    Write-Host "  |             SELECTION DU DEPLOIEMENT                     |" -ForegroundColor Cyan
    Write-Host "  +----------------------------------------------------------+" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "  [S] Deploiement  -- Assistant interactif (OS, disque, domaine)" -ForegroundColor Yellow
    Write-Host "       La post-installation (apps, MAJ, scripts) se fait en phase 2" -ForegroundColor DarkGray
    Write-Host "       via les sequences (by-name / by-mac / _default) ou l'assistant." -ForegroundColor DarkGray
    Write-Host ""
    Write-Host "  [C] Ligne de commande (shell PowerShell, partages montes)" -ForegroundColor DarkGray
    Write-Host "      Pour diagnostic, tests manuels, ou outils en ligne de commande" -ForegroundColor DarkGray
    Write-Host ""

    # En mode SIMPLE, la phase 1 ne deroule PAS de sequence (les sequences sont
    # de la phase 2). On ne propose donc que l'assistant de deploiement [S] ou
    # le shell [C]. Le choix de sequence a ete retire (n'avait plus de sens ici).
    while ($true) {
        Write-Host "  Choix [S=Deploiement / C=Commande] : " -ForegroundColor Yellow -NoNewline
        $sel = (Read-Host).Trim().ToUpper()
        if ($sel -eq 'S' -or $sel -eq '') { return 'SCRATCH' }
        if ($sel -eq 'C') { return 'SHELL' }
        Write-Warn "Choix invalide"
    }
}

# -----------------------------------------------------------------------------
# POINT D'ENTREE PRINCIPAL
# -----------------------------------------------------------------------------

# Trace BRUTE et precoce (surtout en -Resume/phase 2 ou tout plantage serait
# sinon invisible). Ecrit directement, sans dependre d'aucun module.
try {
    $bootTrace = 'C:\Deploy\Logs\phase2-trace.log'
    if ($Resume) {
        $td = Split-Path $bootTrace -Parent
        if (-not (Test-Path $td)) { New-Item -ItemType Directory $td -Force -EA SilentlyContinue | Out-Null }
        Add-Content $bootTrace "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] === Start-Deploy -Resume DEMARRE (PID $PID) ===" -EA SilentlyContinue
        Add-Content $bootTrace "  PSVersion=$($PSVersionTable.PSVersion) User=$env:USERNAME Machine=$env:COMPUTERNAME" -EA SilentlyContinue
    }
} catch {}

try {
    Write-Banner

    # ===================================================================
    # CONFIG SINGLETON : chargee UNE FOIS, lue partout via Get-Cfg.
    # Cherche PSWinDeploy.psd1 (partage/X:/C:), resout les @{DNS;IP} ->
    # chemin accessible, et fusionne deploy-config.psd1 (phase 2) par dessus.
    # Apres ca : Get-Cfg 'DeployShare' -> chemin string deja resolu, PARTOUT.
    # ===================================================================
    Import-DeployModule 'NetShare'   # pour Resolve-Share / ShareHostMap
    Import-DeployModule 'Config'
    # Priorite aux chemins LOCAUX (embarques/copies) : fiables sans reseau.
    # Le partage en dernier (peut ne pas resoudre le nom hors domaine).
    $script:CfgPaths = @(
        'X:\Deploy\PSWinDeploy.psd1',
        'C:\Deploy\PSWinDeploy.psd1',
        "$NetworkShare\PSWinDeploy.psd1"
    )
    $cfgFound = $null
    foreach ($cp in $script:CfgPaths) {
        if ($cp -and (Test-Path $cp -EA SilentlyContinue)) { $cfgFound = $cp; break }
    }
    try {
        if ($cfgFound) { Import-PSWinDeployConfig -ConfigPath $cfgFound -Force -ResolvePaths | Out-Null }
        else { Import-PSWinDeployConfig -ResolvePaths | Out-Null }
    } catch { Write-Warn "Config : $_" }
    # Fusionner deploy-config.psd1 (ecrit au deploiement, contient Server/IP/mapping)
    if (Test-Path 'C:\Deploy\deploy-config.psd1' -EA SilentlyContinue) {
        try {
            $dcfg0 = Import-PowerShellDataFile 'C:\Deploy\deploy-config.psd1'
            if ($dcfg0.ContainsKey('ShareHostMap') -and $dcfg0.ShareHostMap) {
                $mh0 = @{}; $shm0 = $dcfg0.ShareHostMap
                if ($shm0 -is [hashtable] -or $shm0 -is [System.Collections.IDictionary]) { foreach ($k in $shm0.Keys) { $mh0[$k] = $shm0[$k] } }
                else { foreach ($p in $shm0.PSObject.Properties) { $mh0[$p.Name] = $p.Value } }
                if ($mh0.Count -gt 0 -and (Get-Command Set-PSWDShareHostMap -EA SilentlyContinue)) { Set-PSWDShareHostMap -Map $mh0 }
            }
            # Surcharger les valeurs reseau utiles
            $ov = @{}
            foreach ($k in @('NetworkShare','NetworkShareFallback','Server')) { if ($dcfg0.ContainsKey($k) -and $dcfg0[$k]) { $ov[$k] = $dcfg0[$k] } }
            if ($ov.Count -gt 0) { Set-PSWinDeployConfig -Values $ov | Out-Null }
        } catch {}
    }
    # Accesseur court : Get-Cfg 'DeployShare'
    function Get-Cfg { param([string]$Key) try { return (Get-PSWinDeployConfig -Key $Key) } catch { return $null } }

    # Charger un eventuel profil de SURCHARGE GUI (Overrides\gui.ps1 dans Deploy).
    # S'il existe, il branche un provider UI (WinForms/WPF) et/ou des overrides.
    # Absent = comportement console par defaut. Voir GUIDE-SURCHARGE-GUI.md.
    try {
        Import-DeployModule 'Hooks'
        if (Get-Command Find-PSWDOverrideProfile -EA SilentlyContinue) {
            $ovProfile = Find-PSWDOverrideProfile
            if ($ovProfile) {
                Write-Info "Profil de surcharge GUI : $ovProfile"
                Import-PSWDOverrideProfile -Path $ovProfile | Out-Null
            }
        }
    } catch { Write-Warn "Profil de surcharge : $_" }

    # -- Mode assistant post-install SEUL (fenetre visible, lance par la phase 2) --
    if ($PostInstallWizard) {
        Write-Step "Assistant post-installation"
        foreach ($m in @('Hooks','NetShare','TaskContract','TaskHandlers','TaskEngine','SequenceResolver','TaskSequence','SimpleDeploy','PostInstall')) {
            try { Import-DeployModule $m } catch { Write-Warn "Module $m : $_" }
        }
        # Config deja chargee + chemins resolus (singleton). On LIT, point.
        $NetworkShare = Get-Cfg 'DeployShare'
        if (-not $NetworkShare) { $NetworkShare = Get-Cfg 'NetworkShare' }
        Write-Info "Serveur phase 2 : $NetworkShare"
        try { Connect-DeployShares -Mode 'Auto' -VaultPath 'C:\Deploy\secrets.vault.psd1' | Out-Null } catch {}
        $seqShare       = Get-Cfg 'SequencesPath'
        $scriptShare    = Get-Cfg 'ScriptShare'
        $softwareShare  = Get-Cfg 'SoftwareShare'
        $catalogueShare = Get-Cfg 'CataloguePath'
        Write-Info "Partages resolus : Sequences=$seqShare Scripts=$scriptShare Logiciels=$softwareShare"
        # Boucle : en cas d'erreur OU apres une action, on REVIENT au menu.
        # On ne quitte que si l'utilisateur choisit explicitement de terminer.
        $wizardDone = $false
        while (-not $wizardDone) {
            try {
                $built = Show-PostInstallWizard -SeqDir $seqShare -RuntimeDir 'C:\Deploy\Runtime' -ScriptShare $scriptShare -SoftwareShare $softwareShare -CatalogueShare $catalogueShare
                if ($built -is [hashtable] -and $built.ContainsKey('__action')) {
                    # L'utilisateur a choisi de terminer (avec ou sans nettoyage).
                    # DESARMER le mode deploiement : autologon OFF + tache supprimee.
                    # C'est le SEUL endroit qui desarme (fin du deploiement).
                    if (Get-Command Disable-DeploymentMode -EA SilentlyContinue) { Disable-DeploymentMode }
                    $wizardDone = $true
                } elseif ($built) {
                    Write-OK "Sequence prete : $built"
                    Write-Host ""
                    # FLUX UNIFIE : la sequence generee est mise en local puis le
                    # MOTEUR la deroule (exactement comme by-name). Etat neuf.
                    Remove-Item 'C:\Deploy\Runtime\state.psd1' -Force -EA SilentlyContinue
                    if ("$built" -ne 'C:\Deploy\Runtime\sequence.psd1') {
                        New-Item -ItemType Directory 'C:\Deploy\Runtime' -Force -EA SilentlyContinue | Out-Null
                        Copy-Item $built 'C:\Deploy\Runtime\sequence.psd1' -Force -EA SilentlyContinue
                    }
                    # Mode deploiement (autologon + reprise) arme avant de lancer.
                    if (Get-Command Enable-DeploymentMode -EA SilentlyContinue) {
                        $apwd = $null
                        try { $apwd = Get-Secret -Source vault -Key 'localAdminPassword' } catch {}
                        Enable-DeploymentMode -AdminPassword $apwd
                    }
                    $ctxV = @{
                        LogsDir   = 'C:\Deploy\Logs'
                        GetConfig = { param($k) Get-Cfg $k }
                        GetSecret = { param($k) Get-Secret -Source vault -Key $k }
                    }
                    Invoke-Engine -SequencePath 'C:\Deploy\Runtime\sequence.psd1' -Context $ctxV -PhaseFilter 'Windows' | Out-Null
                    Remove-Item 'C:\Deploy\Runtime\state.psd1' -Force -EA SilentlyContinue
                    Write-Host ""
                    Write-Host "  ============================================" -ForegroundColor Green
                    Write-OK "  Sequence terminee : les actions demandees ont ete realisees."
                    Write-Host "  ============================================" -ForegroundColor Green
                    Write-Host ""
                    # Pause explicite : l'operateur voit le resultat, appuie sur
                    # Entree, PUIS on revient au menu (pour nettoyer ou autre).
                    Read-Host "  Appuyez sur Entree pour revenir au menu"
                    Write-Host ""
                } else {
                    $wizardDone = $true
                }
            } catch {
                Write-Host ""
                Write-Err "ERREUR dans l'assistant : $_"
                Write-Err $_.ScriptStackTrace
                Write-Host ""
                $retry = Read-Host "  Une erreur est survenue. Revenir au menu ? (O/n)"
                if ($retry -match '^[nN]') { $wizardDone = $true }
                # sinon : on reboucle vers le menu
            }
        }
        Write-Host ""
        Write-OK "Assistant termine."
        Write-Host "  Appuyez sur Entree pour fermer cette fenetre..." -ForegroundColor Yellow
        [void](Read-Host)
        exit 0
    }

    $isWinPE = Test-IsWinPE
    $mode    = if ($Resume)     { 'RESUME' }
               elseif ($isWinPE) { 'WINPE' }
               else              { 'WINDOWS' }

    Write-Info "Mode : $mode"
    Write-Info "Host : $env:COMPUTERNAME"
    Write-Info "Date : $(Get-Date -Format 'dd/MM/yyyy HH:mm:ss')"
    Write-Host ""

    # -- Import des modules locaux (dans le WIM) --
    Write-Step "Chargement des modules..."
    foreach ($m in @('Hooks','WinPE-Builder','WIM-Manager','DiskSelector','TaskContract','TaskHandlers','TaskEngine','SequenceResolver','TaskSequence','NetShare','SimpleDeploy','PostInstall')) {
        try {
            Import-DeployModule $m
            if ($Resume) { Add-Content $bootTrace "  Module charge : $m" -EA SilentlyContinue }
        } catch {
            if ($Resume) { Add-Content $bootTrace "  ECHEC chargement module $m : $_" -EA SilentlyContinue }
            Write-Warn "Module $m non charge : $_"
        }
    }
    Write-OK "Modules charges"
    Write-Host ""

    # -- Mode RESUME (apres reboot) : PHASE 2 --
    if ($Resume) {
        Write-Step "Phase 2 : post-deploiement (Windows demarre)"
        Write-Host ""

        # VERROU anti-double-instance par FICHIER (le mutex Global\ est refuse en
        # compte SYSTEM -> 'acces refuse'). Un fichier lock avec le PID + l'heure
        # suffit : si un lock recent (<120s) existe et que son process tourne
        # encore, cette instance se termine. Sinon on prend le lock.
        $lockFile = 'C:\Deploy\Logs\.resume-lock'
        $lockDir = Split-Path $lockFile -Parent
        if (-not (Test-Path $lockDir -EA SilentlyContinue)) { New-Item -ItemType Directory $lockDir -Force -EA SilentlyContinue | Out-Null }
        $takeLock = $true
        if (Test-Path $lockFile -EA SilentlyContinue) {
            try {
                $lockData = Get-Content $lockFile -Raw -EA SilentlyContinue
                $lockPid = ($lockData -split '\|')[0]
                $lockTime = [datetime]($lockData -split '\|')[1]
                $ageSec = ((Get-Date) - $lockTime).TotalSeconds
                $stillRunning = $false
                if ($lockPid) { $stillRunning = [bool](Get-Process -Id ([int]$lockPid) -EA SilentlyContinue) }
                if ($ageSec -lt 120 -and $stillRunning) { $takeLock = $false }
            } catch { $takeLock = $true }
        }
        if (-not $takeLock) {
            Write-Info "Une autre instance de reprise est deja active -- celle-ci se termine."
            return
        }
        try { Set-Content -Path $lockFile -Value "$PID|$(Get-Date -Format 'o')" -Force -EA SilentlyContinue } catch {}

        # Detecter un MARQUEUR de step en cours : s'il existe, c'est qu'on a
        # redemarre PENDANT un step (reboot prevu, ou plantage). On l'affiche
        # pour savoir d'ou on repart / ce qui a pu planter.
        $markerFile = 'C:\Deploy\Logs\.current-step'
        if (Test-Path $markerFile -EA SilentlyContinue) {
            try {
                $mk = Get-Content $markerFile -Raw -EA SilentlyContinue
                $mkName = ($mk -split "`n" | Where-Object { $_ -match '^stepName=' }) -replace 'stepName=',''
                Write-Warn "Reprise pendant un step : $($mkName.Trim())"
                Write-Info "(Si ce step a plante, consultez C:\Deploy\Logs. Le deploiement reprend.)"
            } catch {}
        }

        # GARDE-FOU : fenetre de 5s pour reprendre la main. ESC = interrompre et
        # desarmer l'autologon (utile si le deploiement reboucle ou se bloque).
        Write-Host "  Reprise du deploiement dans 5s..." -ForegroundColor Cyan
        Write-Host "  [ESC] = interrompre et desactiver l'autologon / [Entree] = continuer maintenant" -ForegroundColor DarkGray
        $escPressed = $false
        $deadline = (Get-Date).AddSeconds(5)
        while ((Get-Date) -lt $deadline) {
            if ([Console]::KeyAvailable) {
                $k = [Console]::ReadKey($true)
                if ($k.Key -eq 'Escape') { $escPressed = $true; break }
                if ($k.Key -eq 'Enter')  { break }
            }
            Start-Sleep -Milliseconds 150
        }
        if ($escPressed) {
            Write-Warn "Reprise interrompue par l'operateur."
            try { if (Get-Command Disable-DeployResume -EA SilentlyContinue) { Disable-DeployResume } } catch {}
            Write-Host ""
            Write-OK "Autologon et reprise desactives."
            Write-Info "Pour relancer l'assistant : C:\Deploy\Scripts\Start-Deploy.ps1 -PostInstallWizard"
            Write-Host ""
            $relance = Read-Host "  Lancer l'assistant maintenant ? (O/n)"
            if ($relance -notmatch '^[nN]') {
                $PostInstallWizard = $true; $Resume = $false
            } else {
                Read-Host "  Appuyez sur Entree pour fermer"
                return
            }
        }
    }

    if ($Resume) {

        # Config singleton deja chargee + chemins resolus. On LIT le partage Deploy.
        $NetworkShare = Get-Cfg 'DeployShare'
        if (-not $NetworkShare) { $NetworkShare = Get-Cfg 'NetworkShare' }
        Write-OK "Serveur phase 2 (resolu) : $NetworkShare"
        Add-Content $bootTrace "  Config (singleton) : DeployShare=$NetworkShare" -EA SilentlyContinue

        # Reconnecter les partages SMB (pour MAJ/apps/domaine). Le vault local
        # (C:\Deploy\secrets.vault) fournit les credentials via le mode 'Auto'.
        Write-Step "Reconnexion des partages..."
        try {
            $shareOk2 = Connect-DeployShares -Mode 'Auto' -VaultPath 'C:\Deploy\secrets.vault.psd1'
            if (-not $shareOk2) {
                # Reessayer avec le vault sans extension
                $shareOk2 = Connect-DeployShares -Mode 'Auto' -VaultPath 'C:\Deploy\secrets.vault'
            }
            if ($shareOk2) { Write-OK "Partages reconnectes" }
            else { Write-Warn "Partages non reconnectes (certains scripts peuvent echouer)" }
        } catch {
            Write-Warn "Reconnexion partages : $_ (certains scripts peuvent echouer)"
        }
        Write-Host ""

        # Phase 2 : la TaskSequence reprend la sequence et execute UNIQUEMENT les
        # steps de phase 'Windows' (JoinDomain, InstallUpdates, InstallSoftware,
        # RunScript...). Les steps 'WinPE' (FormatDisk, ApplyWIM, ApplyUnattend)
        # ont deja ete faits par SimpleDeploy avant le reboot.
        # On garde TOUT l'ordonnancement : reboots (RebootAfter), conditions,
        # reprise (state + RunOnce), ContinueOnError.
        Import-DeployModule 'PostInstall'

        # ===== FLUX UNIFIE (refonte) : Resolver -> Engine =====
        # Quelle que soit l'origine (locale / by-name / by-mac / _default), on
        # resout UNE sequence et on la copie en local. Apres ca, TOUT est pareil.
        $seqShare = Get-Cfg 'SequencesPath'
        if (-not $seqShare) { $seqShare = "$NetworkShare\Sequences" }
        $SequencePath = Resolve-DeploySequence -SequencesDir $seqShare

        # Contexte partage fourni aux handlers (logger, config, secrets, logs).
        $engineCtx = @{
            LogsDir   = 'C:\Deploy\Logs'
            GetConfig = { param($k) Get-Cfg $k }
            GetSecret = { param($k) Get-Secret -Source vault -Key $k }
        }

        if (-not $SequencePath) {
            # Aucune sequence affectee -> assistant INTERACTIF (fenetre visible).
            Write-Info "Aucune sequence affectee a ce poste."
            Write-Info "Ouverture de l'assistant post-installation..."
            $selfPath = $PSCommandPath
            if (-not $selfPath) { $selfPath = 'C:\Deploy\Scripts\Start-Deploy.ps1' }
            Start-Process powershell.exe -ArgumentList @(
                '-NoProfile','-ExecutionPolicy','Bypass',
                '-File', "`"$selfPath`"", '-PostInstallWizard'
            ) -Wait
        } else {
            # MODE DEPLOIEMENT : autologon + tache de reprise armes UNE FOIS au
            # debut (idempotent : re-arme a chaque reprise). C'est le marqueur
            # 'deploiement en cours'. Desarme uniquement a la fin (done).
            if (Get-Command Enable-DeploymentMode -EA SilentlyContinue) {
                $adminPwd = $null
                try { $adminPwd = Get-Secret -Source vault -Key 'localAdminPassword' } catch {}
                Enable-DeploymentMode -AdminPassword $adminPwd
            }
            Write-OK "Sequence phase 2 : $SequencePath"
            Write-Host ""
            # LE MOTEUR : deroule la sequence, dispatche, gere reboot/reprise.
            $engResult = Invoke-Engine -SequencePath $SequencePath -Context $engineCtx -Resume -PhaseFilter 'Windows'
            # Si le moteur a reboote, le process s'arrete avant ici. S'il revient,
            # c'est que la sequence est terminee (ou en attente d'action).
            if ($engResult -and $engResult.done) {
                # Sequence terminee : basculer sur l'assistant pour permettre le
                # nettoyage / la fin (qui desarmera le mode deploiement).
                $selfPath = $PSCommandPath
                if (-not $selfPath) { $selfPath = 'C:\Deploy\Scripts\Start-Deploy.ps1' }
                Start-Process powershell.exe -ArgumentList @(
                    '-NoProfile','-ExecutionPolicy','Bypass',
                    '-File', "`"$selfPath`"", '-PostInstallWizard'
                ) -Wait
            }
        }

        # Nettoyer les mecanismes de reprise (sequence finie -> ne pas reboucler) :
        # RunOnce, autologon, et tache planifiee.
        try {
            reg delete 'HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce' /v 'PSWinDeployResume' /f 2>&1 | Out-Null
            # Desarmer l'autologon
            $wl = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'
            Set-ItemProperty $wl -Name 'AutoAdminLogon' -Value '0' -Type String -Force -EA SilentlyContinue
            Remove-ItemProperty $wl -Name 'DefaultPassword' -Force -EA SilentlyContinue
            # Supprimer la tache de reprise
            Unregister-ScheduledTask -TaskName 'PSWinDeployResume' -Confirm:$false -EA SilentlyContinue | Out-Null
        } catch {}

        Write-Host ""
        Write-OK "==============================================="
        Write-OK "  Phase 2 terminee"
        Write-OK "==============================================="
        exit 0
    }

    # -- Initialisation reseau --------------------------------------------------
    Write-Step "Initialisation reseau..."
    $netOk = Initialize-Network
    Write-Host ""

    if ($netOk) {
        Write-Step "Connexion aux partages de deploiement..."

        # Extraire le nom du serveur depuis NetworkShare (ex: \\SERVEUR\Deploy -> SERVEUR)
        $deployServer = ''
        if ($NetworkShare -match '\\\\([^\\]+)\\') { $deployServer = $Matches[1] }

        $shareOk = Connect-DeployShares `
            -Server   $deployServer `
            -Mode     $CredentialMode `
            -User     $ShareUser `
            -Pass     $SharePassword `
            -VaultPwd $VaultPassword

        if (-not $shareOk) {
            Write-Warn "Partages reseau inaccessibles -- deploiement depuis sources locales uniquement"
        }
        Write-Host ""
    }

    # -- Selection de la sequence --
    if (-not $SequencePath -or -not (Test-Path $SequencePath)) {
        if ($Unattended) {
            Write-Err "Mode -Unattended mais -SequencePath absent ou invalide"
            exit 1
        }
        Write-Step "Selection de la sequence de deploiement..."
        $SequencePath = Select-SequenceFile -SearchRoot $NetworkShare

        # Option Ligne de commande : ouvrir un shell interactif, partages montes.
        # Pratique pour diagnostic, tests manuels (Test-Unattend-Complet.ps1...),
        # ou utiliser des outils en ligne de commande comme avec Shift+F10.
        while ($SequencePath -eq 'SHELL') {
            Write-Host ""
            Write-Host "  +----------------------------------------------------------+" -ForegroundColor Cyan
            Write-Host "  |  MODE LIGNE DE COMMANDE                                  |" -ForegroundColor Cyan
            Write-Host "  +----------------------------------------------------------+" -ForegroundColor Cyan
            Write-Host ""
            Write-Host "  Les partages reseau sont montes et accessibles." -ForegroundColor Gray
            Write-Host "  Tu es dans un shell PowerShell interactif." -ForegroundColor Gray
            Write-Host ""
            Write-Host "  - Pour revenir au menu de deploiement : tape  exit" -ForegroundColor DarkGray
            Write-Host "  - Pour relancer le deploiement directement :" -ForegroundColor DarkGray
            Write-Host "      X:\Deploy\Scripts\Start-Deploy.ps1" -ForegroundColor DarkGray
            Write-Host "  - Pour un invite de commandes classique : tape  cmd" -ForegroundColor DarkGray
            Write-Host ""
            # Ouvrir un shell interactif. A la sortie (exit), on relance la selection.
            try { & powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass } catch {}
            Write-Host ""
            Write-Info "Retour au menu de deploiement..."
            $SequencePath = Select-SequenceFile -SearchRoot $NetworkShare
        }

        # Option From Scratch : assistant interactif WinPE
        if ($SequencePath -eq 'SCRATCH') {
            Write-Step "Assistant From Scratch"
            # Capturer UNIQUEMENT la derniere ligne retournee (le chemin PSD1)
            # Les Write-Host ne sont pas captur?s, mais les expressions non-captur?es le sont
            $wizardOutput = @(Invoke-ScratchWizard)
            # Mode SIMPLE : le deploiement a deja ete fait par Invoke-SimpleDeploy.
            if ($wizardOutput -contains 'SIMPLE-DONE') {
                Write-OK "Deploiement simple termine."
                return
            }
            # Prendre uniquement la derni?re valeur non-nulle (le chemin du fichier)
            $SequencePath = ($wizardOutput | Where-Object { $_ -and $_.ToString().Trim() -match '\.psd1$|\.json$' } | Select-Object -Last 1)
            if (-not $SequencePath) {
                # Fallback : derni?re valeur non-nulle
                $SequencePath = ($wizardOutput | Where-Object { $_ } | Select-Object -Last 1)
            }
            Write-Info "Sequence : $SequencePath"
        }
    }

    $SequencePath = $SequencePath.Trim().Trim('"').Trim("'")
    if ([string]::IsNullOrWhiteSpace($SequencePath)) {
        throw "Aucune sequence selectionnee"
    }
    if (-not (Test-Path $SequencePath -ErrorAction SilentlyContinue)) {
        # Essayer le chemin avec guillemets supprimes
        Write-Warn "Sequence introuvable : $SequencePath"
        throw "Sequence introuvable : $SequencePath"
    }

    Write-OK "Sequence : $SequencePath"

    # Lecture du JSON pour savoir si l'assistant disque est necessaire
    if ([string]::IsNullOrWhiteSpace($SequencePath)) {
        throw "Chemin sequence vide -- impossible de continuer"
    }
    # Lire la sequence -- PSD1 ou JSON
    $seqData = if ($SequencePath -match '\.psd1$') {
        Import-PowerShellDataFile $SequencePath -ErrorAction Stop
    } else {
        Get-Content $SequencePath -Raw | ConvertFrom-Json
    }
    $formatStep = $seqData.steps | Where-Object { $_.type -eq 'FormatDisk' } | Select-Object -First 1
    $needDiskWizard = (-not $Unattended) -and
                      ($null -eq $formatStep -or $null -eq $formatStep.params.diskNumber -or
                       $formatStep.params.diskNumber -eq -1)

    # -- Assistant pre-deploiement --
    if ($needDiskWizard -and $isWinPE) {
        Write-Host ""
        Write-Step "Lancement de l'assistant de deploiement..."
        $wizardResult = Invoke-PreDeployWizard -WimSearchPath @(
            "$NetworkShare\Images",
            'D:\Images',
            'X:\Images'
        )

        if (-not $wizardResult) {
            Write-Warn "Deploiement annule par l'operateur."
            exit 0
        }

        # Injection des choix de l'assistant dans la sequence (en memoire)
        # On met a jour le step FormatDisk et ApplyWIM dynamiquement
        foreach ($step in $seqData.steps) {
            if ($step.type -eq 'FormatDisk') {
                $step.params.diskNumber   = $wizardResult.DiskNumber
                $step.params.firmwareType = $wizardResult.FirmwareType
            }
            if ($step.type -eq 'ApplyWIM') {
                $step.params.wimPath = $wizardResult.WimPath
                $step.params.index   = $wizardResult.WimIndex
            }
        }
        # Sauvegarde de la sequence modifiee dans le Deploy local
        $localSeqPath = 'C:\Deploy\sequence-runtime.psd1'
        if (Test-IsWinPE) {
            # En WinPE C:\ est la future partition Windows -- ecrire dans X:\
            $localSeqPath = 'X:\Deploy\sequence-runtime.psd1'
        }
        $seqDir = Split-Path $localSeqPath -Parent
        if (-not (Test-Path $seqDir)) { New-Item -ItemType Directory $seqDir -Force | Out-Null }
        $seqData | ConvertTo-Json -Depth 10 | Set-Content $localSeqPath -Encoding UTF8
        $SequencePath = $localSeqPath
        Write-OK "Sequence runtime enregistree : $SequencePath"
    }

    Write-Host ""

    # -- Lancement de la task sequence --
    Write-Step "Demarrage de la sequence '$($seqData.name)'..."
    Write-Host ""

    Invoke-TaskSequence -SequencePath $SequencePath

    # -- Fin --
    Write-Host ""
    Write-OK "==============================================="
    Write-OK "  Deploiement termine avec succes !"
    Write-OK "==============================================="

    # Exporter les logs vers le partage AVANT de rebooter (survivent au reboot/BSOD)
    if (Get-Command Export-DeployLogs -EA SilentlyContinue) {
        Export-DeployLogs -NetworkShare $NetworkShare -Tag '_fin'
    }

    # Reboot : en WinPE, flush + wpeutil reboot (PAS Restart-Computer -Force qui
    # peut rebooter avant le flush disque -> corruption -> BSOD sans logs).
    $inWinPE = Test-Path 'X:\Windows\System32\wpeutil.exe' -EA SilentlyContinue
    if ($inWinPE) {
        Write-OK "  Flush disque puis redemarrage (wpeutil)..."
        foreach ($vol in @('S','W','R')) {
            if (Test-Path "${vol}:\" -EA SilentlyContinue) {
                try { [System.IO.File]::WriteAllText("${vol}:\.flush", '1'); Remove-Item "${vol}:\.flush" -Force -EA SilentlyContinue } catch {}
            }
        }
        Start-Sleep 3
        & wpeutil.exe reboot
        Start-Sleep 30
    } else {
        Write-OK "  La machine va redemarrer dans 10 secondes..."
        Start-Sleep 10
        Restart-Computer -Force
    }

} catch {
    Write-Host ""
    Write-Err "==============================================="
    Write-Err "  ERREUR FATALE : $_"
    Write-Err "==============================================="
    Write-Host ""
    Write-Warn "  Le deploiement a echoue."
    Write-Warn "  Consultez les logs : $DeployRoot\Logs\deploy.log"
    Write-Host ""
    Write-Host "  Appuyez sur une touche pour ouvrir une console de depannage..." -ForegroundColor DarkGray
    $null = $Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown')
    # Ouvre un shell PowerShell interactif pour diagnostic
    Start-Process powershell.exe -ArgumentList '-NoExit -NoProfile' -Wait
    exit 1
}
