#Requires -RunAsAdministrator
<#
.SYNOPSIS
    WinPE-Builder.psm1 -- Module de construction d'environnements WinPE bootables
.DESCRIPTION
    Remplace la partie WinPE de MDT. Construit un environnement WinPE depuis l'ADK,
    permet d'injecter drivers et packages, et genere un media bootable (ISO ou cle USB).
.NOTES
    Prerequis : Windows ADK + WinPE Add-on installes
    Droits    : Administrateur obligatoire (DISM)
    Teste sur : Windows 10/11, Windows Server 2019/2022
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# -----------------------------------------------------------------------------
# CONFIGURATION PAR DEFAUT
# -----------------------------------------------------------------------------

$script:DefaultConfig = @{
    # Chemins ADK standards -- modifiables via Set-WinPEConfig
    AdkPath          = 'C:\Program Files (x86)\Windows Kits\10\Assessment and Deployment Kit'
    WinPEAddonPath   = 'C:\Program Files (x86)\Windows Kits\10\Assessment and Deployment Kit\Windows Preinstallation Environment'
    # Architecture cible par defaut
    Architecture     = 'amd64'   # amd64 | x86 | arm64
    # Dossier de travail temporaire
    WorkspacePath    = "$env:TEMP\WinPE-Builder"
    # Langue WinPE
    Locale           = 'fr-FR'
}

$script:Config = $script:DefaultConfig.Clone()

# -----------------------------------------------------------------------------
# FONCTIONS UTILITAIRES INTERNES
# -----------------------------------------------------------------------------

function Write-WinPELog {
    <#
    .SYNOPSIS Journalisation structuree avec horodatage et niveau#>
    param(
        [string]$Message,
        [ValidateSet('INFO','WARN','ERROR','SUCCESS','STEP')]
        [string]$Level = 'INFO'
    )
    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $icons = @{
        INFO    = '[~]'
        WARN    = '[!]'
        ERROR   = '[X]'
        SUCCESS = '[OK]'
        STEP    = '[>>]'
    }
    $colors = @{
        INFO    = 'Cyan'
        WARN    = 'Yellow'
        ERROR   = 'Red'
        SUCCESS = 'Green'
        STEP    = 'Magenta'
    }
    Write-Host "$timestamp $($icons[$Level]) $Message" -ForegroundColor $colors[$Level]
}

function Assert-AdkInstalled {
    <#
    .SYNOPSIS Verifie que l'ADK et le WinPE Add-on sont bien installes#>
    $copype = Join-Path $script:Config.WinPEAddonPath 'copype.cmd'
    if (-not (Test-Path $copype)) {
        throw "WinPE Add-on introuvable : $copype`nInstalllez l'ADK + WinPE Add-on depuis : https://learn.microsoft.com/en-us/windows-hardware/get-started/adk-install"
    }

    $dism = Join-Path $script:Config.AdkPath 'Deployment Tools\x86\DISM\dism.exe'
    # Fallback sur le DISM systeme si celui de l'ADK est absent
    if (-not (Test-Path $dism)) {
        $dism = 'dism.exe'
    }
    Write-WinPELog "ADK detecte : $($script:Config.AdkPath)" -Level SUCCESS
    return $dism
}

function Invoke-DISM {
    <#
    .SYNOPSIS Wrapper DISM avec gestion d'erreurs et logging#>
    param([string[]]$Arguments)
    Write-WinPELog "DISM $($Arguments -join ' ')" -Level INFO

    $result = & dism.exe @Arguments 2>&1
    $result | ForEach-Object { Write-Host "  $_" -ForegroundColor DarkGray }

    if ($LASTEXITCODE -ne 0) {
        throw "DISM a echoue (code $LASTEXITCODE). Commande : dism.exe $($Arguments -join ' ')"
    }
}

# -----------------------------------------------------------------------------
# FONCTION 1 : CONFIGURATION DU MODULE
# -----------------------------------------------------------------------------

function Set-WinPEConfig {
    <#
    .SYNOPSIS
        Configure les chemins et parametres globaux du module WinPE-Builder.
    .DESCRIPTION
        Permet de surcharger les chemins ADK, l'architecture cible et le dossier
        de travail. A appeler avant toute autre fonction si l'ADK n'est pas dans
        son chemin par defaut.
    .PARAMETER AdkPath
        Chemin racine de l'ADK Windows.
    .PARAMETER Architecture
        Architecture cible : amd64 (defaut), x86 ou arm64.
    .PARAMETER WorkspacePath
        Dossier de travail temporaire pour les operations WinPE.
    .PARAMETER Locale
        Langue du WinPE (ex: fr-FR, en-US).
    .EXAMPLE
        Set-WinPEConfig -Architecture 'amd64' -WorkspacePath 'D:\WinPE-Work'
    #>
    [CmdletBinding()]
    param(
        [string]$AdkPath,
        [ValidateSet('amd64','x86','arm64')]
        [string]$Architecture,
        [string]$WorkspacePath,
        [string]$Locale
    )

    if ($AdkPath)       { $script:Config.AdkPath = $AdkPath }
    if ($Architecture)  { $script:Config.Architecture = $Architecture }
    if ($WorkspacePath) { $script:Config.WorkspacePath = $WorkspacePath }
    if ($Locale)        { $script:Config.Locale = $Locale }

    Write-WinPELog "Configuration mise a jour" -Level SUCCESS
    $script:Config | Format-Table -AutoSize | Out-String | Write-Host
}

function Get-WinPEConfig {
    <#
    .SYNOPSIS Affiche la configuration active du module.#>
    $script:Config
}

# -----------------------------------------------------------------------------
# FONCTION 2 : CREER L'ENVIRONNEMENT WINPE
# -----------------------------------------------------------------------------

