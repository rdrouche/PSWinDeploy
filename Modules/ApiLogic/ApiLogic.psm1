# ApiLogic.psm1 -- Logique metier de l'API web PSWinDeploy.
#
# Regroupe les fonctions appelees par les routes Pode (Deploy-API.ps1), pour
# garder les routes minces et tester la logique separement. Aligne sur
# l'architecture actuelle : catalogue avec Script, sequences by-name/by-mac
# (format MAC AABBCCDDEEFF), drivers, suivi/historique des deploiements.
#
# Depend de PsdJson (conversion PSD1<->JSON).

Set-StrictMode -Version Latest

# Chemins par defaut (surcharges par la config a l'init)
$script:ApiConfig = @{
    ProjectRoot   = ''
    SequencesPath = ''     # \\srv\Deploy\Sequences
    DriverShare   = ''     # \\srv\Drivers
    CataloguePath = ''     # \\srv\...\applications.psd1 ou local
    HistoryPath   = ''     # dossier d'historique des deploiements
}

function Initialize-ApiLogic {
    param([hashtable]$Config)
    foreach ($k in $Config.Keys) { $script:ApiConfig[$k] = $Config[$k] }
    # Dossier d'historique par defaut
    if (-not $script:ApiConfig.HistoryPath) {
        $script:ApiConfig.HistoryPath = Join-Path $script:ApiConfig.ProjectRoot 'Logs\deploy-history'
    }
    if (-not (Test-Path $script:ApiConfig.HistoryPath)) {
        New-Item -ItemType Directory $script:ApiConfig.HistoryPath -Force -EA SilentlyContinue | Out-Null
    }
}

function Get-ApiConfig { return $script:ApiConfig }

# ===========================================================================
#  CATALOGUE (synchro JSON <-> PSD1)
# ===========================================================================
function Get-AppCatalogue {
    <# .SYNOPSIS Lit le catalogue d'applications (PSD1) et retourne la liste d'apps. #>
    $path = $script:ApiConfig.CataloguePath
    if (-not $path) { $path = Join-Path $script:ApiConfig.ProjectRoot 'Catalogue\applications.psd1' }
    $data = ConvertFrom-Psd1File -Path $path
    if (-not $data) { return @() }
    $apps = if ($data.ContainsKey('Applications')) { $data['Applications'] } else { $data }
    return @($apps)
}

function Save-AppCatalogue {
    <# .SYNOPSIS Ecrit le catalogue (depuis une liste d'apps) en PSD1 avec BOM. #>
    param([Parameter(Mandatory)]$Apps)
    $path = $script:ApiConfig.CataloguePath
    if (-not $path) { $path = Join-Path $script:ApiConfig.ProjectRoot 'Catalogue\applications.psd1' }
    $obj = @{ Applications = @($Apps) }
    Save-Psd1File -Object $obj -Path $path | Out-Null
    return $path
}

# ===========================================================================
#  SEQUENCES (generation by-name / by-mac, format aligne)
# ===========================================================================
function Format-MacAddress {
    <# .SYNOPSIS Normalise une MAC au format AABBCCDDEEFF (sans separateur, maj).
        DOIT correspondre au format du resolver et de PostInstall. #>
    param([string]$Mac)
    if (-not $Mac) { return '' }
    return ($Mac -replace '[:-]', '').ToUpper()
}

function Save-SequenceByName {
    <# .SYNOPSIS Genere une sequence by-name sur le partage Sequences. #>
    param(
        [Parameter(Mandatory)][string]$ComputerName,
        [Parameter(Mandatory)]$Sequence
    )
    $dir = Join-Path $script:ApiConfig.SequencesPath 'by-name'
    $path = Join-Path $dir "$ComputerName.psd1"
    Save-Psd1File -Object $Sequence -Path $path | Out-Null
    return $path
}

function Save-SequenceByMac {
    <# .SYNOPSIS Genere une sequence by-mac sur le partage Sequences (format aligne). #>
    param(
        [Parameter(Mandatory)][string]$Mac,
        [Parameter(Mandatory)]$Sequence
    )
    $macNorm = Format-MacAddress $Mac
    if (-not $macNorm) { throw "MAC invalide : $Mac" }
    $dir = Join-Path $script:ApiConfig.SequencesPath 'by-mac'
    $path = Join-Path $dir "$macNorm.psd1"
    Save-Psd1File -Object $Sequence -Path $path | Out-Null
    return $path
}

