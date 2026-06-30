#Requires -RunAsAdministrator
<#
.SYNOPSIS
    WIM-Manager.psm1 -- Module de gestion des images WIM Windows
.DESCRIPTION
    Remplace les fonctions MDT de gestion d'images. Permet de capturer,
    monter, modifier, appliquer et exporter des images .wim/.esd.
    Toutes les operations DISM sont loguees et verifiees.
.NOTES
    Prerequis : DISM (inclus Windows ou ADK), droits Administrateur
    Usage     : Depuis Windows normal ou depuis WinPE
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# -----------------------------------------------------------------------------
# CONFIGURATION
# -----------------------------------------------------------------------------

$script:WimConfig = @{
    # Dossier de travail pour les montages temporaires
    MountBasePath   = "$env:TEMP\WIM-Mounts"
    # Dossier de logs
    LogPath         = "$env:TEMP\WIM-Manager"
    # Compression par defaut pour la capture
    CompressionType = 'Maximum'   # None | Fast | Maximum
    # Verifier l'integrite apres operations
    VerifyIntegrity = $true
}

# -----------------------------------------------------------------------------
# UTILITAIRES INTERNES
# -----------------------------------------------------------------------------

function Write-WimLog {
    param(
        [string]$Message,
        [ValidateSet('INFO','WARN','ERROR','SUCCESS','STEP')]
        [string]$Level = 'INFO'
    )
    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $icons  = @{ INFO='[~]'; WARN='[!]'; ERROR='[X]'; SUCCESS='[OK]'; STEP='[>>]' }
    $colors = @{ INFO='Cyan'; WARN='Yellow'; ERROR='Red'; SUCCESS='Green'; STEP='Magenta' }
    $line   = "$timestamp $($icons[$Level]) $Message"
    Write-Host $line -ForegroundColor $colors[$Level]

    # Ecriture dans le fichier de log si dossier accessible
    try {
        if (-not (Test-Path $script:WimConfig.LogPath)) {
            New-Item -ItemType Directory -Path $script:WimConfig.LogPath -Force | Out-Null
        }
        $logFile = Join-Path $script:WimConfig.LogPath "WIM-Manager_$(Get-Date -Format 'yyyyMMdd').log"
        Add-Content -Path $logFile -Value $line -Encoding UTF8
    } catch {}
}

function Invoke-DISMCommand {
    <#
    .SYNOPSIS Execute DISM en capturant la progression (%) en temps reel.
    .PARAMETER Arguments     Arguments DISM.
    .PARAMETER ShowProgress  Affiche une barre de progression (defaut pour Apply-Image).
    .PARAMETER Activity      Libelle de l'operation pour la barre.
    #>
    param(
        [string[]]$Arguments,
        [switch]$ShowProgress,
        [string]$Activity = 'DISM'
    )
    Write-WimLog "DISM $($Arguments -join ' ')" -Level INFO

    # Hook Progress (GUI) si disponible
    $hasHook = (Get-Command Write-PSWDProgress -EA SilentlyContinue) -ne $null

    $output = New-Object System.Collections.Generic.List[string]
    $lastPct = -1

    # Executer DISM et lire la sortie ligne par ligne pour capturer le %
    & dism.exe @Arguments 2>&1 | ForEach-Object {
        $line = "$_"
        $output.Add($line)
        # DISM affiche la progression sous forme [===  45.0%  ===]
        if ($line -match '(\d+(?:\.\d+)?)\s*%') {
            $pct = [int][Math]::Round([double]$Matches[1])
            if ($pct -ne $lastPct) {
                $lastPct = $pct
                if ($ShowProgress) {
                    if ($hasHook) {
                        Write-PSWDProgress -Percent $pct -Activity $Activity
                    } else {
                        Write-Progress -Activity $Activity -Status "$pct%" -PercentComplete $pct
                    }
                }
            }
        } elseif ($line.Trim()) {
            Write-Host "  $line" -ForegroundColor DarkGray
        }
    }

    if ($ShowProgress) { Write-Progress -Activity $Activity -Completed }

    if ($LASTEXITCODE -ne 0) {
        throw "DISM a echoue (code $LASTEXITCODE)`nCommande : dism.exe $($Arguments -join ' ')"
    }
    return $output.ToArray()
}

function Get-UniqueMountPath {
    <#Genere un chemin de montage unique base sur un GUID court#>
    param([string]$Prefix = 'wim')
    $guid  = [System.Guid]::NewGuid().ToString('N').Substring(0,8)
    $path  = Join-Path $script:WimConfig.MountBasePath "$Prefix`_$guid"
    New-Item -ItemType Directory -Path $path -Force | Out-Null
    return $path
}

function Format-FileSize {
    param([long]$Bytes)
    if ($Bytes -gt 1GB) { return "{0:N2} GB" -f ($Bytes/1GB) }
    if ($Bytes -gt 1MB) { return "{0:N1} MB" -f ($Bytes/1MB) }
    return "{0:N0} KB" -f ($Bytes/1KB)
}

# -----------------------------------------------------------------------------
# FONCTION 1 : INFORMATIONS SUR UN WIM
# -----------------------------------------------------------------------------