function New-WinPEEnvironment {
    <#
    .SYNOPSIS
        Cree un nouvel environnement WinPE de travail via copype.cmd.
    .DESCRIPTION
        Lance copype.cmd pour copier les fichiers WinPE de base dans un dossier
        de travail, puis monte le WIM pour permettre les modifications.
        Genere la structure :
          <WorkspacePath>\
            media\          -> contenu du media bootable (ISO root)
            mount\          -> point de montage du WIM
            winpe.wim       -> WIM original (sauvegarde)
    .PARAMETER WorkspacePath
        Dossier de destination. Si omis, utilise la config globale.
    .PARAMETER Architecture
        Architecture cible. Si omis, utilise la config globale.
    .PARAMETER Force
        Supprime et recree le workspace s'il existe deja.
    .EXAMPLE
        New-WinPEEnvironment -WorkspacePath 'D:\WinPE-Work' -Architecture 'amd64'
    .OUTPUTS
        [PSCustomObject] avec les proprietes : WorkspacePath, MountPath, MediaPath, WimPath
    #>
    [CmdletBinding()]
    param(
        [string]$WorkspacePath = $script:Config.WorkspacePath,
        [ValidateSet('amd64','x86','arm64')]
        [string]$Architecture  = $script:Config.Architecture,
        [switch]$Force
    )

    Write-WinPELog "=== Creation de l'environnement WinPE ===" -Level STEP
    Assert-AdkInstalled | Out-Null

    # Gestion du workspace existant
    if (Test-Path $WorkspacePath) {
        if ($Force) {
            Write-WinPELog "Suppression du workspace existant : $WorkspacePath" -Level WARN
            Remove-Item $WorkspacePath -Recurse -Force
        } else {
            throw "Le workspace existe deja : $WorkspacePath`nUtilisez -Force pour ecraser."
        }
    }

    # Execution de copype.cmd
    $copype = Join-Path $script:Config.WinPEAddonPath 'copype.cmd'

    # Verification 1 : copype.cmd existe
    if (-not (Test-Path $copype)) {
        throw "copype.cmd introuvable : $copype`nVerifier que le WinPE Add-on est installe.`nTelecharger : https://learn.microsoft.com/windows-hardware/get-started/adk-install"
    }

    # Verification 2 : l'architecture demandee existe dans le WinPE Add-on
    $archPath = Join-Path $script:Config.WinPEAddonPath $Architecture
    if (-not (Test-Path $archPath)) {
        $available = @(Get-ChildItem $script:Config.WinPEAddonPath -Directory -EA SilentlyContinue |
                      Where-Object { $_.Name -in @('amd64','arm64','x86') } |
                      Select-Object -ExpandProperty Name)
        $archList = if ($available.Count -gt 0) { $available -join ', ' } else { 'aucune' }
        throw "Architecture '$Architecture' absente du WinPE Add-on.`nArchitectures disponibles : $archList`nDossier verifie : $archPath`nReinstaller le WinPE Add-on depuis l ADK Setup en cochant l architecture souhaitee."
    }
    Write-WinPELog "Architecture $Architecture OK : $archPath" -Level INFO

    Write-WinPELog "Execution de copype.cmd ($Architecture) -> $WorkspacePath" -Level INFO

    # copype.cmd necessite les variables d environnement ADK (WinPERoot, PATH enrichi, etc.)
    # definies par DandISetEnv.bat. Sans elles, copype echoue meme si le dossier amd64 existe.
    # Solution : executer DandISetEnv.bat puis copype.cmd dans le MEME processus cmd.exe
    # via un fichier .cmd temporaire qui enchaine les deux appels.

    $dandISetEnv = Join-Path $script:Config.AdkPath 'Deployment Tools\DandISetEnv.bat'
    if (-not (Test-Path $dandISetEnv)) {
        # Chercher dans les sous-dossiers courants
        $candidates = @(Get-ChildItem $script:Config.AdkPath -Filter 'DandISetEnv.bat' -Recurse -ErrorAction SilentlyContinue)
        if ($candidates.Count -gt 0) { $dandISetEnv = $candidates[0].FullName }
    }
    if (-not (Test-Path $dandISetEnv)) {
        throw "DandISetEnv.bat introuvable dans $($script:Config.AdkPath)`nVerifier l installation de l ADK (composant Deployment Tools)."
    }
    Write-WinPELog "DandISetEnv.bat : $dandISetEnv" -Level INFO

    # Creer un script .cmd temporaire qui :
    #   1. Execute DandISetEnv.bat pour initialiser l environnement ADK
    #   2. Appelle copype.cmd avec l architecture et le workspace
    $tmpScript = [System.IO.Path]::GetTempFileName() + '.cmd'
    $tmpContent  = "@echo off`r`n"
    $tmpContent += "call `"$dandISetEnv`"`r`n"
    $tmpContent += "call copype.cmd $Architecture `"$WorkspacePath`"`r`n"
    $tmpContent += "exit /b %errorlevel%`r`n"
    Set-Content -Path $tmpScript -Value $tmpContent -Encoding ASCII

    Write-WinPELog "Script temporaire :`r`n$tmpContent" -Level INFO

    $prevLocation = Get-Location
    try {
        Set-Location $script:Config.WinPEAddonPath
                    $psiCP = New-Object System.Diagnostics.ProcessStartInfo
                    $psiCP.FileName  = $env:ComSpec
                    $psiCP.Arguments = "/c `"$tmpScript`""
                    $psiCP.WorkingDirectory = $script:Config.WinPEAddonPath
                    $psiCP.RedirectStandardOutput = $true
                    $psiCP.RedirectStandardError  = $true
                    $psiCP.UseShellExecute = $false
                    $psiCP.CreateNoWindow  = $true
                    $procCP = New-Object System.Diagnostics.Process
                    $procCP.StartInfo = $psiCP
                    $procCP.Start() | Out-Null
                    $taskOutCP = $procCP.StandardOutput.ReadToEndAsync()
                    $taskErrCP = $procCP.StandardError.ReadToEndAsync()
                    $procCP.WaitForExit()
                    $exitCP = $procCP.ExitCode
                    $outCP = $taskOutCP.GetAwaiter().GetResult()
                    $errCP = $taskErrCP.GetAwaiter().GetResult()
                    ($outCP + $errCP).Split("`n") | Where-Object { $_.Trim() } |
                        ForEach-Object { Write-Host "  $_" -ForegroundColor DarkGray }
                    if ($exitCP -ne 0) {
                        throw "copype.cmd a echoue (code $exitCP)`nArchitecture : $Architecture`nWorkspace : $WorkspacePath"
                    }
    } finally {
        Set-Location $prevLocation
        Remove-Item $tmpScript -Force -ErrorAction SilentlyContinue
    }

    # Chemins resultants
    $paths = [PSCustomObject]@{
        WorkspacePath = $WorkspacePath
        MountPath     = Join-Path $WorkspacePath 'mount'
        MediaPath     = Join-Path $WorkspacePath 'media'
        WimPath       = Join-Path $WorkspacePath 'media\sources\boot.wim'
    }

    # Sauvegarde du WIM original
    $backupWim = Join-Path $WorkspacePath 'winpe_original.wim'
    Copy-Item $paths.WimPath $backupWim -Force
    Write-WinPELog "WIM original sauvegarde : $backupWim" -Level INFO

    # Creation du dossier mount si absent
    if (-not (Test-Path $paths.MountPath)) {
        New-Item -ItemType Directory -Path $paths.MountPath | Out-Null
    }

    # Montage du WIM pour modification
    Write-WinPELog "Montage du WIM en ecriture : $($paths.WimPath) -> $($paths.MountPath)" -Level INFO
    Invoke-DISM @('/Mount-Image', "/ImageFile:$($paths.WimPath)", '/Index:1', "/MountDir:$($paths.MountPath)")

    Write-WinPELog "Environnement WinPE pret !" -Level SUCCESS
    Write-WinPELog "  Mount  : $($paths.MountPath)" -Level INFO
    Write-WinPELog "  Media  : $($paths.MediaPath)" -Level INFO

    return $paths
}

# -----------------------------------------------------------------------------
# FONCTION 3 : AJOUTER DES DRIVERS
# -----------------------------------------------------------------------------

