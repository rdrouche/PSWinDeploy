<#
.SYNOPSIS
    Config.psm1 -- Chargeur de configuration central PSWinDeploy
.DESCRIPTION
    Chaque module appelle Import-PSWinDeployConfig au chargement.
    Priorite de resolution :
      1. Parametre -ConfigPath explicite
      2. Variable d'env PSWINDEX_CONFIG
      3. PSWinDeploy.psd1 dans le dossier racine du projet (remonte depuis le module)
      4. C:\Deploy\PSWinDeploy.psd1 (machine cible / WinPE)
      5. X:\Deploy\PSWinDeploy.psd1 (WinPE X: drive)
      6. Valeurs par defaut codees en dur (toujours valide sans config)
#>

Set-StrictMode -Version Latest

# -----------------------------------------------------------------------------
# VERSION -- source unique de verite : le fichier VERSION a la racine du projet.
# Get-PSWDVersion le lit (avec cache + fallback) pour que l'affichage de la
# version soit dynamique partout (console, API, assistant) sans hardcode.
# -----------------------------------------------------------------------------
$script:CachedVersion = $null
function Get-PSWDVersion {
    <# .SYNOPSIS Retourne la version du projet, lue depuis le fichier VERSION.
       Cherche le fichier en remontant depuis ce module. Fallback sur la valeur
       par defaut si introuvable. Resultat mis en cache. #>
    param([switch]$Refresh)
    if ($script:CachedVersion -and -not $Refresh) { return $script:CachedVersion }
    $candidates = @(
        (Join-Path $PSScriptRoot '..\..\VERSION')        # Modules\Config\ -> racine
        (Join-Path $PSScriptRoot '..\..\..\VERSION')     # App\Modules\Config\ -> racine install
        (Join-Path (Get-Location) 'VERSION')
    )
    foreach ($c in $candidates) {
        if (Test-Path $c -EA SilentlyContinue) {
            try {
                $v = (Get-Content $c -Raw -EA Stop).Trim()
                if ($v) { $script:CachedVersion = $v; return $v }
            } catch {}
        }
    }
    # Fallback : derniere version connue figee ici (mise a jour par le bump).
    $script:CachedVersion = '0.8.0'
    return $script:CachedVersion
}

# -----------------------------------------------------------------------------
# VALEURS PAR DEFAUT (si aucun .psd1 trouve)
# x86 retire -- amd64 et arm64 uniquement (ADK 2004+)
# -----------------------------------------------------------------------------

$script:Defaults = @{
    Version          = '0.8.0'
    ProjectName      = 'PSWinDeploy'

    AdkPath          = 'C:\Program Files (x86)\Windows Kits\10\Assessment and Deployment Kit'
    WinPEAddonPath   = 'C:\Program Files (x86)\Windows Kits\10\Assessment and Deployment Kit\Windows Preinstallation Environment'
    Architecture     = 'amd64'
    WinPEWorkspace   = "$env:TEMP\WinPE-Work"
    WinPEOutputPath  = "$env:TEMP\WinPE-ISO"
    WinPEPackages    = @('PowerShell','WMI','NetFx','Scripting','StorageWMI','EnhancedStorage')
    WinPELocale      = 'fr-FR'

    ImageShare       = '\\SERVEUR\Images'
    DeployShare      = '\\SERVEUR\Deploy'
    LogShare         = '\\SERVEUR\Logs'
    DriverShare      = '\\SERVEUR\Drivers'
    SoftwareShare    = '\\SERVEUR\Logiciels'
    ScriptShare      = '\\SERVEUR\Scripts'
    ProfilesPath     = '\\SERVEUR\Deploy\Profiles'
    CataloguePath    = '\\SERVEUR\Deploy\Catalogue\catalogue.psd1'
    SequencesPath    = '\\SERVEUR\Deploy\Sequences'
    RuntimePath      = '\\SERVEUR\Deploy\Runtime'

    DefaultLocale    = 'fr-FR'
    DefaultTimezone  = 'Romance Standard Time'
    FirmwareType     = 'UEFI'
    DefaultDisk      = -1
    WindowsDrive     = 'W:'
    SystemDrive      = 'S:'
    RecoveryDrive    = 'R:'

    VaultPath        = 'C:\Deploy\secrets.vault.psd1'
    VaultMethod      = 'DPAPI'
    MaxReboots       = 5

    # Mode avance : debloque les options de diagnostic/test dans les assistants
    AdvancedMode     = $false
    # Options avancees (actives seulement si AdvancedMode = $true)
    AdvNoAutoLogon   = $false   # desactive l'autologon unattend (diagnostic BSOD)
    AdvSkipUnattend  = $false   # saute completement ApplyUnattend (test WIM brut)
    AdvVerboseLog    = $false   # logs detailles
    StateFile        = 'C:\Deploy\state.psd1'
    DeployLogPath    = 'C:\Deploy\Logs\deploy.log'

    ApiPort          = 8080
    ApiAllowedOrigin = '*'

    DeployRoot       = 'C:\Deploy'
    ModulesRoot      = 'C:\Deploy\Modules'
    ScriptsRoot      = 'C:\Deploy\Scripts'
}

