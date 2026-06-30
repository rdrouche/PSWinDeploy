#Requires -RunAsAdministrator
<#
.SYNOPSIS
    DiskSelector.psm1 -- Assistant interactif de selection de disque
.DESCRIPTION
    Affiche une representation visuelle ASCII des disques disponibles
    et guide l'utilisateur dans le choix du disque cible et de l'image WIM.
    Concu pour fonctionner dans la console WinPE (pas d'interface graphique).
.NOTES
    Usage : depuis WinPE ou Windows, appele par TaskSequence.psm1
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# -----------------------------------------------------------------------------
# UTILITAIRES VISUELS CONSOLE
# -----------------------------------------------------------------------------

function Write-ConsoleLine {
    param([string]$Text = '', [ConsoleColor]$Color = 'White', [switch]$NoNewline)
    if ($NoNewline) { Write-Host $Text -ForegroundColor $Color -NoNewline }
    else            { Write-Host $Text -ForegroundColor $Color }
}

function Write-ConsoleBox {
    <#Dessine un encadre ASCII autour d'un titre#>
    param([string]$Title, [int]$Width = 60, [ConsoleColor]$Color = 'Cyan')
    $line = '-' * ($Width - 2)
    Write-ConsoleLine "+$line+" -Color $Color
    $pad  = ' ' * [Math]::Max(0, [Math]::Floor(($Width - 2 - $Title.Length) / 2))
    $padR = ' ' * [Math]::Max(0, $Width - 2 - $Title.Length - $pad.Length)
    Write-ConsoleLine "|$pad$Title$padR|" -Color $Color
    Write-ConsoleLine "+$line+" -Color $Color
}

function Format-DiskSize {
    param([long]$Bytes)
    if ($Bytes -gt 1TB) { return "{0:N1} TB" -f ($Bytes/1TB) }
    if ($Bytes -gt 1GB) { return "{0:N0} GB" -f ($Bytes/1GB) }
    return "{0:N0} MB" -f ($Bytes/1MB)
}

function Format-DiskBar {
    <#Genere une barre de progression ASCII representant l'utilisation du disque#>
    param(
        [long]$TotalBytes,
        [long]$UsedBytes  = 0,
        [int]$Width       = 30
    )
    $ratio = if ($TotalBytes -gt 0) { [Math]::Min(1.0, $UsedBytes / $TotalBytes) } else { 0 }
    $filled = [Math]::Round($ratio * $Width)
    $empty  = $Width - $filled

    $bar    = '#' * $filled + '.' * $empty
    $pct    = "{0:N0}%" -f ($ratio * 100)
    return "[$bar] $pct"
}

function Get-DiskHealthIcon {
    param([string]$OperationalStatus, [string]$PartitionStyle)
    $health = switch ($OperationalStatus) {
        'Online'  { '[OK]' }
        'Offline' { '[OFF]' }
        default   { '[??]' }
    }
    $style = switch ($PartitionStyle) {
        'GPT' { 'GPT' }
        'MBR' { 'MBR' }
        'RAW' { 'RAW' }
        default { '---' }
    }
    return "$health $style"
}

# -----------------------------------------------------------------------------
# AFFICHAGE DES DISQUES
# -----------------------------------------------------------------------------

function Show-DiskMap {
    <#
    .SYNOPSIS
        Affiche la carte visuelle de tous les disques et leurs partitions.
    .DESCRIPTION
        Pour chaque disque physique, affiche :
        - Numero, modele, taille, statut, style de partition
        - Barre de capacite
        - Liste des partitions avec type, lettre, taille, label
    .OUTPUTS [PSCustomObject[]] liste des disques avec leurs infos
    #>
    [CmdletBinding()]
    param([switch]$Quiet)

    $disks = @(Get-Disk | Sort-Object Number)
    if (@($disks).Count -eq 0) { throw "No disk detected!" }

    if (-not $Quiet) {
        Clear-Host
        Write-ConsoleBox -Title " PSWinDeploy -- Selection du disque cible " -Width 68 -Color Cyan
        Write-ConsoleLine ""
    }

    $diskInfos = @()

    foreach ($disk in $disks) {
        # Calcul espace utilise par les partitions
        $partitions = @(Get-Partition -DiskNumber $disk.Number -ErrorAction SilentlyContinue 2>$null)
        $measureResult = $partitions | Measure-Object -Property Size -Sum -ErrorAction SilentlyContinue
        $usedBytes = if ($measureResult -and $null -ne $measureResult.Sum) { $measureResult.Sum } else { 0 }

        $healthIcon    = Get-DiskHealthIcon -OperationalStatus $disk.OperationalStatus -PartitionStyle $disk.PartitionStyle
        $sizeStr       = Format-DiskSize $(if($null -ne $disk.Size){$disk.Size}else{0})
        $bar           = Format-DiskBar -TotalBytes $(if($null -ne $disk.Size){[long]$disk.Size}else{0}) -UsedBytes $usedBytes -Width 28
        $isSystem      = (@($partitions | Where-Object { $_.IsSystem -or $_.IsBoot }).Count -gt 0)
        $systemWarn    = if ($isSystem) { ' [SYSTEME ACTUEL]' } else { '' }
        $bootable      = if ($disk.IsBoot) { ' [BOOT]' } else { '' }

        $diskInfo = [PSCustomObject]@{
            Number        = $disk.Number
            FriendlyName  = $disk.FriendlyName
            Size          = $disk.Size
            SizeStr       = $sizeStr
            PartitionStyle = $disk.PartitionStyle
            OperationalStatus = $disk.OperationalStatus
            IsSystem      = $isSystem
            IsBoot        = $disk.IsBoot
            Partitions    = $partitions
            UsedBytes     = $usedBytes
        }
        $diskInfos += $diskInfo

        if (-not $Quiet) {
            # Ligne principale du disque
            $diskColor = if ($isSystem) { 'Yellow' } else { 'White' }
            Write-ConsoleLine "  +- Disque $($disk.Number) ---------------------------------------------" -Color DarkGray
            Write-ConsoleLine "  |  " -Color DarkGray -NoNewline
            Write-ConsoleLine "$($disk.Number) " -Color Cyan -NoNewline
            Write-ConsoleLine "$($disk.FriendlyName)" -Color $diskColor -NoNewline
            Write-ConsoleLine "$systemWarn$bootable" -Color Yellow
            Write-ConsoleLine "  |  " -Color DarkGray -NoNewline
            Write-ConsoleLine "     Taille   : $sizeStr" -Color Gray
            Write-ConsoleLine "  |  " -Color DarkGray -NoNewline
            Write-ConsoleLine "     Statut   : $healthIcon" -Color $(if ($disk.OperationalStatus -eq 'Online') { 'Green' } else { 'Red' })
            Write-ConsoleLine "  |  " -Color DarkGray -NoNewline
            Write-ConsoleLine "     Capacite : $bar" -Color DarkCyan

            # Partitions
            if ($partitions -and @($partitions).Count -gt 0) {
                Write-ConsoleLine "  |" -Color DarkGray
                Write-ConsoleLine "  |  Partitions :" -Color DarkGray

                foreach ($part in ($partitions | Sort-Object PartitionNumber)) {
                    # Recuperation volume associe
                    $vol = try { Get-Volume -Partition $part -ErrorAction SilentlyContinue } catch { $null } { $null }

                    $letter  = if ($part.DriveLetter -and $part.DriveLetter -ne "`0") {
                                   "$($part.DriveLetter):"
                               } else { '  ' }
                    $partSize = Format-DiskSize $(if($null -ne $part.Size){$part.Size}else{0})
                    $label   = if ($vol -and $vol.FileSystemLabel) { $vol.FileSystemLabel } else { '' }
                    $fs      = if ($vol -and $vol.FileSystem)      { $vol.FileSystem }      else { '---' }
                    $typeStr = switch ($part.Type) {
                        'System'      { '[EFI ]' }
                        'Reserved'    { '[MSR ]' }
                        'Recovery'    { '[REC ]' }
                        'Basic'       { '[DATA]' }
                        'IFS'         { '[NTFS]' }
                        default       { "[    ]" }
                    }

                    $partColor = switch -Regex ($part.Type) {
                        'System'   { 'DarkYellow' }
                        'Recovery' { 'DarkMagenta' }
                        default    { 'Gray' }
                    }

                    Write-ConsoleLine "  |     " -Color DarkGray -NoNewline
                    Write-ConsoleLine "$typeStr " -Color $partColor -NoNewline
                    Write-ConsoleLine "P$($part.PartitionNumber) " -Color DarkGray -NoNewline
                    Write-ConsoleLine "$letter " -Color $(if ($letter.Trim()) { 'White' } else { 'DarkGray' }) -NoNewline
                    Write-ConsoleLine "$partSize " -Color DarkCyan -NoNewline
                    Write-ConsoleLine "$fs " -Color DarkGray -NoNewline
                    Write-ConsoleLine "$label" -Color Gray
                }
            } else {
                Write-ConsoleLine "  |  " -Color DarkGray -NoNewline
                Write-ConsoleLine "     (non partitionne / RAW)" -Color DarkGray
            }

            Write-ConsoleLine "  +----------------------------------------------------------" -Color DarkGray
            Write-ConsoleLine ""
        }
    }

    return $diskInfos
}

# -----------------------------------------------------------------------------
# SELECTION INTERACTIVE DU DISQUE
# -----------------------------------------------------------------------------

function Invoke-DiskSelector {
    <#
    .SYNOPSIS
        Interface interactive pour choisir le disque cible du deploiement.
    .DESCRIPTION
        Affiche la carte des disques, propose une liste de choix,
        demande confirmation et retourne le numero du disque selectionne.
        Si un seul disque est disponible et non-systeme, le selectionne automatiquement.
    .PARAMETER AllowSystemDisk
        Autorise la selection du disque systeme actuel (dangereux -- a confirmer).
    .PARAMETER AutoSelectIfSingle
        Selectionne automatiquement si un seul disque non-systeme est disponible.
    .OUTPUTS [int] Numero du disque selectionne
    #>
    [CmdletBinding()]
    param(
        [switch]$AllowSystemDisk,
        [switch]$AutoSelectIfSingle
    )

    $diskInfos = Show-DiskMap

    # Filtrage des disques selectionnables
    $selectable = $diskInfos | Where-Object {
        $_.OperationalStatus -eq 'Online' -and
        (-not $_.IsSystem -or $AllowSystemDisk)
    }

    if (@($selectable).Count -eq 0) {
        throw "No selectable disk available.`nAll disks are system or offline."
    }

    # Auto-selection si un seul disque disponible
    if ($AutoSelectIfSingle -and @($selectable).Count -eq 1) {
        $auto = $selectable[0]
        Write-ConsoleLine ""
        Write-ConsoleLine "  [AUTO] Un seul disque disponible : Disque $($auto.Number) ($($auto.FriendlyName))" -Color Green
        return $auto.Number
    }

    # -- Prompt de selection --
    Write-ConsoleLine "  Disks available for deployment:" -Color Cyan
    Write-ConsoleLine ""

    foreach ($d in $selectable) {
        $warn = if ($d.IsSystem) { ' [ATTENTION : disque systeme !]' } else { '' }
        Write-ConsoleLine "    " -NoNewline
        Write-ConsoleLine "[$($d.Number)]" -Color Yellow -NoNewline
        Write-ConsoleLine " Disque $($d.Number) -- $($d.FriendlyName) -- $($d.SizeStr)$warn" -Color White
    }

    Write-ConsoleLine ""
    $validNums = $selectable.Number

    $choice = $null
    while ($null -eq $choice) {
        Write-ConsoleLine "  Enter the target disk number" -Color Cyan -NoNewline
        Write-ConsoleLine " [$($validNums -join '/')] " -Color Yellow -NoNewline
        $input = (Read-Host).Trim()

        if ($input -match '^\d+$' -and [int]$input -in $validNums) {
            $choice = [int]$input
        } else {
            Write-ConsoleLine "  Choix invalide. Entrez l'un des numeros proposes." -Color Red
        }
    }

    $selected = $selectable | Where-Object { $_.Number -eq $choice }

    # -- Confirmation --
    Write-ConsoleLine ""
    Write-ConsoleLine "  +-------------------------------------------------+" -Color Yellow
    Write-ConsoleLine "  |  ATTENTION -- Le disque selectionne sera EFFACE  |" -Color Yellow
    Write-ConsoleLine "  +-------------------------------------------------+" -Color Yellow
    Write-ConsoleLine "  |  Disque : $($selected.Number) -- $($selected.FriendlyName)" -Color Yellow
    Write-ConsoleLine "  |  Taille : $($selected.SizeStr)" -Color Yellow
    if ($selected.IsSystem) {
        Write-ConsoleLine "  |  /!\ SYSTEM DISK -- All data will be lost!" -Color Red
    }
    Write-ConsoleLine "  +-------------------------------------------------+" -Color Yellow
    Write-ConsoleLine ""

    $confirm = $null
    while ($confirm -notin @('oui','non','o','n')) {
        Write-ConsoleLine "  Confirmer l'effacement du Disque $($selected.Number) ? " -Color Yellow -NoNewline
        Write-ConsoleLine "[oui/non] " -Color Cyan -NoNewline
        $confirm = (Read-Host).Trim().ToLower()
    }

    if ($confirm -in @('non','n')) {
        Write-ConsoleLine ""
        Write-ConsoleLine "  Selection annulee. Relancement de la selection..." -Color Yellow
        Start-Sleep 2
        return Invoke-DiskSelector -AllowSystemDisk:$AllowSystemDisk -AutoSelectIfSingle:$AutoSelectIfSingle
    }

    Write-ConsoleLine ""
    Write-ConsoleLine "  Disque $($selected.Number) selectionne et confirme." -Color Green
    Write-ConsoleLine ""

    return $selected.Number
}

# -----------------------------------------------------------------------------
# SELECTION INTERACTIVE DE L'IMAGE WIM
# -----------------------------------------------------------------------------

function Invoke-WIMIndexSelector {
    <#
    .SYNOPSIS
        Interface interactive pour choisir l'index WIM a deployer.
    .DESCRIPTION
        Affiche les images disponibles dans un fichier WIM avec leurs infos
        (nom, edition, langue, taille) et guide le choix.
    .PARAMETER WimPath
        Chemin vers le fichier .wim ou .esd.
    .OUTPUTS [int] Index de l'image selectionnee
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$WimPath
    )

    if (-not (Test-Path $WimPath)) {
        throw "Fichier WIM introuvable : $WimPath"
    }

    Clear-Host
    Write-ConsoleBox -Title " PSWinDeploy -- Selection de l'image Windows " -Width 68 -Color Magenta
    Write-ConsoleLine ""
    Write-ConsoleLine "  Fichier : $WimPath" -Color Gray
    $wimSize = [System.IO.FileInfo]::new($WimPath).Length
    Write-ConsoleLine "  Taille  : $(Format-DiskSize $wimSize)" -Color Gray
    Write-ConsoleLine ""

    # Recuperation des index via DISM
    Write-ConsoleLine "  Reading available images..." -Color DarkGray
    $output = & dism.exe /Get-WimInfo /WimFile:"$WimPath" 2>&1
    if ($LASTEXITCODE -ne 0) { throw "Impossible de lire le WIM : $WimPath" }

    # Parsing
    $images  = @()
    $current = $null
    foreach ($line in $output) {
        $line = $line.Trim()
        if ($line -match '^Index\s*:\s*(\d+)') {
            if ($current) { $images += $current }
            $current = [PSCustomObject]@{
                Index       = [int]$Matches[1]
                Name        = ''
                Description = ''
                Size        = ''
                Edition     = ''
                Language    = ''
                Build       = ''
            }
        }
        if ($current) {
            switch -Regex ($line) {
                '^Name\s*:\s*(.+)'             { $current.Name        = $Matches[1] }
                '^Description\s*:\s*(.+)'      { $current.Description = $Matches[1] }
                '^Size\s*:\s*(.+)'             { $current.Size        = $Matches[1] }
                '^Edition ID\s*:\s*(.+)'       { $current.Edition     = $Matches[1] }
                '^Default Language\s*:\s*(.+)' { $current.Language    = $Matches[1] }
                '^Version\s*:\s*(.+)'          { $current.Build       = $Matches[1] }
            }
        }
    }
    if ($current) { $images += $current }

    if (@($images).Count -eq 0) { throw "Aucune image trouvee dans $WimPath" }

    # Auto-selection si une seule image
    if (@($images).Count -eq 1) {
        Write-ConsoleLine "  [AUTO] Une seule image disponible : $($images[0].Name)" -Color Green
        Write-ConsoleLine ""
        return $images[0].Index
    }

    # Affichage des images
    Write-ConsoleLine "  Images disponibles :" -Color Magenta
    Write-ConsoleLine ""

    foreach ($img in $images) {
        $langStr  = if ($img.Language) { " [$($img.Language)]" } else { '' }
        $buildStr = if ($img.Build)    { " -- Build $($img.Build)" } else { '' }

        Write-ConsoleLine "    " -NoNewline
        Write-ConsoleLine "[$($img.Index)]" -Color Yellow -NoNewline
        Write-ConsoleLine " $($img.Name)$langStr$buildStr" -Color White

        if ($img.Description -and $img.Description -ne $img.Name) {
            Write-ConsoleLine "        $($img.Description)" -Color DarkGray
        }
        if ($img.Size) {
            Write-ConsoleLine "        Taille depliee : $($img.Size)" -Color DarkCyan
        }
        Write-ConsoleLine ""
    }

    $validIdx = $images.Index
    $choice   = $null

    while ($null -eq $choice) {
        Write-ConsoleLine "  Entrez l'index de l'image a deployer" -Color Magenta -NoNewline
        Write-ConsoleLine " [$($validIdx -join '/')] " -Color Yellow -NoNewline
        $input = (Read-Host).Trim()

        if ($input -match '^\d+$' -and [int]$input -in $validIdx) {
            $choice = [int]$input
        } else {
            Write-ConsoleLine "  Index invalide. Choisissez parmi : $($validIdx -join ', ')" -Color Red
        }
    }

    $selected = $images | Where-Object { $_.Index -eq $choice }
    Write-ConsoleLine ""
    Write-ConsoleLine "  Image selectionnee : [$choice] $($selected.Name)" -Color Green
    Write-ConsoleLine ""

    return $choice
}