function Add-WinPEDriver {
    <#
    .SYNOPSIS
        Injecte un ou plusieurs drivers dans l'image WinPE montee.
    .DESCRIPTION
        Utilise DISM /Add-Driver pour injecter des drivers .inf dans le WIM monte.
        Peut traiter un driver unique ou un dossier entier (recursif).
    .PARAMETER MountPath
        Chemin du point de montage WinPE.
    .PARAMETER DriverPath
        Chemin vers un fichier .inf ou un dossier contenant des drivers.
    .PARAMETER Recurse
        Si DriverPath est un dossier, cherche les drivers en sous-dossiers.
    .PARAMETER UnsignedDrivers
        Autorise les drivers non signes (a eviter en production).
    .EXAMPLE
        Add-WinPEDriver -MountPath 'D:\WinPE-Work\mount' -DriverPath 'D:\Drivers\NIC'
    .EXAMPLE
        Add-WinPEDriver -MountPath 'D:\WinPE-Work\mount' -DriverPath 'D:\Drivers' -Recurse
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$MountPath,
        [Parameter(Mandatory)]
        [string]$DriverPath,
        [switch]$Recurse,
        [switch]$UnsignedDrivers
    )

    Write-WinPELog "=== Injecting drivers ===" -Level STEP

    if (-not (Test-Path $MountPath)) {
        throw "Point de montage introuvable : $MountPath"
    }
    if (-not (Test-Path $DriverPath)) {
        throw "Chemin driver introuvable : $DriverPath"
    }

    # DISM /Add-Driver ne supporte pas toujours les chemins UNC (\serveur\partage)
    # Si le chemin est un partage reseau, copier les drivers en local avant injection
    $localDriverPath = $DriverPath
    $tmpDriverDir    = $null
    if ($DriverPath -match '^\\\\') {
        Write-WinPELog "UNC path detected -- local copy before DISM injection" -Level INFO
        $tmpDriverDir    = Join-Path $env:TEMP "winpe-drivers-$(Get-Random)"
        New-Item -ItemType Directory $tmpDriverDir -Force | Out-Null
        Copy-Item "$DriverPath\*" $tmpDriverDir -Recurse -Force -ErrorAction SilentlyContinue
        $localDriverPath = $tmpDriverDir
        Write-WinPELog "Drivers copies dans : $tmpDriverDir" -Level INFO
    }

    try {
        # Verifier qu il y a bien des .inf dans le dossier local avant d appeler DISM
        $infFiles = @(Get-ChildItem $localDriverPath -Filter '*.inf' -Recurse -ErrorAction SilentlyContinue)
        if ($infFiles.Count -eq 0) {
            Write-WinPELog "Aucun .inf dans $DriverPath -- dossier vide, injection ignoree" -Level WARN
        } else {
            Write-WinPELog "$($infFiles.Count) fichier(s) .inf trouve(s)" -Level INFO
            $dismArgs = @("/Image:$MountPath", '/Add-Driver', "/Driver:$localDriverPath")
            if ($Recurse)         { $dismArgs += '/Recurse' }
            if ($UnsignedDrivers) { $dismArgs += '/ForceUnsigned' }
            Invoke-DISM $dismArgs
            Write-WinPELog "Drivers injectes depuis : $DriverPath" -Level SUCCESS
        }
    } finally {
        if ($tmpDriverDir -and (Test-Path $tmpDriverDir)) {
            Remove-Item $tmpDriverDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

# -----------------------------------------------------------------------------
# FONCTION 4 : AJOUTER DES PACKAGES WinPE
# -----------------------------------------------------------------------------

function Add-WinPEPackage {
    <#
    .SYNOPSIS
        Ajoute des packages optionnels WinPE (PowerShell, WMI, .NET, HTA, etc.)
    .DESCRIPTION
        Installe les packages .cab de l'ADK dans l'image WinPE montee.
        Les packages disponibles sont enumeres automatiquement depuis l'ADK.
    .PARAMETER MountPath
        Chemin du point de montage WinPE.
    .PARAMETER Package
        Nom(s) de package a installer. Voir Get-WinPEAvailablePackages pour la liste.
        Raccourcis acceptes : PowerShell, WMI, NetFx, Scripting, HTA, StorageWMI,
                              WinPESetup, FontSupport-WinRE, RNDIS
    .PARAMETER Architecture
        Architecture. Si omis, utilise la config globale.
    .EXAMPLE
        Add-WinPEPackage -MountPath 'D:\WinPE-Work\mount' -Package 'PowerShell','WMI'
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$MountPath,
        [Parameter(Mandatory)]
        [string[]]$Package,
        [ValidateSet('amd64','x86','arm64')]
        [string]$Architecture = $script:Config.Architecture
    )

    Write-WinPELog "=== Adding WinPE packages ===" -Level STEP

    # Mapping noms raccourcis -> noms de packages ADK reels
    $packageMap = @{
        'PowerShell'       = 'WinPE-PowerShell'
        'WMI'              = 'WinPE-WMI'
        'NetFx'            = 'WinPE-NetFx'
        'Scripting'        = 'WinPE-Scripting'
        'HTA'              = 'WinPE-HTA'
        'StorageWMI'       = 'WinPE-StorageWMI'
        'WinPESetup'       = 'WinPE-Setup'
        'RNDIS'            = 'WinPE-RNDIS'
        'EnhancedStorage'  = 'WinPE-EnhancedStorage'
        'WinRE'            = 'WinPE-WinReCfg'
    }

    # Les packages .cab sont dans WinPEAddonPathmd64\ (pas de sous-dossier OptionalComponents)
    # Verifier les deux emplacements connus selon la version de l ADK
    $packagesBasePath = $null
    foreach ($candidate in @(
        (Join-Path $script:Config.WinPEAddonPath "$Architecture"),
        (Join-Path $script:Config.WinPEAddonPath "OptionalComponents\$Architecture"),
        (Join-Path $script:Config.WinPEAddonPath "$Architecture\WinPE_OCs")
    )) {
        if (Test-Path (Join-Path $candidate 'WinPE-WMI.cab') -ErrorAction SilentlyContinue) {
            $packagesBasePath = $candidate
            Write-WinPELog "Packages .cab trouves dans : $packagesBasePath" -Level INFO
            break
        }
    }
    if (-not $packagesBasePath) {
        # Fallback : chercher WinPE-WMI.cab recursivement pour trouver le bon dossier
        $wmicab = Get-ChildItem $script:Config.WinPEAddonPath -Filter 'WinPE-WMI.cab' -Recurse -ErrorAction SilentlyContinue |
                  Where-Object { $_.FullName -match $Architecture } | Select-Object -First 1
        if ($wmicab) {
            $packagesBasePath = Split-Path $wmicab.FullName -Parent
            Write-WinPELog "Packages .cab detectes automatiquement : $packagesBasePath" -Level INFO
        } else {
            Write-WinPELog "AVERTISSEMENT : aucun package .cab trouve dans $($script:Config.WinPEAddonPath)" -Level WARN
            $packagesBasePath = Join-Path $script:Config.WinPEAddonPath $Architecture
        }
    }
    $localeBasePath = Join-Path $packagesBasePath $script:Config.Locale

    # Ordre d installation obligatoire (dependances Microsoft WinPE) :
    # WMI -> NetFx -> Scripting -> PowerShell -> StorageWMI -> EnhancedStorage -> autres
    $orderedPackages = [System.Collections.Generic.List[string]]::new()
    $installOrder = @(
        'WinPE-WMI','WinPE-NetFx','WinPE-Scripting','WinPE-PowerShell',
        'WinPE-StorageWMI','WinPE-EnhancedStorage','WinPE-HTA','WinPE-RNDIS','WinPE-WinReCfg'
    )
    # Ajouter d abord les packages dans l ordre des dependances
    foreach ($ordPkg in $installOrder) {
        if ($Package -contains $ordPkg -or
            ($packageMap.Values -contains $ordPkg -and
             ($Package | Where-Object { $packageMap.ContainsKey($_) -and $packageMap[$_] -eq $ordPkg }))) {
            $orderedPackages.Add($ordPkg)
        }
    }
    # Ajouter les packages non couverts par l ordre ci-dessus
    foreach ($pkg in $Package) {
        $pkgName = if ($packageMap.ContainsKey($pkg)) { $packageMap[$pkg] } else { $pkg }
        if (-not $orderedPackages.Contains($pkgName)) { $orderedPackages.Add($pkgName) }
    }

    foreach ($pkgName in $orderedPackages) {
        $cabPath = Join-Path $packagesBasePath "$pkgName.cab"
        if (-not (Test-Path $cabPath)) {
            Write-WinPELog "Package introuvable (ignore) : $cabPath" -Level WARN
            continue
        }
        Write-WinPELog "Installation : $pkgName" -Level INFO
        $dismPkgArgs = @("/Image:$MountPath", '/Add-Package', "/PackagePath:$cabPath")
        try {
            Invoke-DISM $dismPkgArgs
        } catch {
            # 0x800f081e = package non applicable (deja installe ou incompatible) -> non bloquant
            if ($_ -match '800f081e|0x800f081e') {
                Write-WinPELog "Package $pkgName deja present ou non applicable -- ignore" -Level WARN
            } else {
                throw
            }
        }

        # Package de langue associe (optionnel, non bloquant)
        $localeCab = Join-Path $localeBasePath "${pkgName}_$($script:Config.Locale).cab"
        if (-not (Test-Path $localeCab)) {
            # Essayer avec le tiret au lieu du underscore
            $localeCab = Join-Path $localeBasePath "$pkgName`_$($script:Config.Locale).cab"
        }
        if (Test-Path $localeCab) {
            Write-WinPELog "  + Pack langue ($($script:Config.Locale))" -Level INFO
            $dismLangArgs = @("/Image:$MountPath", '/Add-Package', "/PackagePath:$localeCab")
            try { Invoke-DISM $dismLangArgs } catch {
                Write-WinPELog "  Pack langue non installe : $_" -Level WARN
            }
        }
        Write-WinPELog "Package installe : $pkgName" -Level SUCCESS
    }  foreach ($pkg in $Package) {
        # Resolution du nom complet si raccourci utilise
        $pkgName = if ($packageMap.ContainsKey($pkg)) { $packageMap[$pkg] } else { $pkg }

        # Chemin du .cab principal
        $cabPath = Join-Path $packagesBasePath "$pkgName.cab"
        if (-not (Test-Path $cabPath)) {
            Write-WinPELog "Package introuvable : $cabPath" -Level WARN
            continue
        }

        Write-WinPELog "Installation : $pkgName" -Level INFO
        $dismPkgArgs = @("/Image:$MountPath", '/Add-Package', "/PackagePath:$cabPath")
        Invoke-DISM $dismPkgArgs

        # Package de langue associe (optionnel, non bloquant)
        $localeCab = Join-Path $localeBasePath "$pkgName`_$($script:Config.Locale).cab"
        if (Test-Path $localeCab) {
            Write-WinPELog "  + Pack langue ($($script:Config.Locale))" -Level INFO
            $dismLangArgs = @("/Image:$MountPath", '/Add-Package', "/PackagePath:$localeCab")
            Invoke-DISM $dismLangArgs
        }

        Write-WinPELog "Package installe : $pkgName" -Level SUCCESS
    }
}

function Get-WinPEAvailablePackages {
    <#
    .SYNOPSIS Liste les packages WinPE disponibles dans l'ADK installe.#>
    [CmdletBinding()]
    param(
        [ValidateSet('amd64','x86','arm64')]
        [string]$Architecture = $script:Config.Architecture
    )

    $packagesPath = Join-Path $script:Config.WinPEAddonPath "OptionalComponents\$Architecture"
    if (-not (Test-Path $packagesPath)) {
        throw "Dossier packages introuvable : $packagesPath"
    }

    Get-ChildItem $packagesPath -Filter '*.cab' |
        Where-Object { $_.Name -notmatch '_[a-z]{2}-[A-Z]{2}' } |
        Select-Object @{N='Package';E={$_.BaseName}}, @{N='Taille';E={"{0:N0} KB" -f ($_.Length/1KB)}} |
        Sort-Object Package
}

# -----------------------------------------------------------------------------
# FONCTION 5 : PERSONNALISATION DU WINPE
# -----------------------------------------------------------------------------

function Set-WinPECustomization {
    <#
    .SYNOPSIS
        Personnalise l'image WinPE montee (fond d'ecran, scripts de demarrage, etc.)
    .DESCRIPTION
        - Copie des fichiers dans le WIM monte
        - Configure startnet.cmd pour lancer des scripts au boot
        - Definit la police de la console WinPE
    .PARAMETER MountPath
        Chemin du point de montage WinPE.
    .PARAMETER StartnetCommands
        Tableau de commandes a ajouter dans startnet.cmd (apres wpeinit).
    .PARAMETER FilesToCopy
        Hashtable @{'source\path' = 'destination\dans\winpe'} pour copier des fichiers.
    .PARAMETER WallpaperPath
        Chemin vers un fichier .bmp a utiliser comme fond d'ecran WinPE.
    .EXAMPLE
        Set-WinPECustomization -MountPath 'D:\WinPE-Work\mount' `
            -StartnetCommands @('powershell.exe -File X:\Deploy\Start-Deploy.ps1') `
            -FilesToCopy @{'D:\Scripts\Deploy' = 'Deploy'}
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$MountPath,
        [string[]]$StartnetCommands,
        [hashtable]$FilesToCopy,
        [string]$WallpaperPath
    )

    Write-WinPELog "=== Personnalisation WinPE ===" -Level STEP

    # Modification de startnet.cmd
    if ($StartnetCommands) {
        $startnetPath = Join-Path $MountPath 'Windows\System32\startnet.cmd'
        $content = Get-Content $startnetPath -Raw
        # Ajouter les commandes apres wpeinit
        $additions = $StartnetCommands -join "`r`n"
        $content = $content.TrimEnd() + "`r`n$additions`r`n"
        Set-Content -Path $startnetPath -Value $content -Encoding ASCII
        Write-WinPELog "startnet.cmd mis a jour avec $($StartnetCommands.Count) commande(s)" -Level SUCCESS
    }

    # Configuration locale et clavier WinPE
    # Sans ca, WinPE demarre en QWERTY meme si locale = fr-FR
    try {
        $localeCode = $script:Config.Locale
        # Mapper locale -> code clavier LCID
        $keyboardMap = @{
            'fr-FR' = '040c:0000040c'   # AZERTY France
            'fr-BE' = '080c:0000080c'   # AZERTY Belgique
            'fr-CH' = '100c:00000100'   # QWERTZ Suisse
            'de-DE' = '0407:00000407'   # QWERTZ Allemagne
            'de-AT' = '0c07:00000407'   # QWERTZ Autriche
            'es-ES' = '0c0a:0000040a'   # QWERTY Espagne
            'it-IT' = '0410:00000410'   # QWERTY Italie
            'en-US' = '0409:00000409'   # QWERTY US
            'en-GB' = '0809:00000809'   # QWERTY UK
        }
        $inputLocale = if ($keyboardMap.ContainsKey($localeCode)) { $keyboardMap[$localeCode] } else { '040c:0000040c' }
        $uiLocale    = $localeCode

        Write-WinPELog "Configuration locale WinPE : $uiLocale / clavier : $inputLocale" -Level INFO

        # UILanguage
        $dismLocaleArgs = @("/Image:$MountPath", '/Set-UILanguage:en-US', '/Set-UILanguageFallback:en-US')
        try { Invoke-DISM $dismLocaleArgs } catch { Write-WinPELog "UILanguage : $_ (non bloquant)" -Level WARN }

        # InputLocale (clavier)
        $dismInputArgs  = @("/Image:$MountPath", "/Set-InputLocale:$inputLocale")
        try { Invoke-DISM $dismInputArgs } catch { Write-WinPELog "InputLocale : $_ (non bloquant)" -Level WARN }

        # UserLocale et SystemLocale
        $dismUserArgs   = @("/Image:$MountPath", "/Set-UserLocale:$localeCode")
        try { Invoke-DISM $dismUserArgs } catch { Write-WinPELog "UserLocale : $_ (non bloquant)" -Level WARN }

        $dismSysArgs    = @("/Image:$MountPath", "/Set-SysLocale:$localeCode")
        try { Invoke-DISM $dismSysArgs } catch { Write-WinPELog "SysLocale : $_ (non bloquant)" -Level WARN }

        # TimeZone (facultatif mais pratique)
        $tzMap = @{
            'fr-FR' = 'Romance Standard Time'
            'fr-BE' = 'Romance Standard Time'
            'de-DE' = 'W. Europe Standard Time'
            'es-ES' = 'Romance Standard Time'
            'it-IT' = 'W. Europe Standard Time'
        }
        if ($tzMap.ContainsKey($localeCode)) {
            $dismTZArgs = @("/Image:$MountPath", "/Set-TimeZone:$($tzMap[$localeCode])")
            try { Invoke-DISM $dismTZArgs } catch { Write-WinPELog "TimeZone : $_ (non bloquant)" -Level WARN }
        }

        Write-WinPELog "Locale WinPE configuree : AZERTY ($localeCode)" -Level SUCCESS
    } catch {
        Write-WinPELog "Configuration locale echouee : $_ (non bloquant)" -Level WARN
    }

    # Copie de fichiers dans le WIM monte
    if ($FilesToCopy) {
        foreach ($source in $FilesToCopy.Keys) {
            $dest = Join-Path $MountPath $FilesToCopy[$source]
            if (-not (Test-Path $dest)) {
                New-Item -ItemType Directory -Path $dest -Force | Out-Null
            }
            # Copier le CONTENU du dossier (source\*) et non le dossier lui-meme
            # Copy-Item dossier -> dest existant cree dest\NomDossier (doublon)
            # Copy-Item dossier\* -> dest copie les fichiers directement
            if (Test-Path $source -PathType Container) {
                Copy-Item (Join-Path $source '*') $dest -Recurse -Force
            } else {
                Copy-Item $source $dest -Force
            }
            Write-WinPELog "Copie : $source\* -> $dest" -Level SUCCESS
        }
    }

    # Remplacement du fond d'ecran
    if ($WallpaperPath) {
        if (-not (Test-Path $WallpaperPath)) {
            Write-WinPELog "Fond d'ecran introuvable : $WallpaperPath" -Level WARN
        } else {
            $winpeBg = Join-Path $MountPath 'Windows\System32\winpe.bmp'
            Copy-Item $WallpaperPath $winpeBg -Force
            Write-WinPELog "Fond d'ecran applique" -Level SUCCESS
        }
    }
}