# Config active (initialisee avec les defaults)
$script:Config = $script:Defaults.Clone()
$script:ConfigLoadedFrom = $null   # Initialise au chargement du module

# -----------------------------------------------------------------------------
# RESOLUTION DU CHEMIN CONFIG
# -----------------------------------------------------------------------------

function Resolve-ConfigPath {
    <#Trouve le PSWinDeploy.psd1 le plus proche dans la hierarchie#>
    param([string]$ExplicitPath)

    $candidates = @()

    # 1. Chemin explicite
    if ($ExplicitPath) { $candidates += $ExplicitPath }

    # 2. Variable d'environnement
    $envPath = [System.Environment]::GetEnvironmentVariable('PSWINDEX_CONFIG')
    if ($envPath) { $candidates += $envPath }

    # 3. Remonter depuis le dossier du module appelant
    $callerDir = Split-Path $PSScriptRoot -Parent   # Modules\ -> racine projet
    $projectRoot = Split-Path $callerDir -Parent    # racine -> parent
    foreach ($dir in @($callerDir, $projectRoot, (Split-Path $projectRoot -Parent))) {
        $candidates += Join-Path $dir 'PSWinDeploy.psd1'
    }

    # 4. Chemins absolus standard (machine cible + WinPE)
    $candidates += @(
        'C:\Deploy\PSWinDeploy.psd1',
        'X:\Deploy\PSWinDeploy.psd1',
        'D:\Deploy\PSWinDeploy.psd1'
    )

    foreach ($c in $candidates) {
        if ($c -and (Test-Path $c -ErrorAction SilentlyContinue)) {
            return $c
        }
    }
    return $null
}

# -----------------------------------------------------------------------------
# FONCTIONS PUBLIQUES
# -----------------------------------------------------------------------------