function Get-WIMInfo {
    <#
    .SYNOPSIS
        Affiche les informations detaillees d'un fichier WIM et ses index.
    .PARAMETER WimPath
        Chemin vers le fichier .wim ou .esd.
    .PARAMETER Index
        Si specifie, details d'un index particulier seulement.
    .EXAMPLE
        Get-WIMInfo -WimPath 'D:\Sources\install.wim'
    .EXAMPLE
        Get-WIMInfo -WimPath 'D:\Sources\install.wim' -Index 2
    .OUTPUTS
        [PSCustomObject[]] liste des images dans le WIM
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateScript({ Test-Path $_ })]
        [string]$WimPath,
        [int]$Index
    )

    Write-WimLog "Lecture des informations : $WimPath" -Level INFO

    $dismArgs = @('/Get-WimInfo', "/WimFile:$WimPath")
    if ($Index) { $dismArgs += "/Index:$Index" }

    $output = Invoke-DISMCommand $dismArgs

    # Parser la sortie DISM en objets PowerShell
    $images  = @()
    $current = $null

    foreach ($line in $output) {
        $line = $line.Trim()
        if ($line -match '^Index\s*:\s*(\d+)') {
            if ($current) { $images += $current }
            $current = [PSCustomObject]@{
                Index        = [int]$Matches[1]
                Name         = ''
                Description  = ''
                Size         = ''
                Architecture = ''
                Edition      = ''
                Language     = ''
                Build        = ''
            }
        }
        if ($current) {
            switch -Regex ($line) {
                '^Name\s*:\s*(.+)'         { $current.Name         = $Matches[1] }
                '^Description\s*:\s*(.+)'  { $current.Description  = $Matches[1] }
                '^Size\s*:\s*(.+)'         { $current.Size         = $Matches[1] }
                '^Architecture\s*:\s*(.+)' { $current.Architecture = $Matches[1] }
                '^Edition ID\s*:\s*(.+)'   { $current.Edition      = $Matches[1] }
                '^Default Language\s*:\s*(.+)' { $current.Language = $Matches[1] }
                '^Version\s*:\s*(.+)'      { $current.Build        = $Matches[1] }
            }
        }
    }
    if ($current) { $images += $current }

    # Affichage tableau recapitulatif
    $fileSize = Format-FileSize (Get-Item $WimPath).Length
    Write-WimLog "Fichier : $WimPath ($fileSize) -- $(@($images).Count) image(s)" -Level SUCCESS
    $images | Format-Table -AutoSize | Out-String | Write-Host

    return $images
}

# -----------------------------------------------------------------------------
# FONCTION 2 : CAPTURER UNE IMAGE
# -----------------------------------------------------------------------------

function New-WIMCapture {
    <#
    .SYNOPSIS
        Capture un volume/dossier dans un fichier WIM.
    .DESCRIPTION
        Cree une nouvelle image WIM depuis un volume source (typiquement C:\
        ou un volume syspreppe). Supporte l'ajout d'une image dans un WIM
        existant (multi-index).
    .PARAMETER SourcePath
        Volume ou dossier source a capturer (ex: 'C:\' ou 'D:\').
    .PARAMETER WimPath
        Chemin de destination du fichier .wim a creer ou dans lequel ajouter.
    .PARAMETER Name
        Nom de l'image dans le WIM (ex: 'Windows 11 Pro - Base').
    .PARAMETER Description
        Description de l'image.
    .PARAMETER CompressionType
        None | Fast | Maximum (defaut selon config).
    .PARAMETER Append
        Ajoute l'image dans un WIM existant au lieu d'ecraser.
    .PARAMETER Verify
        Verifie l'integrite apres capture.
    .PARAMETER Exclude
        Liste de chemins relatifs a exclure (ex: @('pagefile.sys','hiberfil.sys')).
    .EXAMPLE
        New-WIMCapture -SourcePath 'C:\' -WimPath 'D:\Images\Win11Pro.wim' -Name 'Win11 Pro Base'
    .EXAMPLE
        New-WIMCapture -SourcePath 'C:\' -WimPath 'D:\Images\Windows.wim' -Name 'Win11 Pro v2' -Append
    .OUTPUTS
        [PSCustomObject] avec WimPath, Index, Name, Duration
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$SourcePath,
        [Parameter(Mandatory)]
        [string]$WimPath,
        [Parameter(Mandatory)]
        [string]$Name,
        [string]$Description    = $Name,
        [ValidateSet('None','Fast','Maximum')]
        [string]$CompressionType = $script:WimConfig.CompressionType,
        [switch]$Append,
        [switch]$Verify,
        [string[]]$Exclude       = @('pagefile.sys','hiberfil.sys','swapfile.sys','System Volume Information','$Recycle.Bin')
    )

    Write-WimLog "=== Capture WIM ===" -Level STEP
    Write-WimLog "Source      : $SourcePath" -Level INFO
    Write-WimLog "Destination : $WimPath" -Level INFO
    Write-WimLog "Nom         : $Name" -Level INFO
    Write-WimLog "Compression : $CompressionType" -Level INFO

    # Creation du dossier destination si besoin
    $wimDir = Split-Path $WimPath -Parent
    if (-not (Test-Path $wimDir)) {
        New-Item -ItemType Directory -Path $wimDir -Force | Out-Null
    }

    # Choix de la commande DISM
    $dismCmd = if ($Append -and (Test-Path $WimPath)) { '/Append-Image' } else { '/Capture-Image' }

    $dismArgs = @(
        $dismCmd,
        "/ImageFile:$WimPath",
        "/CaptureDir:$SourcePath",
        "/Name:$Name",
        "/Description:$Description",
        "/Compress:$($CompressionType.ToLower())"
    )

    if ($Verify) { $dismArgs += '/Verify' }
    if ($Exclude) {
        foreach ($ex in $Exclude) {
            $dismArgs += "/ExcludePath:$ex"
        }
    }

    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    Invoke-DISMCommand $dismArgs -ShowProgress -Activity "Application de $($imageInfo.Name)"
    $stopwatch.Stop()

    # Recuperation de l'index cree
    $wimInfo = Get-WIMInfo -WimPath $WimPath
    $newImage = $wimInfo | Where-Object { $_.Name -eq $Name } | Select-Object -Last 1

    $duration = $stopwatch.Elapsed
    Write-WimLog "Capture terminee en $([Math]::Round($duration.TotalMinutes,1)) min" -Level SUCCESS
    Write-WimLog "WIM : $WimPath ($(Format-FileSize (Get-Item $WimPath).Length))" -Level SUCCESS

    return [PSCustomObject]@{
        WimPath  = $WimPath
        Index    = $newImage.Index
        Name     = $Name
        FileSize = Format-FileSize (Get-Item $WimPath).Length
        Duration = $duration
    }
}