# -----------------------------------------------------------------------------
# ASSISTANT COMPLET PRE-DEPLOIEMENT
# -----------------------------------------------------------------------------

function Invoke-PreDeployWizard {
    <#
    .SYNOPSIS
        Assistant interactif complet avant deploiement.
    .DESCRIPTION
        Guide l'operateur etape par etape :
        1. Selection du fichier WIM (si plusieurs disponibles)
        2. Selection de l'index WIM
        3. Selection du disque cible
        4. Choix du firmware (UEFI/BIOS) si non detecte
        5. Confirmation recapitulative avant lancement
    .PARAMETER WimSearchPath
        Dossier(s) ou chercher les fichiers .wim disponibles.
    .PARAMETER WimPath
        Chemin direct vers un WIM (skip la recherche).
    .PARAMETER DiskNumber
        Numero de disque pre-selectionne (skip la selection).
    .OUTPUTS [PSCustomObject] @{ WimPath; WimIndex; DiskNumber; FirmwareType }
    #>
    [CmdletBinding()]
    param(
        [string[]]$WimSearchPath = @('\\SERVEUR\Images', 'D:\Images', 'X:\Images'),
        [string]$WimPath,
        [int]$DiskNumber = -1
    )

    Clear-Host
    Write-ConsoleBox -Title " PSWinDeploy -- Assistant de deploiement Windows " -Width 68 -Color Cyan
    Write-ConsoleLine ""
    Write-ConsoleLine "  Bienvenue dans PSWinDeploy, le successeur de MDT." -Color Gray
    Write-ConsoleLine "  This assistant will guide the deployment step by step." -Color Gray
    Write-ConsoleLine ""
    Start-Sleep 1

    # -- Etape 1 : Selection WIM --
    if (-not $WimPath) {
        $availableWims = @()
        foreach ($searchPath in $WimSearchPath) {
            if (Test-Path $searchPath) {
                $availableWims += Get-ChildItem $searchPath -Filter '*.wim' -Recurse -ErrorAction SilentlyContinue
            }
        }

        if (@($availableWims).Count -eq 0) {
            Write-ConsoleLine "  No WIM file found in the configured paths." -Color Red
            Write-ConsoleLine "  Chemin manuel (ex: \\\\serveur\\images\\win11.wim) : " -Color Yellow -NoNewline
            $WimPath = Read-Host
        } elseif (@($availableWims).Count -eq 1) {
            $WimPath = $availableWims[0].FullName
            Write-ConsoleLine "  [AUTO] WIM trouve : $WimPath" -Color Green
        } else {
            Write-ConsoleLine "  Fichiers WIM disponibles :" -Color Cyan
            Write-ConsoleLine ""
            $i = 1
            foreach ($wim in $availableWims) {
                $size = Format-DiskSize $wim.Length
                Write-ConsoleLine "    [$i] $($wim.Name)  ($size)  -- $($wim.DirectoryName)" -Color White
                $i++
            }
            Write-ConsoleLine ""
            $wimChoice = $null
            while ($null -eq $wimChoice) {
                Write-ConsoleLine "  Choisissez le fichier WIM [1-$(@($availableWims).Count)] : " -Color Cyan -NoNewline
                $in = Read-Host
                if ($in -match '^\d+$' -and [int]$in -ge 1 -and [int]$in -le @($availableWims).Count) {
                    $wimChoice = [int]$in - 1
                }
            }
            $WimPath = $availableWims[$wimChoice].FullName
        }
    }

    Write-ConsoleLine ""

    # -- Etape 2 : Selection index WIM --
    $wimIndex = Invoke-WIMIndexSelector -WimPath $WimPath

    # -- Etape 3 : Selection disque --
    if ($DiskNumber -eq -1) {
        $DiskNumber = Invoke-DiskSelector -AutoSelectIfSingle
    }

    # -- Etape 4 : Detection firmware --
    $firmwareType = 'UEFI'
    try {
        $fw = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control' -Name PEFirmwareType -ErrorAction SilentlyContinue).PEFirmwareType
        $firmwareType = if ($fw -eq 1) { 'BIOS' } else { 'UEFI' }
        Write-ConsoleLine "  Firmware detecte : $firmwareType" -Color Green
    } catch {
        # Demande manuelle si la detection echoue
        Write-ConsoleLine ""
        Write-ConsoleLine "  Cannot detect the firmware automatically." -Color Yellow
        Write-ConsoleLine "  Type de firmware " -Color Cyan -NoNewline
        Write-ConsoleLine "[UEFI/BIOS] (defaut: UEFI) : " -Color Yellow -NoNewline
        $fwInput = (Read-Host).Trim().ToUpper()
        if ($fwInput -eq 'BIOS') { $firmwareType = 'BIOS' }
    }

    # -- Recapitulatif final --
    $diskInfos   = Show-DiskMap -Quiet
    $diskInfo    = $diskInfos | Where-Object { $_.Number -eq $DiskNumber }
    $wimFileName = Split-Path $WimPath -Leaf

    Clear-Host
    Write-ConsoleBox -Title " Deployment summary " -Width 68 -Color Green
    Write-ConsoleLine ""
    Write-ConsoleLine "  Image Windows  : $wimFileName [Index $wimIndex]" -Color White
    Write-ConsoleLine "  Source WIM     : $WimPath" -Color Gray
    Write-ConsoleLine "  Disque cible   : Disque $DiskNumber -- $($diskInfo.FriendlyName) ($($diskInfo.SizeStr))" -Color White
    Write-ConsoleLine "  Firmware       : $firmwareType" -Color White
    Write-ConsoleLine ""
    Write-ConsoleLine "  +==================================================+" -Color Red
    Write-ConsoleLine "  |  Le disque $DiskNumber sera ENTIEREMENT EFFACE !          |" -Color Red
    Write-ConsoleLine "  |  All existing data will be LOST.                |" -Color Red
    Write-ConsoleLine "  +==================================================+" -Color Red
    Write-ConsoleLine ""

    $go = $null
    while ($go -notin @('oui','non','o','n')) {
        Write-ConsoleLine "  Start the deployment? " -Color Green -NoNewline
        Write-ConsoleLine "[oui/non] " -Color Yellow -NoNewline
        $go = (Read-Host).Trim().ToLower()
    }

    if ($go -in @('non','n')) {
        Write-ConsoleLine ""
        Write-ConsoleLine "  Deployment cancelled." -Color Yellow
        return $null
    }

    Write-ConsoleLine ""
    Write-ConsoleLine "  Starting deployment..." -Color Green
    Write-ConsoleLine ""
    Start-Sleep 2

    return [PSCustomObject]@{
        WimPath      = $WimPath
        WimIndex     = $wimIndex
        DiskNumber   = $DiskNumber
        FirmwareType = $firmwareType
    }
}