function Get-SequenceList {
    <# .SYNOPSIS Liste les sequences disponibles (templates + by-name + by-mac). #>
    $result = @()
    $root = $script:ApiConfig.SequencesPath
    if (-not (Test-Path $root -EA SilentlyContinue)) { return $result }
    # Templates a la racine
    foreach ($f in @(Get-ChildItem $root -Filter '*.psd1' -EA SilentlyContinue)) {
        $result += [PSCustomObject]@{ Type = 'template'; Name = $f.BaseName; Path = $f.FullName }
    }
    # by-name
    $byName = Join-Path $root 'by-name'
    if (Test-Path $byName -EA SilentlyContinue) {
        foreach ($f in @(Get-ChildItem $byName -Filter '*.psd1' -EA SilentlyContinue)) {
            $result += [PSCustomObject]@{ Type = 'by-name'; Name = $f.BaseName; Path = $f.FullName }
        }
    }
    # by-mac
    $byMac = Join-Path $root 'by-mac'
    if (Test-Path $byMac -EA SilentlyContinue) {
        foreach ($f in @(Get-ChildItem $byMac -Filter '*.psd1' -EA SilentlyContinue)) {
            $result += [PSCustomObject]@{ Type = 'by-mac'; Name = $f.BaseName; Path = $f.FullName }
        }
    }
    return $result
}

# ===========================================================================
#  DRIVERS (listing des modeles)
# ===========================================================================
function Get-DriverModelList {
    <# .SYNOPSIS Liste les dossiers modeles de drivers (hors WinPE) + nb de .inf. #>
    $root = $script:ApiConfig.DriverShare
    $result = @()
    if (-not $root -or -not (Test-Path $root -EA SilentlyContinue)) { return $result }
    foreach ($d in @(Get-ChildItem $root -Directory -EA SilentlyContinue)) {
        if ($d.Name -ieq 'WinPE') { continue }
        $infCount = @(Get-ChildItem $d.FullName -Filter '*.inf' -Recurse -EA SilentlyContinue).Count
        $result += [PSCustomObject]@{
            Name     = $d.Name
            InfCount = $infCount
            Path     = $d.FullName
        }
    }
    return $result
}

# ===========================================================================
#  SUIVI / HISTORIQUE des deploiements
# ===========================================================================
function Write-DeployReport {
    <#
    .SYNOPSIS Enregistre un rapport d'avancement envoye par un PC en cours de
        deploiement (heartbeat). Stocke l'etat courant + ajoute a l'historique.
    .PARAMETER Report  Hashtable : computerName, mac, status, step, percent, message, timestamp
    #>
    param([Parameter(Mandatory)][hashtable]$Report)

    $id = "$($Report['computerName'])"
    if (-not $id) { $id = "$($Report['mac'])" }
    if (-not $id) { $id = "unknown-$(Get-Random -Maximum 99999)" }
    $id = $id -replace '[^A-Za-z0-9_-]', '_'

    if (-not $Report.ContainsKey('timestamp')) { $Report['timestamp'] = (Get-Date -Format 'o') }

    # Etat courant (dernier rapport, ecrase)
    $statePath = Join-Path $script:ApiConfig.HistoryPath "current-$id.json"
    try { $Report | ConvertTo-Json -Depth 6 | Set-Content -Path $statePath -Encoding UTF8 -EA SilentlyContinue } catch {}

    # Historique (append, une ligne JSON par evenement)
    $histPath = Join-Path $script:ApiConfig.HistoryPath "history-$id.jsonl"
    try { ($Report | ConvertTo-Json -Depth 6 -Compress) | Add-Content -Path $histPath -Encoding UTF8 -EA SilentlyContinue } catch {}

    return $id
}

function Get-DeployCurrentList {
    <# .SYNOPSIS Liste les deploiements actuels (dernier etat de chaque PC). #>
    $dir = $script:ApiConfig.HistoryPath
    $result = @()
    if (-not (Test-Path $dir -EA SilentlyContinue)) { return $result }
    foreach ($f in @(Get-ChildItem $dir -Filter 'current-*.json' -EA SilentlyContinue)) {
        try {
            $obj = Get-Content $f.FullName -Raw -EA Stop | ConvertFrom-Json
            $result += $obj
        } catch {}
    }
    return $result
}

function Get-DeployHistory {
    <# .SYNOPSIS Retourne l'historique d'un PC (liste d'evenements). #>
    param([Parameter(Mandatory)][string]$Id)
    $safe = $Id -replace '[^A-Za-z0-9_-]', '_'
    $histPath = Join-Path $script:ApiConfig.HistoryPath "history-$safe.jsonl"
    $result = @()
    if (-not (Test-Path $histPath -EA SilentlyContinue)) { return $result }
    foreach ($line in Get-Content $histPath -EA SilentlyContinue) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        try { $result += ($line | ConvertFrom-Json) } catch {}
    }
    return $result
}

Export-ModuleMember -Function @(
    'Initialize-ApiLogic'
    'Get-ApiConfig'
    'Get-AppCatalogue'
    'Save-AppCatalogue'
    'Format-MacAddress'
    'Save-SequenceByName'
    'Save-SequenceByMac'
    'Get-SequenceList'
    'Get-DriverModelList'
    'Write-DeployReport'
    'Get-DeployCurrentList'
    'Get-DeployHistory'
)