# -----------------------------------------------------------------------------
# FONCTION 6 : VALIDER ET DEMONTER LE WIM
# -----------------------------------------------------------------------------

function Save-WinPEImage {
    <#
    .SYNOPSIS
        Valide les modifications et demonte le WIM WinPE.
    .DESCRIPTION
        Execute DISM /Unmount-Image /Commit pour enregistrer toutes les
        modifications apportees a l'image montee.
    .PARAMETER MountPath
        Chemin du point de montage WinPE.
    .PARAMETER Discard
        Abandonne les modifications au lieu de les valider.
    .EXAMPLE
        Save-WinPEImage -MountPath 'D:\WinPE-Work\mount'
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$MountPath,
        [switch]$Discard
    )

    Write-WinPELog "=== Unmounting the WIM ===" -Level STEP

    if ($Discard) {
        Write-WinPELog "Discarding changes (Discard)" -Level WARN
        Invoke-DISM @('/Unmount-Image', "/MountDir:$MountPath", '/Discard')
    } else {
        Write-WinPELog "Validating and committing changes..." -Level INFO
        Invoke-DISM @('/Unmount-Image', "/MountDir:$MountPath", '/Commit')
        Write-WinPELog "WIM saved successfully" -Level SUCCESS
    }
}

# -----------------------------------------------------------------------------
# FONCTION 7 : CONSTRUIRE LE MEDIA BOOTABLE
# -----------------------------------------------------------------------------