# Aliases pour compatibilite avec Start-Deploy.ps1
function Show-DiskSummary {
    param([switch]$Quiet)
    Show-DiskMap @PSBoundParameters
}

function Select-TargetDisk {
    <#Selectionne le disque cible de facon simple et fiable (compatible WinPE PS 5.1)#>
    $disks = @(Get-Disk | Sort-Object Number)
    if (@($disks).Count -eq 0) { throw "No disk detected" }

    # Afficher la liste
    Write-Host ""
    foreach ($d in $disks) {
        $sizeGB = if ($d.Size) { "$([Math]::Round($d.Size/1GB,0)) GB" } else { "?" }
        $style  = if ($d.PartitionStyle) { $d.PartitionStyle } else { "RAW" }
        $mark   = if ($d.IsBoot) { " [SYSTEME EN COURS]" } else { "" }
        Write-Host ("  Disk {0}  {1,-30} {2,8}  {3}{4}" -f `
            $d.Number, $d.FriendlyName, $sizeGB, $style, $mark) -ForegroundColor White
        # Lister les partitions
        $parts = @(Get-Partition -DiskNumber $d.Number -ErrorAction SilentlyContinue 2>$null)
        foreach ($p in $parts) {
            $ltr = if ($p.DriveLetter -and $p.DriveLetter -ne "`0") { "$($p.DriveLetter):" } else { "  " }
            $psz = if ($p.Size -gt 0) { "$([Math]::Round($p.Size/1MB,0)) MB" } else { "?" }
            $pty = if ($p.Type) { $p.Type } else { "Basic" }
            Write-Host ("         [{0,-5}] P{1}  {2}  {3,8}" -f `
                $pty, $p.PartitionNumber, $ltr, $psz) -ForegroundColor DarkGray
        }
        Write-Host ""
    }

    # Un seul disque non-systeme -> auto
    $nonSys = @($disks | Where-Object { -not $_.IsBoot })
    if (@($nonSys).Count -eq 1) {
        $d = $nonSys[0]
        Write-Host "  Disque $($d.Number) selectionne automatiquement." -ForegroundColor Green
        return $d.Number
    }

    # Prompt
    $valid = @($disks | ForEach-Object { $_.Number })
    while ($true) {
        Write-Host "  [?]  Choisir le disque cible [$($valid -join '/')] : " -ForegroundColor Yellow -NoNewline
        $n = (Read-Host).Trim()
        if ($n -match '^\d+$' -and [int]$n -in $valid) { return [int]$n }
        Write-Host "  Choix invalide." -ForegroundColor Red
    }
}

Export-ModuleMember -Function @(
    'Show-DiskMap'
    'Show-DiskSummary'
    'Select-TargetDisk'
    'Invoke-DiskSelector'
    'Invoke-WIMIndexSelector'
    'Invoke-PreDeployWizard'
)