# -----------------------------------------------------------------------------
# FONCTION 3 : MONTER UN WIM
# -----------------------------------------------------------------------------

function Mount-WIMImage {
    <#
    .SYNOPSIS
        Monte un index WIM dans un dossier pour modification ou inspection.
    .PARAMETER WimPath
        Chemin vers le fichier .wim.
    .PARAMETER Index
        Index de l'image a monter (defaut : 1).
    .PARAMETER MountPath
        Dossier de montage. Si omis, genere un chemin temporaire unique.
    .PARAMETER ReadOnly
        Monte en lecture seule (pas de modification possible).
    .EXAMPLE
        $mount = Mount-WIMImage -WimPath 'D:\Images\Win11.wim' -Index 1
        # Modifier des fichiers dans $mount.MountPath
        Save-WIMImage -MountPath $mount.MountPath
    .OUTPUTS
        [PSCustomObject] avec MountPath, WimPath, Index
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateScript({ Test-Path $_ })]
        [string]$WimPath,
        [int]$Index       = 1,
        [string]$MountPath,
        [switch]$ReadOnly
    )

    Write-WimLog "=== Mounting WIM ===" -Level STEP

    if (-not $MountPath) {
        $MountPath = Get-UniqueMountPath -Prefix 'wim'
        Write-WimLog "Point de montage genere : $MountPath" -Level INFO
    } elseif (-not (Test-Path $MountPath)) {
        New-Item -ItemType Directory -Path $MountPath -Force | Out-Null
    }

    $dismArgs = @(
        '/Mount-Image',
        "/ImageFile:$WimPath",
        "/Index:$Index",
        "/MountDir:$MountPath"
    )
    if ($ReadOnly) { $dismArgs += '/ReadOnly' }

    Invoke-DISMCommand $dismArgs
    Write-WimLog "WIM monte : $WimPath [Index $Index] -> $MountPath" -Level SUCCESS

    return [PSCustomObject]@{
        MountPath = $MountPath
        WimPath   = $WimPath
        Index     = $Index
        ReadOnly  = $ReadOnly.IsPresent
    }
}

# -----------------------------------------------------------------------------
# FONCTION 4 : SAUVEGARDER / DEMONTER UN WIM
# -----------------------------------------------------------------------------

function Save-WIMImage {
    <#
    .SYNOPSIS
        Valide les modifications et demonte un WIM monte.
    .PARAMETER MountPath
        Chemin du point de montage.
    .PARAMETER Discard
        Abandonne les modifications (pas de commit).
    .EXAMPLE
        Save-WIMImage -MountPath 'C:\Temp\WIM-Mounts\wim_a1b2c3d4'
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$MountPath,
        [switch]$Discard
    )

    if ($Discard) {
        Write-WimLog "Abandon des modifications : $MountPath" -Level WARN
        Invoke-DISMCommand @('/Unmount-Image', "/MountDir:$MountPath", '/Discard')
    } else {
        Write-WimLog "Commit et demontage : $MountPath" -Level INFO
        Invoke-DISMCommand @('/Unmount-Image', "/MountDir:$MountPath", '/Commit')
        Write-WimLog "Modifications sauvegardees" -Level SUCCESS
    }

    # Nettoyage du dossier de montage vide
    try {
        if ((Get-ChildItem $MountPath -Force -ErrorAction SilentlyContinue).Count -eq 0) {
            Remove-Item $MountPath -Force -ErrorAction SilentlyContinue
        }
    } catch {}
}