function Import-PSWinDeployConfig {
    <#
    .SYNOPSIS
        Charge la configuration PSWinDeploy depuis un fichier .psd1.
    .DESCRIPTION
        Fusionne le .psd1 trouve avec les valeurs par defaut.
        Les cles du .psd1 surchargent les defaults, les cles absentes
        du .psd1 gardent leur valeur par defaut.
        Idempotent -- peut etre appele plusieurs fois sans effet de bord.
    .PARAMETER ConfigPath Chemin explicite vers un PSWinDeploy.psd1.
    .PARAMETER Force      Recharge meme si deja charge.
    .EXAMPLE
        Import-PSWinDeployConfig
        Import-PSWinDeployConfig -ConfigPath 'D:\MonDeploy\PSWinDeploy.psd1'
    #>
    [CmdletBinding()]
    param(
        [string]$ConfigPath,
        [switch]$Force,
        [switch]$ResolvePaths   # Resout les @{DNS;IP} -> chemin accessible
    )

    # Deja charge depuis un fichier -- skip sauf si Force
    if ($script:ConfigLoadedFrom -and -not $Force) { return $script:Config }

    # Repartir des defaults
    $script:Config = $script:Defaults.Clone()

    $resolved = Resolve-ConfigPath -ExplicitPath $ConfigPath
    if ($resolved) {
        try {
            $fileData = Import-PowerShellDataFile $resolved
            foreach ($key in $fileData.Keys) {
                $script:Config[$key] = $fileData[$key]
            }
            $script:ConfigLoadedFrom = $resolved
            Write-Verbose "PSWinDeploy config chargee : $resolved"
        } catch {
            Write-Warning "Erreur lecture config '$resolved' : $_ -- defaults utilises"
            $script:ConfigLoadedFrom = 'defaults'
        }
    } else {
        $script:ConfigLoadedFrom = 'defaults'
        Write-Verbose "PSWinDeploy: no .psd1 found -- using default values"
    }

    # Validation architecture (x86 retire depuis ADK 2004)
    if ($script:Config.Architecture -notin @('amd64','arm64')) {
        Write-Warning "Architecture '$($script:Config.Architecture)' non supportee. x86 retire depuis ADK 2004. Force sur 'amd64'."
        $script:Config.Architecture = 'amd64'
    }

    # Resoudre les chemins de partage @{DNS;IP} -> chemin accessible, UNE FOIS.
    # Conserve l'original sous <Cle>Raw, et met la valeur resolue dans <Cle>.
    # Apres ca, tout le programme lit Get-PSWinDeployConfig -Key 'DeployShare'
    # et obtient un chemin string deja teste (nom si joignable, sinon IP).
    if ($ResolvePaths) {
        $shareKeys = @('ImageShare','DeployShare','LogShare','DriverShare','SoftwareShare','ScriptShare','ProfilesPath','CataloguePath','SequencesPath','RuntimePath')
        foreach ($k in $shareKeys) {
            if (-not $script:Config.ContainsKey($k)) { continue }
            $v = $script:Config[$k]
            if ($v -is [hashtable] -or $v -is [System.Collections.IDictionary]) {
                $script:Config["${k}Raw"] = $v   # garder l'original (DNS+IP)
                $dnsP = $v['DNS']; $ipP = $v['IP']
                $chosen = $null
                if     ($dnsP -and (Test-Path $dnsP -EA SilentlyContinue)) { $chosen = $dnsP }
                elseif ($ipP  -and (Test-Path $ipP  -EA SilentlyContinue)) { $chosen = $ipP }
                elseif ($ipP)  { $chosen = $ipP }     # repli : IP (fiable hors domaine)
                elseif ($dnsP) { $chosen = $dnsP }
                $script:Config[$k] = $chosen
            }
        }
        # Memoriser le mapping nom->IP pour Resolve-Share (sous-chemins ad hoc)
        foreach ($k in $shareKeys) {
            $rawKey = "${k}Raw"
            if ($script:Config.ContainsKey($rawKey)) {
                $rv = $script:Config[$rawKey]
                if ($rv['DNS'] -match '^\\\\([^\\]+)\\' ) { $dnsSrv = $Matches[1] } else { $dnsSrv = $null }
                if ($rv['IP']  -match '^\\\\([^\\]+)\\' ) { $ipSrv  = $Matches[1] } else { $ipSrv = $null }
                if ($dnsSrv -and $ipSrv -and (Get-Command Set-PSWDShareHostMap -EA SilentlyContinue)) {
                    $cur = Get-PSWDShareHostMap
                    $cur[$dnsSrv] = $ipSrv
                    Set-PSWDShareHostMap -Map $cur
                }
            }
        }
    }

    return $script:Config
}

function Get-PSWinDeployConfig {
    <#
    .SYNOPSIS Retourne la configuration active (charge si necessaire).
    .PARAMETER Key Cle specifique a retourner. Si absent, retourne tout.
    .EXAMPLE
        $cfg = Get-PSWinDeployConfig
        $share = Get-PSWinDeployConfig -Key ImageShare
    #>
    [CmdletBinding()]
    param([string]$Key)

    if (-not $script:ConfigLoadedFrom) { Import-PSWinDeployConfig | Out-Null }

    if ($Key) {
        if ($script:Config.ContainsKey($Key)) { return $script:Config[$Key] }
        throw "Cle de config inconnue : '$Key'. Cles disponibles : $($script:Config.Keys -join ', ')"
    }
    return $script:Config
}