function Build-WinPEMedia {
    <#
    .SYNOPSIS
        Genere un ISO bootable ou prepare une cle USB depuis le workspace WinPE.
    .DESCRIPTION
        - Mode ISO  : utilise MakeWinPEMedia /ISO pour creer un fichier .iso
        - Mode USB  : utilise MakeWinPEMedia /UFD pour formater et copier sur une cle USB
        - Mode Both : genere les deux
    .PARAMETER WorkspacePath
        Chemin du workspace WinPE (cree par New-WinPEEnvironment).
    .PARAMETER OutputPath
        Chemin de sortie de l'ISO (si mode ISO).
    .PARAMETER UsbDriveLetter
        Lettre du lecteur USB (ex: 'E:') pour le mode USB.
    .PARAMETER Mode
        ISO | USB | Both
    .PARAMETER ISOFileName
        Nom du fichier ISO genere (defaut : WinPE.iso).
    .EXAMPLE
        Build-WinPEMedia -WorkspacePath 'D:\WinPE-Work' -Mode ISO -OutputPath 'D:\Output'
    .EXAMPLE
        Build-WinPEMedia -WorkspacePath 'D:\WinPE-Work' -Mode USB -UsbDriveLetter 'E:'
    .OUTPUTS
        [PSCustomObject] avec les chemins des fichiers generes.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$WorkspacePath,
        [string]$OutputPath     = (Join-Path $WorkspacePath 'output'),
        [string]$UsbDriveLetter,
        [ValidateSet('ISO','USB','Both')]
        [string]$Mode           = 'ISO',
        [string]$ISOFileName    = 'WinPE.iso'
    )

    Write-WinPELog "=== Building WinPE media ===" -Level STEP

    $makeMedia = Join-Path $script:Config.WinPEAddonPath 'MakeWinPEMedia.cmd'
    if (-not (Test-Path $makeMedia)) {
        throw "MakeWinPEMedia.cmd introuvable : $makeMedia"
    }

    $mediaPath = Join-Path $WorkspacePath 'media'
    if (-not (Test-Path $mediaPath)) {
        throw "Dossier media introuvable : $mediaPath -- Avez-vous execute New-WinPEEnvironment ?"
    }

    $results = [PSCustomObject]@{
        ISOPath = $null
        USBPath = $null
    }

    # -- Mode ISO --
    if ($Mode -in 'ISO','Both') {
        if (-not (Test-Path $OutputPath)) {
            New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null
        }
        $isoPath = Join-Path $OutputPath $ISOFileName

        Write-WinPELog "Creation ISO : $isoPath" -Level INFO

        # Verifier que le WIM est bien en place apres demontage
        $bootWim = Join-Path $WorkspacePath 'media\sources\boot.wim'
        if (-not (Test-Path $bootWim)) {
            throw "boot.wim introuvable apres demontage : $bootWim`nVerifier que Save-WinPEImage a reussi."
        }

        # Supprimer l ISO existant -- oscdimg echoue si le fichier destination existe
        if (Test-Path $isoPath) {
            Write-WinPELog "Suppression ISO existant : $isoPath" -Level WARN
            Remove-Item $isoPath -Force
        }

        # Meme approche que copype.cmd : DandISetEnv.bat + Set-Location + nom court
        $dandI = Join-Path $script:Config.AdkPath 'Deployment Tools\DandISetEnv.bat'
        $tmpCmdISO = [System.IO.Path]::GetTempFileName() + '.cmd'
        $isoScript  = "@echo off`r`n"
        $isoScript += "call `"$dandI`"`r`n"
        $isoScript += "call MakeWinPEMedia.cmd /ISO `"$WorkspacePath`" `"$isoPath`"`r`n"
        $isoScript += "exit /b %errorlevel%`r`n"
        Set-Content -Path $tmpCmdISO -Value $isoScript -Encoding ASCII
        Write-WinPELog "Script ISO temporaire : $tmpCmdISO" -Level INFO
        Get-Content $tmpCmdISO | ForEach-Object { Write-WinPELog "  $_" -Level INFO }
        $prevLoc = Get-Location
        try {
            Set-Location $script:Config.WinPEAddonPath
            # Utiliser Start-Process pour eviter que les messages stderr d oscdimg
            # (comme '0% complete') ne declenchent NativeCommandError
            $psi = New-Object System.Diagnostics.ProcessStartInfo
            $psi.FileName  = $env:ComSpec
            $psi.Arguments = "/c `"$tmpCmdISO`""
            $psi.WorkingDirectory = $script:Config.WinPEAddonPath
            $psi.RedirectStandardOutput = $true
            $psi.RedirectStandardError  = $true
            $psi.UseShellExecute = $false
            $psi.CreateNoWindow  = $true
            $proc = New-Object System.Diagnostics.Process
            $proc.StartInfo = $psi
            $proc.Start() | Out-Null
            # Lire stdout et stderr en async pour eviter le deadlock buffer
            $taskOut = $proc.StandardOutput.ReadToEndAsync()
            $taskErr = $proc.StandardError.ReadToEndAsync()
            $proc.WaitForExit()
            $exitISO  = $proc.ExitCode
            $stdoutISO = $taskOut.GetAwaiter().GetResult()
            $stderrISO = $taskErr.GetAwaiter().GetResult()
            # Afficher toute la sortie -- oscdimg et MakeWinPEMedia ecrivent sur stderr
            ($stdoutISO + $stderrISO).Split("`n") | Where-Object { $_.Trim() } |
                ForEach-Object { Write-Host "  $_" -ForegroundColor DarkGray }
            if ($exitISO -ne 0) {
                throw "MakeWinPEMedia /ISO a echoue (code $exitISO)"
            }
        } finally {
            Set-Location $prevLoc
            Remove-Item $tmpCmdISO -Force -ErrorAction SilentlyContinue
        }

        $isoSize = (Get-Item $isoPath).Length / 1MB
        Write-WinPELog "ISO cree : $isoPath ($([Math]::Round($isoSize,1)) MB)" -Level SUCCESS
        $results.ISOPath = $isoPath
    }

    # -- Mode USB --
    if ($Mode -in 'USB','Both') {
        if (-not $UsbDriveLetter) {
            throw "The -UsbDriveLetter parameter is required for USB mode"
        }
        $driveLetter = $UsbDriveLetter.TrimEnd('\').TrimEnd(':') + ':'
        Write-WinPELog "Preparation cle USB : $driveLetter" -Level WARN
        Write-WinPELog "ATTENTION : La cle $driveLetter va etre FORMATEE !" -Level WARN

        # Meme approche que copype : DandISetEnv.bat + Set-Location + nom court
        $dandIU = Join-Path $script:Config.AdkPath 'Deployment Tools\DandISetEnv.bat'
        $tmpCmdUFD = [System.IO.Path]::GetTempFileName() + '.cmd'
        $ufdScript  = "@echo off`r`n"
        $ufdScript += "call `"$dandIU`"`r`n"
        $ufdScript += "call MakeWinPEMedia.cmd /UFD `"$WorkspacePath`" $driveLetter`r`n"
        $ufdScript += "exit /b %errorlevel%`r`n"
        Set-Content -Path $tmpCmdUFD -Value $ufdScript -Encoding ASCII
        $prevLocU = Get-Location
        try {
            Set-Location $script:Config.WinPEAddonPath
            $psiUFD = New-Object System.Diagnostics.ProcessStartInfo
            $psiUFD.FileName  = $env:ComSpec
            $psiUFD.Arguments = "/c `"$tmpCmdUFD`""
            $psiUFD.WorkingDirectory = $script:Config.WinPEAddonPath
            $psiUFD.RedirectStandardOutput = $true
            $psiUFD.RedirectStandardError  = $true
            $psiUFD.UseShellExecute = $false
            $psiUFD.CreateNoWindow  = $true
            $procUFD = New-Object System.Diagnostics.Process
            $procUFD.StartInfo = $psiUFD
            $procUFD.Start() | Out-Null
            $taskOutUFD = $procUFD.StandardOutput.ReadToEndAsync()
            $taskErrUFD = $procUFD.StandardError.ReadToEndAsync()
            $procUFD.WaitForExit()
            $exitUFD = $procUFD.ExitCode
            $outUFD = $taskOutUFD.GetAwaiter().GetResult()
            $errUFD = $taskErrUFD.GetAwaiter().GetResult()
            ($outUFD + $errUFD).Split("`n") | Where-Object { $_.Trim() } |
                ForEach-Object { Write-Host "  $_" -ForegroundColor DarkGray }
            if ($exitUFD -ne 0) {
                throw "MakeWinPEMedia /UFD a echoue (code $exitUFD)"
            }
        } finally {
            Set-Location $prevLocU
            Remove-Item $tmpCmdUFD -Force -ErrorAction SilentlyContinue
        }
        Write-WinPELog "Cle USB prete : $driveLetter" -Level SUCCESS
        $results.USBPath = $driveLetter
    }

    return $results
}