function Repair-WIMMountCleanup {
    <#
    .SYNOPSIS
        Nettoie les montages WIM orphelins (apres crash ou interruption).
    .DESCRIPTION
        Utilise DISM /Cleanup-Mountpoints pour liberer les ressources
        de montages qui n'ont pas ete correctement demontes.
    .EXAMPLE
        Repair-WIMMountCleanup
    #>
    Write-WimLog "Cleaning orphan mounts..." -Level WARN
    Invoke-DISMCommand @('/Cleanup-Mountpoints')
    Write-WimLog "Cleanup complete" -Level SUCCESS
}

# -----------------------------------------------------------------------------
# FONCTION 5 : APPLIQUER UN WIM SUR UN DISQUE
# -----------------------------------------------------------------------------

function Apply-WIMImage {
    <#
    .SYNOPSIS
        Applique une image WIM sur une partition cible (deploiement).
    .DESCRIPTION
        C?ur du deploiement : applique un index WIM sur une partition formatee.
        C'est l'equivalent de l'etape "Apply Operating System" de MDT.
        A utiliser depuis WinPE apres avoir partitionne le disque.
    .PARAMETER WimPath
        Chemin vers le fichier .wim source (chemin reseau ou local).
    .PARAMETER Index
        Index de l'image a appliquer (defaut : 1).
    .PARAMETER TargetPath
        Lettre de lecteur ou chemin de la partition cible (ex: 'W:\').
    .PARAMETER Verify
        Verifie l'integrite apres application.
    .PARAMETER ScratchDir
        Dossier scratch pour DISM (ameliore les performances sur petits disques).
    .EXAMPLE
        Apply-WIMImage -WimPath '\\serveur\images\Win11Pro.wim' -Index 1 -TargetPath 'W:\'
    .OUTPUTS
        [PSCustomObject] avec TargetPath, Duration, WimPath, Index
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$WimPath,
        [int]$Index        = 1,
        [Parameter(Mandatory)]
        [string]$TargetPath,
        [switch]$Verify,
        [string]$ScratchDir
    )

    Write-WimLog "=== Application WIM ===" -Level STEP
    Write-WimLog "Source  : $WimPath [Index $Index]" -Level INFO
    Write-WimLog "Cible   : $TargetPath" -Level INFO

    # Verifications prealables
    if (-not (Test-Path $WimPath)) {
        throw "Fichier WIM introuvable : $WimPath"
    }
    if (-not (Test-Path $TargetPath)) {
        throw "Partition cible introuvable : $TargetPath`nVerifiez que le disque est partitionne et formate."
    }

    # Validation de l'index
    $wimInfos = @(Get-WIMInfo -WimPath $WimPath)
    $imageInfo = @($wimInfos | Where-Object { $_.Index -eq $Index }) | Select-Object -First 1
    if (-not $imageInfo) {
        throw "Index $Index introuvable dans $WimPath. Indices disponibles : $(@($wimInfos).Index -join ', ')"
    }
    Write-WimLog "Image selectionnee : $($imageInfo.Name)" -Level INFO

    $dismArgs = @(
        '/Apply-Image',
        "/ImageFile:$WimPath",
        "/Index:$Index",
        "/ApplyDir:$TargetPath"
    )
    # /CheckIntegrity comme PSD (Expand-WindowsImage -CheckIntegrity) : detecte
    # une corruption du WIM pendant l'application plutot qu'au boot.
    if ($Verify)     { $dismArgs += @('/Verify', '/CheckIntegrity') }
    if ($ScratchDir) { $dismArgs += "/ScratchDir:$ScratchDir" }

    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    Invoke-DISMCommand $dismArgs -ShowProgress -Activity "Application de $($imageInfo.Name)"
    $stopwatch.Stop()

    Write-WimLog "Image appliquee en $([Math]::Round($stopwatch.Elapsed.TotalMinutes,1)) min" -Level SUCCESS

    return [PSCustomObject]@{
        TargetPath = $TargetPath
        WimPath    = $WimPath
        Index      = $Index
        ImageName  = $imageInfo.Name
        Duration   = $stopwatch.Elapsed
    }
}

# -----------------------------------------------------------------------------
# FONCTION 6 : EXPORTER / OPTIMISER UN WIM
# -----------------------------------------------------------------------------