function Set-PSWinDeployConfig {
    <#
    .SYNOPSIS Surcharge une ou plusieurs valeurs de config en memoire (sans toucher au .psd1).
    .EXAMPLE
        Set-PSWinDeployConfig -Values @{ ImageShare = '\\NAS\Images'; Architecture = 'arm64' }
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [hashtable]$Values
    )

    if (-not $script:ConfigLoadedFrom) { Import-PSWinDeployConfig | Out-Null }

    foreach ($key in $Values.Keys) {
        if ($key -eq 'Architecture' -and $Values[$key] -notin @('amd64','arm64')) {
            throw "Architecture invalide : '$($Values[$key])'. Valeurs acceptees : amd64, arm64 (x86 retire depuis ADK 2004)"
        }
        $script:Config[$key] = $Values[$key]
    }
    Write-Verbose "Config mise a jour : $($Values.Keys -join ', ')"
}

function Show-PSWinDeployConfig {
    <#
    .SYNOPSIS Affiche la configuration active de facon lisible.#>
    if (-not $script:ConfigLoadedFrom) { Import-PSWinDeployConfig | Out-Null }

    Write-Host ""
    Write-Host "  PSWinDeploy v$($script:Config.Version) -- Configuration active" -ForegroundColor Cyan
    Write-Host "  Source : $script:ConfigLoadedFrom" -ForegroundColor DarkGray
    Write-Host "  -------------------------------------------------" -ForegroundColor DarkGray

    $sections = [ordered]@{
        'ADK / WinPE'   = @('Architecture','AdkPath','WinPEAddonPath','WinPEWorkspace','WinPEOutputPath','WinPELocale','WinPEPackages')
        'Reseau'        = @('ImageShare','DeployShare','LogShare','DriverShare','SoftwareShare','ScriptShare','ProfilesPath','SequencesPath','RuntimePath')
        'Deploiement'   = @('DefaultLocale','DefaultTimezone','FirmwareType','DefaultDisk','WindowsDrive','SystemDrive','RecoveryDrive')
        'Securite'      = @('VaultPath','VaultMethod','MaxReboots','StateFile','DeployLogPath')
        'API'           = @('ApiPort','ApiAllowedOrigin')
    }

    foreach ($section in $sections.Keys) {
        Write-Host "  [$section]" -ForegroundColor Yellow
        foreach ($key in $sections[$section]) {
            $val = $script:Config[$key]
            if ($val -is [array]) { $val = $val -join ', ' }
            Write-Host ("    {0,-22} = {1}" -f $key, $val) -ForegroundColor Gray
        }
        Write-Host ""
    }
}

Export-ModuleMember -Function @(
    'Get-PSWDVersion'
    'Import-PSWinDeployConfig'
    'Get-PSWinDeployConfig'
    'Set-PSWinDeployConfig'
    'Show-PSWinDeployConfig'
)

# Helper : convertir un objet PS en format PSD1 string
function ConvertTo-Psd1String {
    param($Obj, [int]$Indent=0)
    $sp  = '    ' * $Indent
    $sp1 = '    ' * ($Indent+1)
    if ($null -eq $Obj)                    { return '$null' }
    if ($Obj -is [bool])                   { if ($Obj) { return '$true' } else { return '$false' } }
    if ($Obj -is [int] -or $Obj -is [double]) { return "$Obj" }
    if ($Obj -is [string])                 { $e = $Obj.Replace("'", "''"); return "'$e'" }
    if ($Obj -is [System.Collections.IEnumerable] -and -not ($Obj -is [string])) {
        $items = @($Obj | ForEach-Object { ConvertTo-Psd1String $_ ($Indent+1) })
        if (@($items).Count -eq 0) { return '@()' }
        return "@(`n$sp1$($items -join ",`n$sp1")`n$sp)"
    }
    if ($Obj -is [PSCustomObject] -or $Obj -is [hashtable]) {
        $props = if ($Obj -is [hashtable]) { $Obj.GetEnumerator() } else { $Obj.PSObject.Properties }
        $pairs = $props | ForEach-Object { "$sp1$($_.Name) = $(ConvertTo-Psd1String $_.Value ($Indent+1))" }
        if (-not $pairs) { return '@{}' }
        $nl = [Environment]::NewLine
        $joined = $pairs -join $nl
        return "@{$nl$joined$nl$sp}"
    }
    return "'$Obj'"
}

function Save-Psd1 {
    param([object]$Data, [string]$Path, [string]$Comment='')
    $content = if ($Comment) { "# $Comment`n" } else { '' }
    $content += ConvertTo-Psd1String $Data
    [System.IO.File]::WriteAllText($Path, $content, [System.Text.Encoding]::UTF8)
}