# -----------------------------------------------------------------------------
# FONCTION 8 : WORKFLOW COMPLET (PIPELINE)
# -----------------------------------------------------------------------------


# ---------------------------------------------------------------------------
# FONCTION : INJECTION DRIVERS WinPE PAR CATEGORIE
# ---------------------------------------------------------------------------

function Add-WinPEDrivers {
    <#
    .SYNOPSIS
        Injecte les drivers WinPE par categorie (Net, Storage, Sys).
    .DESCRIPTION
        Wrapper de Add-WinPEDriver qui gere les trois categories necessaires :
          Net     : drivers reseau (NIC) -- indispensable pour acceder aux partages SMB
          Storage : drivers stockage (NVMe, SATA, RAID) -- pour voir les disques
          Sys     : drivers systeme (chipset, USB 3.x) -- recommande

        Detecte automatiquement les sous-dossiers Net/Storage/Sys si DriversRoot fourni.
        Note : WinPE inclut deja de nombreux drivers inbox Microsoft.
        N ajouter que ce qui manque pour vos modeles de machines.

    .PARAMETER MountPath    Point de montage WinPE.
    .PARAMETER DriversRoot  Racine contenant Net\, Storage\, Sys\ (ou WinPE\Net\ etc).
    .PARAMETER NetPath      Dossier drivers reseau uniquement.
    .PARAMETER StoragePath  Dossier drivers stockage uniquement.
    .PARAMETER SysPath      Dossier drivers systeme uniquement.
    .PARAMETER Force        Continue si un chemin est inaccessible.

    .EXAMPLE
        # Structure automatique
        Add-WinPEDrivers -MountPath 'D:\WinPE\mount' -DriversRoot '\\SRV\Drivers\WinPE'
        # Detecte : \\SRV\Drivers\WinPE\Net\, \Storage\, \Sys\

    .EXAMPLE
        # Chemins explicites
        Add-WinPEDrivers -MountPath 'D:\WinPE\mount' `
            -NetPath     '\\SRV\Drivers\WinPE\Net' `
            -StoragePath '\\SRV\Drivers\WinPE\Storage' `
            -SysPath     '\\SRV\Drivers\WinPE\Sys'
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$MountPath,
        [string]$DriversRoot,
        [string]$NetPath,
        [string]$StoragePath,
        [string]$SysPath,
        [string]$AllPath,
        [switch]$Force
    )

    Write-WinPELog "=== Injecting WinPE drivers ===" -Level STEP

    # MODE VRAC : si AllPath est fourni (ou si DriversRoot contient des .inf
    # directement, sans sous-dossiers Net/Storage/Sys), on injecte TOUT le
    # dossier en recursif. Ideal pour les drivers VirtIO/QEMU (Proxmox) ou
    # tout pack de drivers non range par categorie.
    if (-not $AllPath -and $DriversRoot -and (Test-Path $DriversRoot -EA SilentlyContinue)) {
        $hasCatFolders = $false
        foreach ($cat in @('Net','Storage','Sys')) {
            if (Test-Path (Join-Path $DriversRoot $cat) -EA SilentlyContinue) { $hasCatFolders = $true; break }
        }
        $directInf = @(Get-ChildItem $DriversRoot -Filter '*.inf' -Recurse -EA SilentlyContinue)
        if (-not $hasCatFolders -and $directInf.Count -gt 0) {
            $AllPath = $DriversRoot
            Write-WinPELog "  Dossier sans categories mais $($directInf.Count) .inf detecte(s) -> injection VRAC." -Level INFO
        }
    }
    if ($AllPath -and (Test-Path $AllPath -EA SilentlyContinue)) {
        $cnt = @(Get-ChildItem $AllPath -Filter '*.inf' -Recurse -EA SilentlyContinue).Count
        Write-WinPELog "  Injection VRAC (recursif) depuis : $AllPath ($cnt .inf)" -Level INFO
        Add-WinPEDriver -MountPath $MountPath -DriverPath $AllPath -Recurse
        Write-WinPELog "Drivers injectes en vrac depuis $AllPath" -Level SUCCESS
        return
    }

    $injected = @()
    $skipped  = @()

    $autoSubFolders = @{
        Net     = @('Net','Network','NIC','LAN','Ethernet')
        Storage = @('Storage','NVMe','SATA','RAID','HBA','SAS')
        Sys     = @('Sys','System','Chipset','USB','Controller')
    }

    # Auto-detection depuis DriversRoot
    if ($DriversRoot -and (Test-Path $DriversRoot -ErrorAction SilentlyContinue)) {
        foreach ($cat in @('Net','Storage','Sys')) {
            $varName = "${cat}Path"
            $current = Get-Variable $varName -ValueOnly -ErrorAction SilentlyContinue
            if (-not $current) {
                foreach ($sub in $autoSubFolders[$cat]) {
                    $c = Join-Path $DriversRoot $sub
                    if (Test-Path $c -ErrorAction SilentlyContinue) {
                        Set-Variable -Name $varName -Value $c -Scope Local
                        Write-WinPELog "  Auto [$cat] : $c" -Level INFO
                        break
                    }
                }
                # Essayer WinPE\<cat>
                $current = Get-Variable $varName -ValueOnly -ErrorAction SilentlyContinue
                if (-not $current) {
                    $wpe = Join-Path (Join-Path $DriversRoot 'WinPE') $cat
                    if (Test-Path $wpe -ErrorAction SilentlyContinue) {
                        Set-Variable -Name $varName -Value $wpe -Scope Local
                        Write-WinPELog "  Auto [WinPE\$cat] : $wpe" -Level INFO
                    }
                }
            }
        }
    }

    # Injection par categorie
    $categories = [ordered]@{
        'Net'     = $NetPath
        'Storage' = $StoragePath
        'Sys'     = $SysPath
    }

    foreach ($cat in $categories.Keys) {
        $catPath = $categories[$cat]
        if (-not $catPath) {
            Write-WinPELog "  [$cat] non configure (drivers inbox ADK)" -Level INFO
            $skipped += $cat
            continue
        }
        if (-not (Test-Path $catPath -ErrorAction SilentlyContinue)) {
            $msg = "  [$cat] introuvable : $catPath"
            if ($Force) { Write-WinPELog $msg -Level WARN; $skipped += $cat }
            else        { throw $msg }
            continue
        }
        Write-WinPELog "  Injection [$cat] depuis : $catPath" -Level INFO
        Add-WinPEDriver -MountPath $MountPath -DriverPath $catPath -Recurse
        $injected += $cat
    }

    # Resume
    if ($injected.Count -gt 0) {
        Write-WinPELog "Drivers injectes : $($injected -join ', ')" -Level SUCCESS
    }
    if ($skipped.Count -gt 0) {
        Write-WinPELog "Non configures   : $($skipped -join ', ')" -Level INFO
    }

    # Avertissements critiques
    if ('Net' -in $skipped) {
        Write-WinPELog "WARNING: no Net drivers -- WinPE will not be able to access the SMB shares!" -Level WARN
    }
    if ('Storage' -in $skipped) {
        Write-WinPELog "WARNING: no Storage drivers -- NVMe/RAID disks may not be seen" -Level WARN
    }
}

function Invoke-WinPEBuild {
    <#
    .SYNOPSIS
        Workflow complet : cree, personnalise et construit un WinPE en une seule commande.
    .DESCRIPTION
        Orchestre les appels a New-WinPEEnvironment, Add-WinPEDriver,
        Add-WinPEPackage, Set-WinPECustomization, Save-WinPEImage et Build-WinPEMedia.
        Pratique pour une utilisation en CI/CD ou depuis l'API REST.
    .PARAMETER WorkspacePath
        Dossier de travail.
    .PARAMETER Architecture
        Architecture cible.
    .PARAMETER Packages
        Liste de packages a installer (ex: @('PowerShell','WMI','NetFx')).
    .PARAMETER DriversPath
        Dossier de drivers a injecter (recursif).
    .PARAMETER StartnetCommands
        Commandes a ajouter dans startnet.cmd.
    .PARAMETER ExtraFiles
        Hashtable de fichiers a copier dans le WIM.
    .PARAMETER OutputPath
        Dossier de sortie pour l'ISO.
    .PARAMETER ISOFileName
        Nom du fichier ISO.
    .PARAMETER Force
        Ecrase le workspace existant.
    .EXAMPLE
        Invoke-WinPEBuild -WorkspacePath 'D:\WinPE' `
            -Packages @('PowerShell','WMI','NetFx','Scripting') `
            -DriversPath 'D:\Drivers' `
            -StartnetCommands @('powershell.exe -NoProfile -File X:\Deploy\Start-Deploy.ps1') `
            -OutputPath 'D:\ISO'
    #>
    [CmdletBinding()]
    param(
        [string]$WorkspacePath     = $script:Config.WorkspacePath,
        [ValidateSet('amd64','arm64')]
        [string]$Architecture      = $script:Config.Architecture,
        [string[]]$Packages        = @('PowerShell','WMI','NetFx','Scripting'),
        # Drivers WinPE -- 3 categories distinctes
    # Si seul DriversPath est fourni, il est utilise pour les 3 categories (recurse)
    # Sinon, specifier chaque categorie independamment
    [string]$DriversPath,           # Dossier global (recurse sur tous les sous-dossiers)
    [string]$DriversNetPath,        # Drivers reseau uniquement (NIC)
    [string]$DriversStoragePath,    # Drivers stockage (NVMe, SATA, RAID)
    [string]$DriversSysPath,        # Drivers systeme (chipset, USB)
        [string[]]$StartnetCommands,
        [hashtable]$ExtraFiles,
        [string]$OutputPath        = (Join-Path $WorkspacePath 'output'),
        [string]$ISOFileName       = 'WinPE.iso',
        [switch]$Force,

        # -- Connexion partages reseau ----------------------------------------
        # Server      : nom ou IP du serveur (ex: SERVEUR ou 192.168.1.10)
        # ShareUser   : SERVEUR\svc-winpe  ou  CORP\svc-winpe
        # SharePassword : en clair -- mode Plain comme MDT
        # VaultPath   : chemin vers secrets.vault a injecter dans le WIM
        #               (vault doit contenir winpeUser + winpePassword)
        # Si aucun param reseau fourni : mode Prompt (saisie WinPE)
        # Compte reseau WinPE pour l'acces aux partages SMB au boot
        [string]$Server,              # Nom/IP du serveur de deploiement
        [string]$ShareUser,           # Compte (ex: DEPLOYSRV\svc-winpe ou CORP\svc-winpe)
        [string]$SharePassword,       # Mot de passe (mode Plain -- en clair dans le vault WinPE)
        [string]$ShareVaultPath,      # Vault secrets.vault existant a injecter dans l'ISO
        [string]$ShareVaultPassword,  # Mot de passe AES pour chiffrer le vault WinPE
        [switch]$ShareVaultPlain      # Vault en clair (lab/test)
    )

    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    Write-WinPELog "+======================================+" -Level STEP
    Write-WinPELog "|   WINPE-BUILDER -- Pipeline start      |" -Level STEP
    Write-WinPELog "+======================================+" -Level STEP

    # Lire params reseau depuis PSWinDeploy.psd1 si non fournis explicitement
    try {
        $cfgMod = Join-Path (Split-Path $PSScriptRoot -Parent) 'Config\Config.psm1'
        if (Test-Path $cfgMod) {
            Import-Module $cfgMod -Force -ErrorAction SilentlyContinue
            $cfg = Get-PSWinDeployConfig -ErrorAction SilentlyContinue
            if ($cfg) {
                if (-not $Server        -and $cfg.WinPEShareServer)   { $Server        = $cfg.WinPEShareServer }
                if (-not $ShareUser     -and $cfg.WinPEShareUser)     { $ShareUser     = $cfg.WinPEShareUser }
                # WinPESharePassword optionnel dans psd1 -- fallback sur vault si absent
                if (-not $SharePassword) {
                    if ($cfg.WinPESharePassword) {
                        $SharePassword = $cfg.WinPESharePassword
                    } else {
                        # Lire depuis le vault existant (cle winpePassword)
                        $vaultPath = if ($cfg.VaultPath) { $cfg.VaultPath } else { 'C:\Deploy\secrets.vault' }
                        if (Test-Path $vaultPath -ErrorAction SilentlyContinue) {
                            try {
                                $v = Get-Content $vaultPath -Raw | ConvertFrom-Json
                                if ($v.method -eq 'Plain') {
                                    $s = $v.data | ConvertFrom-Json
                                    if ($s.winpePassword)   { $SharePassword = $s.winpePassword }
                                    elseif ($s.sharePassword) { $SharePassword = $s.sharePassword }
                                    if ($SharePassword) { Write-WinPELog 'Mot de passe WinPE lu depuis vault' -Level INFO }
                                }
                                # Vault AES : le mot de passe vault sera demande par New-WinPEShareVault
                            } catch {}
                        }
                    }
                }
            }
        }
    } catch { Write-WinPELog "Config reseau WinPE non lue depuis psd1 : $_" -Level INFO }

    try {
        # 1. Creer l'environnement
        $env = New-WinPEEnvironment -WorkspacePath $WorkspacePath -Architecture $Architecture -Force:$Force

        # 2. Packages
        if ($Packages) {
            Add-WinPEPackage -MountPath $env.MountPath -Package $Packages -Architecture $Architecture
        }

        # 3. Drivers WinPE -- injection par categorie
        # Priorite : chemins specifiques > dossier global > sous-dossiers automatiques
        $driverCategories = [ordered]@{
            'Net'     = $DriversNetPath
            'Storage' = $DriversStoragePath
            'Sys'     = $DriversSysPath
        }

        $anyDriverInjected = $false
        foreach ($cat in $driverCategories.Keys) {
            $catPath = $driverCategories[$cat]
            if ($catPath -and (Test-Path $catPath)) {
                Write-WinPELog "Drivers $cat : $catPath" -Level INFO
                Add-WinPEDriver -MountPath $env.MountPath -DriverPath $catPath -Recurse
                $anyDriverInjected = $true
            }
        }

        # Fallback : dossier global unique (ancien comportement)
        if (-not $anyDriverInjected -and $DriversPath -and (Test-Path $DriversPath)) {
            Write-WinPELog "Drivers (dossier global) : $DriversPath" -Level INFO
            # Chercher automatiquement les sous-dossiers Net, Storage, Sys
            foreach ($sub in @('Net','Network','NIC','Storage','NVMe','SATA','Sys','System','Chipset','USB')) {
                $subPath = Join-Path $DriversPath $sub
                if (Test-Path $subPath) {
                    Write-WinPELog "  Sous-dossier detecte : $sub" -Level INFO
                    Add-WinPEDriver -MountPath $env.MountPath -DriverPath $subPath -Recurse
                    $anyDriverInjected = $true
                }
            }
            # Si aucun sous-dossier trouve, tout injecter en recurse
            if (-not $anyDriverInjected) {
                Write-WinPELog "  Injection recursive de tout $DriversPath" -Level WARN
                Add-WinPEDriver -MountPath $env.MountPath -DriverPath $DriversPath -Recurse
            }
        }

        if (-not $anyDriverInjected) {
            Write-WinPELog "No additional driver injected -- ADK inbox drivers only" -Level WARN
            Write-WinPELog "Use -DriversNetPath, -DriversStoragePath, -DriversSysPath or -DriversPath" -Level INFO
        }

        # 4. Personnalisation generale
        $customParams = @{ MountPath = $env.MountPath }
        if ($StartnetCommands) { $customParams.StartnetCommands = $StartnetCommands }
        if ($ExtraFiles)       { $customParams.FilesToCopy       = $ExtraFiles }
        if ($customParams.Count -gt 1) {
            Set-WinPECustomization @customParams
        }

        # 5. Injection vault reseau WinPE (si configure)
        $vaultInjected = $false
        if ($ShareVaultPath -and (Test-Path $ShareVaultPath)) {
            # Copier un vault existant
            $destDir = Join-Path $env.MountPath 'Deploy'
            if (-not (Test-Path $destDir)) { New-Item -ItemType Directory $destDir -Force | Out-Null }
            Copy-Item $ShareVaultPath (Join-Path $destDir 'secrets.vault') -Force
            Write-WinPELog "Vault reseau injecte depuis : $ShareVaultPath" -Level SUCCESS
            $vaultInjected = $true
        } elseif ($ShareUser -and $SharePassword) {
            # Creer un vault a la volee et l'injecter
            $nsModPath = Join-Path $ModulesRoot 'NetShare\NetShare.psm1'
            # Fallback si modules non charges (appele standalone)
            $nsModPath2 = Join-Path (Split-Path $PSScriptRoot -Parent) 'NetShare\NetShare.psm1'
            foreach ($nsPath in @($nsModPath, $nsModPath2)) {
                if (Test-Path $nsPath) { Import-Module $nsPath -Force; break }
            }
            if (Get-Command New-WinPEShareVault -ErrorAction SilentlyContinue) {
                $tmpVaultDir = Join-Path $env:TEMP "winpe-vault-$(Get-Date -Format yyyyMMddHHmmss)"
                $vaultArgs   = @{
                    Username   = $ShareUser
                    Password   = $SharePassword
                    OutputPath = $tmpVaultDir
                }
                if ($ShareVaultPlain)    { $vaultArgs.Plain         = $true }
                if ($ShareVaultPassword) { $vaultArgs.VaultPassword = $ShareVaultPassword }

                $vaultFile = New-WinPEShareVault @vaultArgs
                $destDir   = Join-Path $env.MountPath 'Deploy'
                if (-not (Test-Path $destDir)) { New-Item -ItemType Directory $destDir -Force | Out-Null }
                Copy-Item $vaultFile (Join-Path $destDir 'secrets.vault') -Force
                Remove-Item $tmpVaultDir -Recurse -Force -ErrorAction SilentlyContinue
                Write-WinPELog "Vault reseau cree et injecte (compte : $ShareUser)" -Level SUCCESS
                $vaultInjected = $true
            } else {
                Write-WinPELog "NetShare module unavailable -- network vault not injected" -Level WARN
            }
        }
        if (-not $vaultInjected) {
            Write-WinPELog "No network vault configured -- use Plain or Prompt mode at boot" -Level WARN
        }

        # 6. Demontage + commit
        Save-WinPEImage -MountPath $env.MountPath

        # 7. Construction ISO
        $media = Build-WinPEMedia -WorkspacePath $WorkspacePath -OutputPath $OutputPath -ISOFileName $ISOFileName -Mode ISO

        $stopwatch.Stop()
        Write-WinPELog "======================================" -Level SUCCESS
        Write-WinPELog "Build termine en $([Math]::Round($stopwatch.Elapsed.TotalMinutes,1)) min" -Level SUCCESS
        Write-WinPELog "ISO : $($media.ISOPath)" -Level SUCCESS
        Write-WinPELog "======================================" -Level SUCCESS

        return $media

    } catch {
        Write-WinPELog "ERREUR : $_" -Level ERROR
        # Tenter un demontage propre en cas d'erreur
        Write-WinPELog "Attempting emergency unmount..." -Level WARN
        try {
            Invoke-DISM @('/Unmount-Image', "/MountDir:$(Join-Path $WorkspacePath 'mount')", '/Discard') 2>$null
        } catch {}
        throw
    }
}

# -----------------------------------------------------------------------------
# EXPORTS
# -----------------------------------------------------------------------------

Export-ModuleMember -Function @(
    'Set-WinPEConfig'
    'Get-WinPEConfig'
    'New-WinPEEnvironment'
    'Add-WinPEDriver'
    'Add-WinPEDrivers'
    'Add-WinPEPackage'
    'Get-WinPEAvailablePackages'
    'Set-WinPECustomization'
    'Save-WinPEImage'
    'Build-WinPEMedia'
    'Invoke-WinPEBuild'
)