function Export-WIMImage {
    <#
    .SYNOPSIS
        Exporte un index WIM vers un nouveau fichier (optimisation, conversion ESD).
    .DESCRIPTION
        Permet de :
        - Extraire un seul index d'un WIM multi-index
        - Recompresser un WIM (reduire la taille)
        - Convertir WIM -> ESD (compression maximale, lecture seule)
        - Convertir ESD -> WIM (pour modification)
    .PARAMETER SourceWimPath
        Fichier WIM source.
    .PARAMETER SourceIndex
        Index a exporter.
    .PARAMETER DestWimPath
        Fichier WIM de destination.
    .PARAMETER CompressionType
        None | Fast | Maximum | Recovery (Recovery = format ESD).
    .PARAMETER CheckIntegrity
        Ajoute des donnees d'integrite dans le WIM exporte.
    .EXAMPLE
        # Extraire l'index 3 (Win11 Pro) d'un install.wim complet
        Export-WIMImage -SourceWimPath 'D:\install.wim' -SourceIndex 3 -DestWimPath 'D:\Win11Pro.wim'
    .EXAMPLE
        # Recompresser au maximum
        Export-WIMImage -SourceWimPath 'D:\Win11Pro.wim' -SourceIndex 1 `
            -DestWimPath 'D:\Win11Pro_compressed.wim' -CompressionType Maximum
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateScript({ Test-Path $_ })]
        [string]$SourceWimPath,
        [int]$SourceIndex    = 1,
        [Parameter(Mandatory)]
        [string]$DestWimPath,
        [ValidateSet('None','Fast','Maximum','Recovery')]
        [string]$CompressionType = 'Maximum',
        [switch]$CheckIntegrity
    )

    Write-WimLog "=== Export WIM ===" -Level STEP
    Write-WimLog "Source : $SourceWimPath [Index $SourceIndex]" -Level INFO
    Write-WimLog "Dest   : $DestWimPath" -Level INFO

    $destDir = Split-Path $DestWimPath -Parent
    if (-not (Test-Path $destDir)) {
        New-Item -ItemType Directory -Path $destDir -Force | Out-Null
    }

    $dismArgs = @(
        '/Export-Image',
        "/SourceImageFile:$SourceWimPath",
        "/SourceIndex:$SourceIndex",
        "/DestinationImageFile:$DestWimPath",
        "/Compress:$($CompressionType.ToLower())"
    )
    if ($CheckIntegrity) { $dismArgs += '/CheckIntegrity' }

    $sizeBefore = (Get-Item $SourceWimPath).Length
    $stopwatch  = [System.Diagnostics.Stopwatch]::StartNew()
    Invoke-DISMCommand $dismArgs
    $stopwatch.Stop()

    $sizeAfter = (Get-Item $DestWimPath).Length
    $ratio     = [Math]::Round((1 - $sizeAfter/$sizeBefore) * 100, 1)

    Write-WimLog "Export termine en $([Math]::Round($stopwatch.Elapsed.TotalMinutes,1)) min" -Level SUCCESS
    Write-WimLog "Avant : $(Format-FileSize $sizeBefore)  ->  Apres : $(Format-FileSize $sizeAfter)  ($ratio% de reduction)" -Level SUCCESS
}

# -----------------------------------------------------------------------------
# FONCTION 7 : PREPARER UN DISQUE (UEFI / BIOS)
# -----------------------------------------------------------------------------

function Initialize-DeployDisk {
    <#
    .SYNOPSIS
        Partitionne et formate un disque pour recevoir Windows (UEFI ou BIOS).
    .DESCRIPTION
        Cree le schema de partitionnement standard Microsoft :
        - UEFI (GPT) : EFI (100MB FAT32) + MSR (16MB) + Windows (reste NTFS) + Recovery (500MB)
        - BIOS (MBR) : System (350MB NTFS Active) + Windows (reste NTFS)
        A utiliser depuis WinPE avant Apply-WIMImage.
    .PARAMETER DiskNumber
        Numero du disque cible (Get-Disk pour lister).
    .PARAMETER FirmwareType
        UEFI (GPT) ou BIOS (MBR). Defaut : UEFI.
    .PARAMETER WindowsDriveLetter
        Lettre a assigner a la partition Windows (defaut : W).
    .PARAMETER RecoveryDriveLetter
        Lettre a assigner a la partition Recovery (defaut : R, UEFI seulement).
    .PARAMETER Force
        Efface le disque sans confirmation.
    .EXAMPLE
        Initialize-DeployDisk -DiskNumber 0 -FirmwareType UEFI -Force
    .OUTPUTS
        [PSCustomObject] avec WindowsDrive, EFIDrive, RecoveryDrive
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)]
        [int]$DiskNumber,
        [ValidateSet('UEFI','BIOS')]
        [string]$FirmwareType      = 'UEFI',
        [string]$WindowsDriveLetter = 'W',
        [string]$RecoveryDriveLetter = 'R',
        [switch]$Force
    )

    Write-WimLog "=== Initialisation du disque $DiskNumber ($FirmwareType) ===" -Level STEP

    # Verification que le disque existe
    $disk = Get-Disk -Number $DiskNumber -ErrorAction SilentlyContinue
    if (-not $disk) {
        throw "Disque $DiskNumber introuvable. Disques disponibles :`n$(Get-Disk | Format-Table -AutoSize | Out-String)"
    }

    Write-WimLog "Disque : $($disk.FriendlyName) -- $(Format-FileSize $disk.Size)" -Level INFO

    if (-not $Force) {
        $confirm = Read-Host "ATTENTION : Le disque $DiskNumber va etre ENTIEREMENT EFFACE. Confirmer ? (oui/non)"
        if ($confirm -ne 'oui') { throw "Operation annulee par l'utilisateur." }
    }

    # =====================================================================
    # NETTOYAGE ROBUSTE (methode MDT/PSD Clear-PSDDisk)
    # Indispensable en PRODUCTION : les machines cibles ont deja un Windows
    # installe avec une ESP 'System' + partitions OEM/Recovery PROTEGEES.
    # Un simple 'diskpart clean' ne retire PAS ces partitions protegees, ce
    # qui empeche la re-creation/montage de l'ESP -> bcdboot erreur 123.
    # Clear-Disk -RemoveData -RemoveOEM supprime TOUT, y compris l'OEM/systeme.
    # =====================================================================
    try {
        $existing = Get-Disk -Number $DiskNumber -EA Stop
        if ($existing.PartitionStyle -ne 'RAW') {
            Write-WimLog "Nettoyage complet du disque (Clear-Disk -RemoveData -RemoveOEM)" -Level INFO
            Clear-Disk -Number $DiskNumber -RemoveData -RemoveOEM -Confirm:$false -EA Stop
            Write-WimLog "Disk cleaned (OEM/system partitions included)" -Level SUCCESS
        } else {
            Write-WimLog "Disk already blank (RAW)" -Level INFO
        }
    } catch {
        # Fallback : diskpart clean classique si Clear-Disk indisponible/echoue
        Write-WimLog "Clear-Disk indisponible ou echoue ($_), fallback diskpart clean" -Level WARN
        "select disk $DiskNumber`r`nclean`r`nexit" | diskpart 2>&1 | Out-Null
    }
    Start-Sleep -Seconds 2

    # Script diskpart selon le mode firmware
    if ($FirmwareType -eq 'UEFI') {
        $diskpartScript = @"
select disk $DiskNumber
clean
convert gpt
rem == Partition systeme EFI (ESP) : 499 MB FAT32 (aligne sur PSD/MDT) ==
create partition efi size=499
format quick fs=fat32 label="System"
assign letter=S
rem == Partition reservee Microsoft (MSR) : 128 MB (aligne sur PSD/MDT) ==
create partition msr size=128
rem == Partition Windows : tout l'espace sauf la Recovery (1024 MB a la fin) ==
create partition primary
shrink minimum=1024
format quick fs=ntfs label="Windows"
assign letter=$WindowsDriveLetter
rem == Partition Recovery (WinRE) : reste de l'espace, juste apres Windows ==
create partition primary
format quick fs=ntfs label="Recovery"
assign letter=$RecoveryDriveLetter
set id="de94bba4-06d1-4d40-a16a-bfd50179d6ac"
gpt attributes=0x8000000000000001
list volume
exit
"@
    } else {
        # BIOS MBR
        $diskpartScript = @"
select disk $DiskNumber
clean
convert mbr
create partition primary size=350
format quick fs=ntfs label=System
assign letter=S
active
create partition primary
format quick fs=ntfs label=Windows
assign letter=$WindowsDriveLetter
list volume
exit
"@
    }

    # Execution diskpart
    $diskpartFile = Join-Path $env:TEMP "diskpart_$(Get-Date -Format 'yyyyMMddHHmmss').txt"
    $diskpartScript | Out-File $diskpartFile -Encoding ASCII

    Write-WimLog "Execution diskpart..." -Level INFO
    $result = & diskpart.exe /s $diskpartFile 2>&1
    $result | ForEach-Object { Write-Host "  $_" -ForegroundColor DarkGray }
    Remove-Item $diskpartFile -Force -ErrorAction SilentlyContinue

    if ($LASTEXITCODE -ne 0) {
        throw "diskpart a echoue (code $LASTEXITCODE)"
    }

    Write-WimLog "Disk initialized successfully" -Level SUCCESS

    $result = [PSCustomObject]@{
        WindowsDrive  = "${WindowsDriveLetter}:"
        SystemDrive   = 'S:'
        RecoveryDrive = if ($FirmwareType -eq 'UEFI') { "${RecoveryDriveLetter}:" } else { $null }
        FirmwareType  = $FirmwareType
    }

    Write-WimLog "Windows    : $($result.WindowsDrive)" -Level INFO
    Write-WimLog "Systeme    : $($result.SystemDrive)" -Level INFO
    if ($result.RecoveryDrive) { Write-WimLog "Recovery   : $($result.RecoveryDrive)" -Level INFO }

    return $result
}

# -----------------------------------------------------------------------------
# FONCTION 8 : CONFIGURER LE BOOTLOADER
# -----------------------------------------------------------------------------

function Set-WindowsBootloader {
    <#
    .SYNOPSIS
        Configure le bootloader Windows apres application du WIM.
    .DESCRIPTION
        Execute bcdboot.exe pour creer les entrees de demarrage.
        A appeler apres Apply-WIMImage et avant le redemarrage.
    .PARAMETER WindowsDrive
        Lettre de lecteur de la partition Windows (ex: 'W:').
    .PARAMETER SystemDrive
        Lettre de lecteur de la partition EFI/System (ex: 'S:').
    .PARAMETER FirmwareType
        UEFI ou BIOS.
    .PARAMETER Locale
        Locale du bootloader (defaut : fr-FR).
    .EXAMPLE
        Set-WindowsBootloader -WindowsDrive 'W:' -SystemDrive 'S:' -FirmwareType UEFI
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$WindowsDrive,
        [Parameter(Mandatory)]
        [string]$SystemDrive,
        [ValidateSet('UEFI','BIOS')]
        [string]$FirmwareType = 'UEFI',
        [string]$Locale       = 'fr-FR',
        [string]$RecoveryDrive = 'R:',
        [switch]$ConfigureWinRE   # WinRE/reagentc DESACTIVE par defaut (suspect BSOD)
    )

    Write-WimLog "=== Configuration du bootloader ===" -Level STEP

    # Utiliser le bcdboot de WinPE (comme le test qui boote), PAS celui de
    # l'image appliquee. En contexte WinPE c'est plus fiable (le bcdboot de
    # l'image peut dependre de DLL/contexte absents -> BCD instable -> BSOD).
    $bcdbootPath = 'bcdboot.exe'

    $firmFlag = if ($FirmwareType -eq 'UEFI') { 'UEFI' } else { 'BIOS' }

    # Arguments separes (PowerShell passe chaque element comme arg distinct a bcdboot)
    # Le flag /c (PSD v0.1.5) force la creation propre du BCD sans fusion avec
    # un store existant -- corrige les problemes de boot UEFI (CRITICAL_PROCESS_DIED).
    $sysDrive = $SystemDrive.TrimEnd('\')
    # PSD n'utilise PAS /l (locale) sur bcdboot : evite les problemes si les ressources
    # de langue ne sont pas presentes. Le /c force un BCD propre (fix UEFI boot PSD v0.1.5).
    if ($FirmwareType -eq 'UEFI') {
        $bcdArgs = @("$WindowsDrive\Windows", '/s', $sysDrive, '/f', 'UEFI', '/c')
    } else {
        $bcdArgs = @("$WindowsDrive\Windows", '/s', $sysDrive, '/c')
    }
    # Verifier que la partition systeme (ESP) est bien accessible AVANT bcdboot.
    # Sinon bcdboot renvoie 123 (ERROR_INVALID_NAME) et l'OS ne demarre pas.
    $sysCheck = $sysDrive.TrimEnd('\') + '\'
    if ($FirmwareType -eq 'UEFI' -and -not (Test-Path $sysCheck -EA SilentlyContinue)) {
        throw "Partition systeme EFI $sysDrive inaccessible avant bcdboot -- le partitionnement a echoue ou l'ESP n'a pas recu de lettre. Verifier le disque cible."
    }
    Write-WimLog "bcdboot.exe $($bcdArgs -join ' ')" -Level INFO

    $result = & $bcdbootPath @bcdArgs 2>&1
    # Detecter un echec textuel (bcdboot ne retourne pas toujours un exit code non-zero)
    $bcdFailed = $false
    $result | ForEach-Object {
        $line = "$_"
        Write-Host "  $line" -ForegroundColor DarkGray
        if ($line -match 'Failure|Echec|impossible|Error|Erreur') { $bcdFailed = $true }
    }

    if ($LASTEXITCODE -ne 0 -or $bcdFailed) {
        throw "bcdboot a echoue (code $LASTEXITCODE) -- partition de boot $SystemDrive non preparee"
    }

    # Laisser le temps au systeme de fichiers de se synchroniser (PSD : Start-Sleep 15)
    Start-Sleep -Seconds 5

    if ($FirmwareType -eq 'UEFI') {
        # Re-flaguer la partition EFI avec le type GPT 'System' (etape PSD Set-PSDEFIDiskpartition)
        # Corrige les cas ou la partition n'est pas reconnue comme ESP au boot.
        try {
            $efiFlip = @"
select volume $sysDrive
set id=c12a7328-f81f-11d2-ba4b-00a0c93ec93b
exit
"@
            $efiFlip | diskpart 2>&1 | Out-Null
            Write-WimLog "Type partition EFI confirme (c12a7328... System)" -Level INFO
        } catch {
            Write-WimLog "Flip type EFI : $_ (non bloquant)" -Level WARN
        }
    }

    # Rafraichir les entrees BCD (etape PSD finale, necessaire sur certains hardware)
    try {
        & bcdedit.exe 2>&1 | Out-Null
        Write-WimLog "BCD rafraichi" -Level INFO
    } catch {}

    Write-WimLog "Bootloader configure ($FirmwareType)" -Level SUCCESS

    # -- Configuration de Windows RE --
    # DESACTIVE par defaut : reagentc /Setreimage sur image offline est un suspect
    # de corruption de boot (BSOD). WinRE n'est PAS requis pour booter Windows.
    # Si besoin, le configurer en PHASE 2 (Windows demarre) via reagentc /enable.
    if ($ConfigureWinRE -and $FirmwareType -eq 'UEFI' -and $RecoveryDrive) {
        try {
            $winreSource = Join-Path $WindowsDrive 'Windows\System32\Recovery\Winre.wim'
            $recDrive    = $RecoveryDrive.TrimEnd('\').TrimEnd(':') + ':'
            if (Test-Path $winreSource -EA SilentlyContinue) {
                $recDir = Join-Path $recDrive 'Recovery\WindowsRE'
                if (-not (Test-Path $recDir -EA SilentlyContinue)) { New-Item -ItemType Directory $recDir -Force | Out-Null }
                Copy-Item $winreSource (Join-Path $recDir 'Winre.wim') -Force -EA Stop
                Write-WimLog "Winre.wim copie vers $recDir" -Level INFO

                # Enregistrer l'emplacement de WinRE (reagentc sur l'image offline)
                $reagentc = Join-Path $WindowsDrive 'Windows\System32\Reagentc.exe'
                if (Test-Path $reagentc -EA SilentlyContinue) {
                    $winDir = $WindowsDrive.TrimEnd('\').TrimEnd(':') + ':\Windows'
                    $rcOut = & $reagentc /Setreimage /Path "$recDir" /Target $winDir 2>&1
                    Write-WimLog "reagentc /setreimage : $rcOut" -Level INFO
                }
            } else {
                Write-WimLog "Winre.wim not found in the image -- WinRE not configured (non-blocking)" -Level WARN
            }
        } catch {
            Write-WimLog "Configuration WinRE echouee : $_ (non bloquant)" -Level WARN
        }
    }
}

# -----------------------------------------------------------------------------
# FONCTION 9 : PIPELINE DEPLOIEMENT COMPLET
# -----------------------------------------------------------------------------

function Invoke-WIMDeploy {
    <#
    .SYNOPSIS
        Pipeline complet : partitionne, applique le WIM, configure le boot.
    .DESCRIPTION
        Orchestre Initialize-DeployDisk + Apply-WIMImage + Set-WindowsBootloader.
        C'est la sequence minimale pour deployer Windows depuis WinPE.
        Appelee par Start-Deploy.ps1 (etape 3).
    .PARAMETER WimPath
        Chemin vers le fichier .wim a deployer.
    .PARAMETER WimIndex
        Index de l'image dans le WIM.
    .PARAMETER DiskNumber
        Numero du disque cible.
    .PARAMETER FirmwareType
        UEFI (GPT) ou BIOS (MBR).
    .PARAMETER Locale
        Locale du bootloader.
    .PARAMETER Force
        Efface le disque sans confirmation.
    .EXAMPLE
        # Deploiement depuis WinPE
        Invoke-WIMDeploy -WimPath '\\srv\images\Win11Pro.wim' -DiskNumber 0 -Force
    .OUTPUTS
        [PSCustomObject] avec les resultats de chaque etape
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$WimPath,
        [int]$WimIndex         = 1,
        [Parameter(Mandatory)]
        [int]$DiskNumber,
        [ValidateSet('UEFI','BIOS')]
        [string]$FirmwareType  = 'UEFI',
        [string]$Locale        = 'fr-FR',
        [switch]$Force
    )

    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    Write-WimLog "+==========================================+" -Level STEP
    Write-WimLog "|   WIM-MANAGER -- Deployment pipeline       |" -Level STEP
    Write-WimLog "+==========================================+" -Level STEP

    try {
        # 1. Partitionnement
        $diskResult = Initialize-DeployDisk -DiskNumber $DiskNumber -FirmwareType $FirmwareType -Force:$Force

        # 2. Application du WIM
        $applyResult = Apply-WIMImage -WimPath $WimPath -Index $WimIndex -TargetPath $diskResult.WindowsDrive -Verify

        # 3. Bootloader
        Set-WindowsBootloader -WindowsDrive $diskResult.WindowsDrive -SystemDrive $diskResult.SystemDrive -FirmwareType $FirmwareType -Locale $Locale

        $stopwatch.Stop()
        Write-WimLog "==========================================" -Level SUCCESS
        Write-WimLog "Deploiement termine en $([Math]::Round($stopwatch.Elapsed.TotalMinutes,1)) min" -Level SUCCESS
        Write-WimLog "Windows installe sur $($diskResult.WindowsDrive)" -Level SUCCESS
        Write-WimLog "==========================================" -Level SUCCESS

        return [PSCustomObject]@{
            Success      = $true
            WindowsDrive = $diskResult.WindowsDrive
            WimPath      = $WimPath
            WimIndex     = $WimIndex
            Duration     = $stopwatch.Elapsed
        }

    } catch {
        Write-WimLog "ERREUR deploiement : $_" -Level ERROR
        throw
    }
}

# -----------------------------------------------------------------------------
# EXPORTS
# -----------------------------------------------------------------------------

Export-ModuleMember -Function @(
    'Get-WIMInfo'
    'New-WIMCapture'
    'Mount-WIMImage'
    'Save-WIMImage'
    'Repair-WIMMountCleanup'
    'Apply-WIMImage'
    'Export-WIMImage'
    'Initialize-DeployDisk'
    'Set-WindowsBootloader'
    'Invoke-WIMDeploy'
)
