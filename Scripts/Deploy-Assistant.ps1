#Requires -Version 5.1
<#
.SYNOPSIS
    Deploy-Assistant.ps1 -- Assistant de deploiement PSWinDeploy
.DESCRIPTION
    Guide l'operateur avec trois modes au choix :

      Mode 1 -- Profil     : selectionne un profil preconfigure
                             (apps, domaine, OU predefinis)
      Mode 2 -- Sequence   : pointe vers un .json existant directement
      Mode 3 -- From scratch: construit la sequence pas a pas
                             (aucun profil ni sequence requis)

    Tous les modes partagent les memes etapes finales :
    choix OS, disque, firmware, confirmation, lancement.

.EXAMPLE
    # Mode interactif (choix du mode au demarrage)
    .\Deploy-Assistant.ps1

    # Forcer un mode directement
    .\Deploy-Assistant.ps1 -Mode Profile
    .\Deploy-Assistant.ps1 -Mode Sequence -SequencePath '\\SRV\Deploy\Seq\Win11.json'
    .\Deploy-Assistant.ps1 -Mode Scratch

    # Sans API (WinPE)
    .\Deploy-Assistant.ps1 -Direct
#>

[CmdletBinding()]
param(
    [ValidateSet('Profile','Sequence','Scratch','')]
    [string]$Mode        = '',
    [string]$SequencePath = '',
    [string]$ApiUrl       = '',
    [switch]$Direct,
    [string]$ConfigPath   = ''
)

Set-StrictMode -Version Latest

# Helper : sauvegarder un objet en PSD1 (BOM) pour lecture par WinPE
function Save-AssistantPsd1 {
    param($Data, [string]$Path)
    function ConvertTo-P {
        param($O, [int]$I = 0)
        $sp = '    ' * $I; $sp1 = '    ' * ($I + 1)
        if ($null -eq $O) { return '$null' }
        if ($O -is [bool]) { return $(if ($O) { '$true' } else { '$false' }) }
        if ($O -is [int] -or $O -is [long] -or $O -is [double]) { return "$O" }
        if ($O -is [string]) { $e = $O.Replace("'", "''"); return "'$e'" }
        if ($O -is [System.Collections.IEnumerable] -and $O -isnot [string]) {
            $items = @($O | ForEach-Object { "$sp1$(ConvertTo-P $_ ($I+1))" })
            if ($items.Count -eq 0) { return '@()' }
            return "@(`n$($items -join "`n")`n$sp)"
        }
        if ($O -is [PSCustomObject] -or $O -is [hashtable]) {
            $props = if ($O -is [hashtable]) { $O.GetEnumerator() } else { $O.PSObject.Properties }
            $pairs = @($props | ForEach-Object { "$sp1$($_.Name) = $(ConvertTo-P $_.Value ($I+1))" })
            if ($pairs.Count -eq 0) { return '@{}' }
            return "@{`n$($pairs -join "`n")`n$sp}"
        }
        return "'$O'"
    }
    $utf8Bom = New-Object System.Text.UTF8Encoding $true
    [System.IO.File]::WriteAllText($Path, (ConvertTo-P $Data), $utf8Bom)
}

$ErrorActionPreference = 'Continue'

# ---------------------------------------------------------------------------
# HELPERS
# ---------------------------------------------------------------------------

function Write-Header {
    param([string]$Title)
    $w = 58
    Write-Host ""
    Write-Host "  +$('-'*$w)+" -ForegroundColor Cyan
    $p = ' ' * [Math]::Max(0,[Math]::Floor(($w-$Title.Length)/2))
    $r = ' ' * [Math]::Max(0,$w-$Title.Length-$p.Length)
    Write-Host "  |$p$Title$r|" -ForegroundColor Cyan
    Write-Host "  +$('-'*$w)+" -ForegroundColor Cyan
    Write-Host ""
}
function Write-Step { param([string]$M) Write-Host "  [>>] $M" -ForegroundColor Magenta }
function Write-Info { param([string]$M) Write-Host "  [~]  $M" -ForegroundColor Cyan }
function Write-OK   { param([string]$M) Write-Host "  [OK] $M" -ForegroundColor Green }
function Write-Warn { param([string]$M) Write-Host "  [!]  $M" -ForegroundColor Yellow }
function Write-Err  { param([string]$M) Write-Host "  [X]  $M" -ForegroundColor Red }
function Write-Sep  { Write-Host "  $('-'*58)" -ForegroundColor DarkGray }

function Read-Choice {
    param([string]$Q, [int]$Max, [int]$Min=1, [int]$AllowZero=0)
    $choice = $null
    while ($null -eq $choice) {
        Write-Host "  [?]  $Q [$Min-$Max$(if($AllowZero){'/0'})] : " -ForegroundColor White -NoNewline
        $inp = (Read-Host).Trim().Trim('"').Trim("'").Trim()
        if ($AllowZero -and $inp -eq '0') { return 0 }
        if ($inp -match '^\d+$' -and [int]$inp -ge $Min -and [int]$inp -le $Max) {
            $choice = [int]$inp
        } else { Write-Warn "Entrer un nombre entre $Min et $Max." }
    }
    return $choice
}

function Read-YesNo {
    param([string]$Q, [bool]$Def=$true)
    Write-Host "  [?]  $Q [$(if($Def){'O/n'}else{'o/N'})] : " -ForegroundColor White -NoNewline
    $a = Read-Host
    if ([string]::IsNullOrWhiteSpace($a)) { return $Def }
    return $a.Trim().ToLower() -in @('o','oui','y','yes')
}

function Read-Answer {
    param([string]$Q, [string]$Default='', [switch]$Required)
    $hint = if ($Default) { " (defaut : $Default)" } else { '' }
    Write-Host "  [?]  $Q$hint : " -ForegroundColor White -NoNewline
    $a = Read-Host
    if ([string]::IsNullOrWhiteSpace($a)) {
        if ($Default) { return $Default }
        if ($Required) { Write-Warn "Valeur obligatoire."; return Read-Answer @PSBoundParameters }
        return ''
    }
    return $a.Trim()
}

function Format-Size {
    param([long]$B)
    if ($B -gt 1GB) { return "{0:N1} GB" -f ($B/1GB) }
    if ($B -gt 1MB) { return "{0:N0} MB" -f ($B/1MB) }
    return "{0:N0} KB" -f ($B/1KB)
}

# ---------------------------------------------------------------------------
# CHARGEMENT CONFIG
# ---------------------------------------------------------------------------

$scriptDir   = Split-Path $PSCommandPath -Parent
$projectRoot = Split-Path $scriptDir -Parent

$cfg = @{
    ImageShare    = '\\SERVEUR\Images'
    ProfilesPath  = '\\SERVEUR\Deploy\Profiles'
    SequencesPath = '\\SERVEUR\Deploy\Sequences'
    CataloguePath = '\\SERVEUR\Deploy\Catalogue\catalogue.psd1'
    RuntimePath   = '\\SERVEUR\Deploy\Runtime'
    SoftwareShare = '\\SERVEUR\Logiciels'
    ScriptShare   = '\\SERVEUR\Scripts'
    ApiPort       = 8080
}

$cfgPaths = @(
    $ConfigPath,
    "$projectRoot\PSWinDeploy.psd1",
    "$scriptDir\PSWinDeploy.psd1",
    'C:\Deploy\PSWinDeploy.psd1',
    'X:\Deploy\PSWinDeploy.psd1',
    'C:\PSWinDeploy\App\PSWinDeploy.psd1'
)
foreach ($p in $cfgPaths) {
    if ($p -and (Test-Path $p -ErrorAction SilentlyContinue)) {
        try {
            $loaded = Import-PowerShellDataFile $p
            foreach ($k in $loaded.Keys) { $cfg[$k] = $loaded[$k] }
            Write-OK "Config : $p"
        } catch {}
        break
    }
}

# Resoudre les chemins de partage @{DNS;IP} -> chemin accessible, UNE fois.
# Tout le reste du script utilise $cfg.X comme une simple string.
$__resolveShare = {
    param($v)
    if ($v -is [hashtable]) {
        if ($v['DNS'] -and (Test-Path $v['DNS'] -EA SilentlyContinue)) { return $v['DNS'] }
        if ($v['IP']  -and (Test-Path $v['IP']  -EA SilentlyContinue)) { return $v['IP'] }
        if ($v['DNS']) { return $v['DNS'] }
        return $v['IP']
    }
    return $v
}
foreach ($shareKey in @('ImageShare','DeployShare','LogShare','DriverShare','SoftwareShare','ScriptShare','ProfilesPath','CataloguePath','SequencesPath','RuntimePath')) {
    if ($cfg.ContainsKey($shareKey) -and $cfg[$shareKey]) {
        $cfg[$shareKey] = & $__resolveShare $cfg[$shareKey]
    }
}

# ---------------------------------------------------------------------------
# FONCTIONS COMMUNES
# ---------------------------------------------------------------------------

function Get-AvailableOS {
    param([string]$ImageShare, [switch]$NoCache)
    $cachePath = "$env:TEMP\pswindex-os-cache.psd1"
    if (-not (Test-Path $ImageShare -ErrorAction SilentlyContinue)) {
        Write-Warn "Partage Images inaccessible : $ImageShare"
        return @()
    }
    $wimFiles = Get-ChildItem $ImageShare -Filter '*.wim' -ErrorAction SilentlyContinue |
                Sort-Object LastWriteTime -Descending
    if (@($wimFiles).Count -eq 0) {
        Write-Warn "Aucun .wim dans $ImageShare"
        Write-Warn "Utiliser Export-WIMImage.ps1 pour ajouter des images."
        return @()
    }
    $cache = @{}
    if (-not $NoCache -and (Test-Path $cachePath)) {
        try {
            $cacheAge = (Get-Date) - (Get-Item $cachePath).LastWriteTime
            if ($cacheAge.TotalMinutes -lt 60) {
                $cached = Get-Content $cachePath -Raw | ConvertFrom-Json
                $cached | ForEach-Object { $cache[$_.FilePath] = $_ }
            }
        } catch {}
    }
    $osList = [System.Collections.Generic.List[PSCustomObject]]::new()
    foreach ($wf in $wimFiles) {
        $fp = $wf.FullName
        if ($cache.ContainsKey($fp)) {
            $c = $cache[$fp]
            if ([datetime]$c.LastModified -eq $wf.LastWriteTime) { $osList.Add([PSCustomObject]$c); continue }
        }
        Write-Info "  Lecture : $(Split-Path $fp -Leaf)..."
        try {
            # Forcer UTF-8 pour eviter Nom/Taille sur systemes Windows FR
        $prevEnc = [Console]::OutputEncoding
        try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}
        $out = & dism.exe /Get-WimInfo /WimFile:"$fp" 2>&1
        try { [Console]::OutputEncoding = $prevEnc } catch {}
            $name=''; $build=''; $lang=''
            foreach ($l in $out) {
                $ls = if ($l -is [string]) { $l.Trim() } else { $l.ToString().Trim() }
                # Cles EN et FR : Name/Nom, Version, Default Language/Langue par defaut
                if ($ls -match '^(Name|Nom|Nombre|Nome|Naam)\s*:\s*(.+)$' -and -not $name) {
                    $name = $Matches[2]
                }
                if ($ls -match '^Version\s*:\s*\d+\.\d+\.(\d+)' -and -not $build) {
                    $build = $Matches[1]
                }
                if ($ls -match '^(Default Language|Langue par defaut|Standardsprache)\s*:\s*(.+)$' -and -not $lang) {
                    $lang = $Matches[2]
                }
            }
            $entry = [PSCustomObject]@{
                FilePath     = $fp
                FileName     = $wf.Name
                DisplayName  = if ($name) { $name } else { [IO.Path]::GetFileNameWithoutExtension($wf.Name) }
                Build        = $build; Language = $lang
                SizeBytes    = $wf.Length
                SizeDisplay  = Format-Size $wf.Length
                LastModified = $wf.LastWriteTime.ToString('o')
            }
            $osList.Add($entry)
        } catch {
            $osList.Add([PSCustomObject]@{
                FilePath=$fp; FileName=$wf.Name
                DisplayName=[IO.Path]::GetFileNameWithoutExtension($wf.Name)
                Build=''; Language=''; SizeBytes=$wf.Length
                SizeDisplay=(Format-Size $wf.Length)
                LastModified=$wf.LastWriteTime.ToString('o')
            })
        }
    }
    try { $osList | ConvertTo-Json -Depth 5 | Set-Content $cachePath -Encoding UTF8 } catch {}
    return $osList
}

function Get-Profiles {
    param([string]$ProfilesPath)
    $list = [System.Collections.Generic.List[PSCustomObject]]::new()
    if (-not (Test-Path $ProfilesPath -ErrorAction SilentlyContinue)) { return $list }
    foreach ($f in Get-ChildItem $ProfilesPath -Filter '*.psd1' -ErrorAction SilentlyContinue) {
        try { $list.Add((Get-Content $f.FullName -Raw | ConvertFrom-Json)) }
        catch { Write-Warn "Profil invalide : $($f.Name)" }
    }
    return $list
}

function Get-AppCatalogue {
    param([string]$CataloguePath)
    if (-not (Test-Path $CataloguePath -ErrorAction SilentlyContinue)) { return @() }
    try { return Get-Content $CataloguePath -Raw | ConvertFrom-Json } catch { return @() }
}

function Show-DiskSummary {
    $disks = @(Get-Disk | Sort-Object Number)
    Write-Host ""
    foreach ($disk in $disks) {
        $parts   = Get-Partition -DiskNumber $disk.Number -ErrorAction SilentlyContinue
        $isSys   = ($parts | Where-Object { $_.IsSystem -or $_.IsBoot }) -ne $null
        $sizeStr = if ($disk.Size -gt 0) { Format-Size $disk.Size } else { '?' }
        $col     = if ($isSys) { 'Yellow' } else { 'White' }
        Write-Host ("  Disque {0}  {1,-38}  {2,8}  {3}" -f `
            $disk.Number, $disk.FriendlyName, $sizeStr, $disk.PartitionStyle) -ForegroundColor $col
        if ($isSys) { Write-Host "          [SYSTEME EN COURS]" -ForegroundColor Yellow }
        foreach ($part in ($parts | Sort-Object PartitionNumber)) {
            $vol    = try { Get-Volume -Partition $part -ErrorAction SilentlyContinue } catch { $null }
            $letter = if ($part.DriveLetter -and $part.DriveLetter -ne "`0") { "$($part.DriveLetter):" } else { '  ' }
            $pType  = switch ($part.Type) { 'System'{'EFI '}; 'Reserved'{'MSR '}; 'Recovery'{'REC '}; default{'NTFS'} }
            Write-Host ("         [{0}] P{1}  {2}  {3,8}" -f $pType, $part.PartitionNumber, $letter, (Format-Size $part.Size)) -ForegroundColor DarkGray
        }
        Write-Host ""
    }
}

function Select-TargetDisk {
    $disks = @(Get-Disk | Where-Object { $_.OperationalStatus -eq 'Online' } | Sort-Object Number)
    $nonSys = $disks | Where-Object {
        -not (Get-Partition -DiskNumber $_.Number -ErrorAction SilentlyContinue | Where-Object { $_.IsSystem -or $_.IsBoot })
    }
    if (@($nonSys).Count -eq 1) {
        Write-OK "Un seul disque disponible : $($nonSys[0].Number) -- $($nonSys[0].FriendlyName)"
        return $nonSys[0].Number
    }
    $map = @{}; $i = 1
    foreach ($d in $disks) {
        $isSys = (Get-Partition -DiskNumber $d.Number -ErrorAction SilentlyContinue | Where-Object { $_.IsSystem -or $_.IsBoot }) -ne $null
        $warn  = if ($isSys) { ' [SYSTEME]' } else { '' }
        Write-Host "    [$i] Disque $($d.Number) -- $($d.FriendlyName) -- $(Format-Size $d.Size)$warn" `
            -ForegroundColor $(if($isSys){'Yellow'}else{'White'})
        $map[$i] = $d.Number; $i++
    }
    $c = Read-Choice "Choisir le disque cible" -Max ($i-1)
    $diskNum = $map[$c]
    Write-Host ""
    Write-Host "  +--------------------------------------------------+" -ForegroundColor Red
    Write-Host "  |  ATTENTION : Disque $diskNum sera ENTIEREMENT EFFACE   |" -ForegroundColor Red
    Write-Host "  +--------------------------------------------------+" -ForegroundColor Red
    if (-not (Read-YesNo "Confirmer l'effacement ?" $false)) { return Select-TargetDisk }
    return $diskNum
}

function Invoke-DeployAPI {
    param([string]$BaseUrl, [string]$Endpoint, [string]$Method='GET', $Body)
    try {
        if ($Body) {
            $json = $Body | ConvertTo-Json -Depth 10
            return Invoke-RestMethod -Uri "$BaseUrl/api/$Endpoint" -Method $Method -Body $json -ContentType 'application/json' -TimeoutSec 15
        }
        return Invoke-RestMethod -Uri "$BaseUrl/api/$Endpoint" -Method $Method -TimeoutSec 10
    } catch { throw "API $Method $Endpoint : $_" }
}

# ---------------------------------------------------------------------------
# BANNIERE + DETECTION API
# ---------------------------------------------------------------------------

Clear-Host
Write-Host ""
Write-Host "  ==========================================================" -ForegroundColor Cyan
Write-Host "      PSWinDeploy -- Editeur de sequences de deploiement               " -ForegroundColor Cyan
Write-Host "  ==========================================================" -ForegroundColor Cyan
Write-Host ""

$useApi = $false
if (-not $Direct) {
    foreach ($url in @($ApiUrl, "http://localhost:$($cfg.ApiPort)", "http://$env:COMPUTERNAME`:$($cfg.ApiPort)")) {
        if (-not $url) { continue }
        try {
            $h = Invoke-DeployAPI -BaseUrl $url -Endpoint 'health'
            $ApiUrl = $url; $useApi = $true
            Write-OK "API : $ApiUrl (v$($h.version))"
            break
        } catch {}
    }
    if (-not $useApi) { Write-Info "API non detectee -- mode direct" }
}

# ---------------------------------------------------------------------------
# CHOIX DU MODE
# ---------------------------------------------------------------------------

Write-Header "Mode de deploiement"

if (-not $Mode) {
    $profiles    = Get-Profiles -ProfilesPath $cfg.ProfilesPath
    $hasProfiles = @($profiles).Count -gt 0
    $hasSeqs     = (Test-Path $cfg.SequencesPath -ErrorAction SilentlyContinue) -and
                   (Get-ChildItem $cfg.SequencesPath -Filter '*.psd1' -ErrorAction SilentlyContinue).Count -gt 0

    Write-Host "  [1] Profil preconfigure" -ForegroundColor White
    Write-Host "      Utilise un profil JSON (apps, domaine, scripts predefinis)" -ForegroundColor DarkGray
    if ($hasProfiles) {
        Write-Host "      $(@($profiles).Count) profil(s) disponible(s)" -ForegroundColor Green
    } else {
        Write-Host "      Aucun profil trouve dans $($cfg.ProfilesPath)" -ForegroundColor Yellow
    }
    Write-Host ""

    Write-Host "  [2] Sequence existante" -ForegroundColor White
    Write-Host "      Pointe directement vers un fichier .json" -ForegroundColor DarkGray
    if ($hasSeqs) {
        $seqCount = (Get-ChildItem $cfg.SequencesPath -Filter '*.psd1' -ErrorAction SilentlyContinue).Count
        Write-Host "      $seqCount sequence(s) disponible(s)" -ForegroundColor Green
    } else {
        Write-Host "      Chemin a saisir manuellement" -ForegroundColor DarkGray
    }
    Write-Host ""

    Write-Host "  [3] From scratch (sans profil ni sequence)" -ForegroundColor White
    Write-Host "      Construit la sequence pas a pas" -ForegroundColor DarkGray
    Write-Host "      OS + domaine (oui/non) + apps + scripts" -ForegroundColor DarkGray
    Write-Host ""

    $modeChoice = Read-Choice "Choisir le mode" -Max 3
    $Mode = switch ($modeChoice) { 1{'Profile'}; 2{'Sequence'}; 3{'Scratch'} }
}

Write-OK "Mode : $Mode"

# ---------------------------------------------------------------------------
# VARIABLES COMMUNES (remplies selon le mode)
# ---------------------------------------------------------------------------

$selectedProf   = $null
$selectedAppIds = [System.Collections.Generic.List[string]]::new()
$scratchParams  = [PSCustomObject]@{
    Domain         = $null
    InstallUpdates = $false
    Apps           = @()
    Scripts        = @()
    LocalAdminPass = $null
}  # Parametres construits en mode Scratch

# ---------------------------------------------------------------------------
# MODE 1 : PROFIL
# ---------------------------------------------------------------------------

if ($Mode -eq 'Profile') {
    Write-Header "Profil de deploiement"

    $profiles = Get-Profiles -ProfilesPath $cfg.ProfilesPath
    if ($useApi) {
        try { $r = Invoke-DeployAPI -BaseUrl $ApiUrl -Endpoint 'profiles'; if ($r.data) { $profiles = $r.data } }
        catch {}
    }

    if (@($profiles).Count -eq 0) {
        Write-Warn "Aucun profil disponible."
        Write-Info "Basculement automatique en mode From Scratch."
        $Mode = 'Scratch'
    } else {
        for ($i=0;$i -lt @($profiles).Count;$i++) {
            $p = $profiles[$i]
            $dom = if ($p.overrides -and $p.overrides.'metadata.domain') {
                       "  [Domaine: $($p.overrides.'metadata.domain')]"
                   } else { "  [Standalone]" }
            $reqApps = if ($p.requiredApps) { $p.requiredApps.Count } else { 0 }
            $defApps = if ($p.defaultApps)  { $p.defaultApps.Count  } else { 0 }
            Write-Host "  [$($i+1)] $($p.name)$dom" -ForegroundColor White
            Write-Host "       $($p.description)" -ForegroundColor DarkGray
            Write-Host "       $reqApps obligatoire(s)  $defApps par defaut" -ForegroundColor DarkGray
            Write-Host ""
        }
        $selectedProf = $profiles[(Read-Choice "Choisir le profil" -Max @($profiles).Count) - 1]
        Write-OK "Profil : $($selectedProf.name)"

        # Apps depuis le profil
        $cat = Get-AppCatalogue -CataloguePath $cfg.CataloguePath
        $reqIds = @(if ($selectedProf.requiredApps) { $selectedProf.requiredApps })
        $defIds = @(if ($selectedProf.defaultApps)  { $selectedProf.defaultApps  })
        $reqIds | ForEach-Object { $selectedAppIds.Add($_) }
        $defIds | Where-Object { $_ -notin $reqIds } | ForEach-Object { $selectedAppIds.Add($_) }

        # Afficher les apps et permettre modification
        Write-Header "Applications du profil"
        $reqApps = $cat | Where-Object { $_.id -in $reqIds }
        $optApps = @($cat | Where-Object { $_.id -notin $reqIds -and $_.type -eq 'app' })
        if ($reqApps) {
            Write-Info "Obligatoires (non modifiables) :"
            $reqApps | ForEach-Object { Write-Host "    [*] $($_.name)" -ForegroundColor DarkYellow }
            Write-Host ""
        }
        if (@($optApps).Count -gt 0) {
            Write-Info "Optionnelles :"
            for ($i=0;$i -lt @($optApps).Count;$i++) {
                $app = $optApps[$i]
                $sel = if ($app.id -in $selectedAppIds) { '[X]' } else { '[ ]' }
                $defTag = if ($app.id -in $defIds) { ' (par defaut)' } else { '' }
                Write-Host "    [$($i+1)] $sel $($app.name)$defTag" -ForegroundColor Gray
            }
            Write-Host "    [0] Valider" -ForegroundColor DarkGray
            Write-Host ""
            $editing = $true
            while ($editing) {
                Write-Host "  [?]  Numero a activer/desactiver (0=valider) : " -ForegroundColor White -NoNewline
                $inp = (Read-Host).Trim().Trim('"').Trim("'").Trim()
                if ($inp -eq '0' -or [string]::IsNullOrWhiteSpace($inp)) { $editing=$false }
                elseif ($inp -match '^\d+$' -and [int]$inp -ge 1 -and [int]$inp -le @($optApps).Count) {
                    $app = $optApps[[int]$inp-1]
                    if ($selectedAppIds.Contains($app.id)) {
                        $selectedAppIds.Remove($app.id)
                        Write-Host "    [-] $($app.name)" -ForegroundColor DarkGray
                    } else { $selectedAppIds.Add($app.id); Write-Host "    [+] $($app.name)" -ForegroundColor Green }
                }
            }
        }
        Write-OK "$($selectedAppIds.Count) application(s) selectionnee(s)"
    }
}

# ---------------------------------------------------------------------------
# MODE 2 : SEQUENCE EXISTANTE
# ---------------------------------------------------------------------------

if ($Mode -eq 'Sequence') {
    Write-Header "Sequence de deploiement"

    $seqDir = $cfg.SequencesPath
    $seqs   = @()
    if (Test-Path $seqDir -ErrorAction SilentlyContinue) {
        $seqs = @(Get-ChildItem $seqDir -Filter '*.psd1' -ErrorAction SilentlyContinue)
    }

    if (@($seqs).Count -gt 0) {
        Write-Info "$(@($seqs).Count) sequence(s) disponible(s) :"
        for ($i=0;$i -lt @($seqs).Count;$i++) {
            try {
                $s = Get-Content $seqs[$i].FullName -Raw | ConvertFrom-Json
                Write-Host "    [$($i+1)] $($s.name) v$($s.version)  -- $($seqs[$i].Name)" -ForegroundColor White
            } catch {
                Write-Host "    [$($i+1)] $($seqs[$i].Name)" -ForegroundColor White
            }
        }
        Write-Host "    [0] Saisir un chemin manuellement" -ForegroundColor DarkGray
        Write-Host ""
        $c = Read-Choice "Choisir la sequence" -Max @($seqs).Count -AllowZero 1
        if ($c -eq 0) {
            $SequencePath = Read-Answer "Chemin vers le .json" -Required
        } else {
            $SequencePath = $seqs[$c-1].FullName
        }
    } else {
        Write-Warn "Aucune sequence dans $seqDir"
        $SequencePath = Read-Answer "Chemin complet vers le fichier .json" -Required
    }

    if (-not (Test-Path $SequencePath)) { throw "Sequence introuvable : $SequencePath" }
    Write-OK "Sequence : $SequencePath"
}

# ---------------------------------------------------------------------------
# MODE 3 : FROM SCRATCH
# ---------------------------------------------------------------------------

if ($Mode -eq 'Scratch') {
    Write-Header "Deploiement from scratch"
    Write-Info "Construction de la sequence pas a pas."
    Write-Info "Aucun profil ni fichier JSON requis."
    Write-Host ""

    # Domaine ?
    $joinDomain = Read-YesNo "Joindre un domaine Active Directory ?" $false
    if ($joinDomain) {
        $scratchParams.Domain    = Read-Answer "Nom du domaine (ex: corp.local)" -Required
        $scratchParams.OU        = Read-Answer "OU cible (laisser vide si racine)" -Default ''
        $scratchParams.DomainUser= Read-Answer "Compte de jonction (ex: svc-joindomain)" -Default 'svc-joindomain'
        Write-Host "  [?]  Mot de passe du compte de jonction : " -ForegroundColor White -NoNewline
        $sp = Read-Host -AsSecureString
        $scratchParams.DomainPass = [Runtime.InteropServices.Marshal]::PtrToStringAuto(
            [Runtime.InteropServices.Marshal]::SecureStringToBSTR($sp))
    }

    # Mises a jour ?
    $scratchParams.InstallUpdates = Read-YesNo "Installer les mises a jour Windows ?" $false

    # Applications depuis le catalogue
    $cat = Get-AppCatalogue -CataloguePath $cfg.CataloguePath
    if (@($cat).Count -gt 0) {
        Write-Header "Applications disponibles"
        $apps = @($cat | Where-Object { $_.type -eq 'app' })
        for ($i=0;$i -lt @($apps).Count;$i++) {
            Write-Host "    [$($i+1)] [ ] $($apps[$i].name)  -- $($apps[$i].description)" -ForegroundColor Gray
        }
        Write-Host "    [0] Aucune application" -ForegroundColor DarkGray
        Write-Host ""
        $editing = $true
        while ($editing) {
            Write-Host "  [?]  Numero a ajouter (0=valider) : " -ForegroundColor White -NoNewline
            $inp = (Read-Host).Trim().Trim('"').Trim("'").Trim()
            if ($inp -eq '0' -or [string]::IsNullOrWhiteSpace($inp)) { $editing=$false }
            elseif ($inp -match '^\d+$' -and [int]$inp -ge 1 -and [int]$inp -le @($apps).Count) {
                $app = $apps[[int]$inp-1]
                if ($selectedAppIds.Contains($app.id)) {
                    $selectedAppIds.Remove($app.id)
                    Write-Host "    [-] $($app.name)" -ForegroundColor DarkGray
                } else { $selectedAppIds.Add($app.id); Write-Host "    [+] $($app.name)" -ForegroundColor Green }
            }
        }
    } else {
        Write-Info "Catalogue non disponible -- pas d'applications"
    }

    # Scripts
    $scripts = @($cat | Where-Object { $_.type -eq 'script' })
    if (@($scripts).Count -gt 0) {
        if (Read-YesNo "Executer des scripts post-deploiement ?" $false) {
            for ($i=0;$i -lt @($scripts).Count;$i++) {
                Write-Host "    [$($i+1)] [ ] $($scripts[$i].name)" -ForegroundColor Gray
            }
            Write-Host "    [0] Aucun script" -ForegroundColor DarkGray
            $scratchScripts = [System.Collections.Generic.List[string]]::new()
            $editing = $true
            while ($editing) {
                Write-Host "  [?]  Numero (0=valider) : " -ForegroundColor White -NoNewline
                $inp = (Read-Host).Trim().Trim('"').Trim("'").Trim()
                if ($inp -eq '0' -or [string]::IsNullOrWhiteSpace($inp)) { $editing=$false }
                elseif ($inp -match '^\d+$' -and [int]$inp -ge 1 -and [int]$inp -le @($scripts).Count) {
                    $s = $scripts[[int]$inp-1]
                    if ($scratchScripts.Contains($s.id)) { $scratchScripts.Remove($s.id) }
                    else { $scratchScripts.Add($s.id); Write-Host "    [+] $($s.name)" -ForegroundColor Green }
                }
            }
            $scratchParams.Scripts = $scratchScripts
        }
    }

    # Mot de passe admin local
    Write-Host ""
    if (Read-YesNo "Definir le mot de passe administrateur local ?" $true) {
        Write-Host "  [?]  Mot de passe admin local : " -ForegroundColor White -NoNewline
        $sp = Read-Host -AsSecureString
        $scratchParams.LocalAdminPass = [Runtime.InteropServices.Marshal]::PtrToStringAuto(
            [Runtime.InteropServices.Marshal]::SecureStringToBSTR($sp))
    }

    Write-OK "Parametres from scratch collectes"
    Write-Host "  Domaine     : $(if($scratchParams.Domain -ne $null -and $scratchParams.Domain -ne ''){$scratchParams.Domain}else{'(standalone)'})" -ForegroundColor Gray
    Write-Host "  MAJ Windows : $($scratchParams.InstallUpdates)" -ForegroundColor Gray
    Write-Host "  Apps        : $($selectedAppIds.Count) selectionnee(s)" -ForegroundColor Gray
    if ($scratchParams.Scripts -and $scratchParams.Scripts.Count -gt 0) {
        Write-Host "  Scripts     : $($scratchParams.Scripts.Count) selectionne(s)" -ForegroundColor Gray
    }
}

# ---------------------------------------------------------------------------
# ETAPES COMMUNES : OS + DISQUE + FIRMWARE
# ---------------------------------------------------------------------------

Write-Header "Image Windows"
Write-Step "Lecture du catalogue OS depuis $($cfg.ImageShare)..."
$availableOS = @(Get-AvailableOS -ImageShare $cfg.ImageShare)

if (@($availableOS).Count -eq 0) {
    Write-Err "Aucune image WIM disponible dans $($cfg.ImageShare)."
    Write-Info "Utiliser Export-WIMImage.ps1 pour ajouter des images au partage."
    exit 1
}

# Afficher les images disponibles
for ($i=0;$i -lt @($availableOS).Count;$i++) {
    $os = $availableOS[$i]
    $b  = if ($os.Build)    { "  Build $($os.Build)"   } else { '' }
    $l  = if ($os.Language) { "  [$($os.Language)]"    } else { '' }
    $dn = if ($os.DisplayName) { $os.DisplayName } else { $os.FileName }
    Write-Host "  [$($i+1)] $dn$b$l" -ForegroundColor White
    Write-Host "       $($os.FileName)" -ForegroundColor DarkGray
    Write-Host ""
}

# Selectionner l'image a utiliser pour cette sequence
# Le WinPE utilisera cette image specifique -- pas de choix au boot
$osIdx = (Read-Choice "Choisir l'image OS pour cette sequence" -Max @($availableOS).Count) - 1
$selectedOS = $availableOS[$osIdx]
$selectedOSName = if ($selectedOS.DisplayName) { $selectedOS.DisplayName } else { $selectedOS.FileName }
Write-OK "Image selectionnee : $selectedOSName"

# Disque cible : -1 = auto-selection au boot WinPE (recommande)
# L'operateur choisira le disque au moment du deploiement, pas maintenant
$diskNumber = -1
Write-Info "Disque cible : selection automatique au boot WinPE"
Write-Info "(L'operateur choisira le disque physique au moment du deploiement)"

try {
    $fwType    = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control' `
                  -Name PEFirmwareType -ErrorAction SilentlyContinue).PEFirmwareType
    $firmware  = if ($fwType -eq 1) { 'BIOS' } else { 'UEFI' }
    Write-OK "Firmware detecte : $firmware"
} catch {
    $firmware = Read-Answer "Firmware [UEFI/BIOS]" -Default 'UEFI'
}

# ---------------------------------------------------------------------------
# CONFIRMATION
# ---------------------------------------------------------------------------

Write-Header "Recapitulatif"

Write-Host "  Mode        : $Mode" -ForegroundColor White
if ($selectedProf) {
    Write-Host "  Profil      : $($selectedProf.name)" -ForegroundColor White
}
if ($Mode -eq 'Scratch') {
    Write-Host "  Domaine     : $(if($scratchParams.Domain){$scratchParams.Domain}else{'Standalone'})" -ForegroundColor White
    Write-Host "  MAJ Windows : $($scratchParams.InstallUpdates)" -ForegroundColor White
}
if ($SequencePath) {
    Write-Host "  Sequence    : $SequencePath" -ForegroundColor White
}
Write-Host "  Image OS    : $selectedOSName" -ForegroundColor White
Write-Host "  Disque      : $diskNumber  --  Firmware : $firmware" -ForegroundColor White
Write-Host "  Apps        : $($selectedAppIds.Count)" -ForegroundColor White
Write-Host ""
Write-Host "  +--------------------------------------------------+" -ForegroundColor Red
Write-Host "  | Disque $diskNumber SERA ENTIEREMENT EFFACE                |" -ForegroundColor Red
Write-Host "  +--------------------------------------------------+" -ForegroundColor Red
Write-Host ""

if (-not (Read-YesNo "CONFIRMER le deploiement ?" $false)) {
    Write-Warn "Deploiement annule."
    exit 0
}

# ---------------------------------------------------------------------------
# CONSTRUCTION DE LA SEQUENCE RUNTIME
# ---------------------------------------------------------------------------

Write-Header "Preparation"

$runtimeDir = if ($cfg.RuntimePath -and (Test-Path $cfg.RuntimePath -EA SilentlyContinue)) {
                  $cfg.RuntimePath
              } else { $env:TEMP }
$runtimePath = Join-Path $runtimeDir "seq-$(Get-Date -Format 'yyyyMMddHHmmss').psd1"

if ($Mode -eq 'Scratch') {
    # Construire la sequence depuis zero
    $steps = [System.Collections.Generic.List[PSCustomObject]]::new()

    $steps.Add([PSCustomObject]@{ id='s01'; type='FormatDisk'; name='Partition disque'; enabled=$true; rebootAfter='Never'
        params=[PSCustomObject]@{ diskNumber=$diskNumber; firmwareType=$firmware } })

    $steps.Add([PSCustomObject]@{ id='s02'; type='ApplyWIM'; name='Appliquer Windows'; enabled=$true; rebootAfter='Never'
        params=[PSCustomObject]@{ wimPath=$(if($selectedOS.FilePath){$selectedOS.FilePath}else{''}); index=1; targetDrive='W:\' } })

    $steps.Add([PSCustomObject]@{ id='s03'; type='SetLocale'; name='Langue et timezone'; enabled=$true; rebootAfter='Never'
        params=[PSCustomObject]@{ locale='fr-FR'; timezone='Romance Standard Time'; targetDrive='W:\' } })

    $steps.Add([PSCustomObject]@{ id='s04'; type='WaitForNetwork'; name='Attente reseau'; enabled=$true; rebootAfter='Never'
        params=[PSCustomObject]@{ timeoutSec=60 } })

    if ($scratchParams.Domain) {
        $steps.Add([PSCustomObject]@{ id='s05'; type='JoinDomain'; name='Jonction domaine'; enabled=$true; rebootAfter='Always'
            params=[PSCustomObject]@{
                domain   = $scratchParams.Domain
                ou       = $scratchParams.OU
                username = $scratchParams.DomainUser
                credential = [PSCustomObject]@{ source='plain'; key=$scratchParams.DomainPass }
            }
        })
    }

    if ($scratchParams.InstallUpdates) {
        $steps.Add([PSCustomObject]@{ id='s06'; type='InstallUpdates'; name='Mises a jour'; enabled=$true; continueOnError=$true; rebootAfter='IfRequired'
            params=[PSCustomObject]@{ categories=@('Security','Critical') } })
    }

    if ($selectedAppIds.Count -gt 0) {
        $cat = Get-AppCatalogue -CataloguePath $cfg.CataloguePath
        $pkgs = $cat | Where-Object { $_.id -in $selectedAppIds } | ForEach-Object {
            [PSCustomObject]@{ name=$_.name; installer=$_.installer; args=$_.args; continueOnError=$true }
        }
        $steps.Add([PSCustomObject]@{ id='s07'; type='InstallSoftware'; name='Installation apps'; enabled=$true; rebootAfter='IfRequired'
            params=[PSCustomObject]@{ source=$cfg.SoftwareShare; packages=@($pkgs) } })
    }

    if ($scratchParams.Scripts) {
        $cat = Get-AppCatalogue -CataloguePath $cfg.CataloguePath
        $sIdx = 8
        foreach ($sid in $scratchParams.Scripts) {
            $scriptDef = @($cat | Where-Object { $_.id -eq $sid } | Select-Object -First 1)
            if ($scriptDef) {
                $steps.Add([PSCustomObject]@{ id="s0$sIdx"; type='RunScript'; name=$scriptDef.name; enabled=$true; continueOnError=$true; rebootAfter='Never'
                    params=[PSCustomObject]@{ path=$scriptDef.path; shell='PowerShell'; args=$scriptDef.args } })
                $sIdx++
            }
        }
    }

    $seq = [PSCustomObject]@{
        id       = "scratch-$(Get-Date -Format 'yyyyMMddHHmmss')"
        name     = "Deploiement from scratch"
        version  = '1.0.0'
        metadata = [PSCustomObject]@{ locale='fr-FR'; timezone='Romance Standard Time' }
        options  = [PSCustomObject]@{ continueOnError=$false; logLevel='Info' }
        steps    = $steps.ToArray()
    }
    Save-Psd1 -Data $seq -Path $runtimePath -Comment "PSWinDeploy Sequence"
    Write-OK "Sequence from scratch : $($steps.Count) steps"

} elseif ($Mode -eq 'Profile') {
    # Via API si disponible
    if ($useApi) {
        try {
            $prep = Invoke-DeployAPI -BaseUrl $ApiUrl -Endpoint 'deploy/prepare' -Method POST -Body @{
                profileId    = $selectedProf.id
                selectedApps = @($selectedAppIds)
                wimPath      = $selectedOS.FilePath
                diskNumber   = $diskNumber
                firmwareType = $firmware
            }
            if ($prep.success) {
                $runtimePath = $prep.runtimePath
                Write-OK "Sequence preparee par API : $runtimePath"
            } else { throw $prep.error }
        } catch {
            Write-Warn "API : $_ -- mode direct"
            $useApi = $false
        }
    }
    if (-not $useApi) {
        # Charger la sequence du profil et patcher
        $seqSrc = if ($selectedProf.sequencePath -and (Test-Path $selectedProf.sequencePath)) {
                      $selectedProf.sequencePath
                  } else {
                      $(($f = Get-ChildItem $cfg.SequencesPath -Filter '*.psd1' -EA SilentlyContinue | Select-Object -First 1); if ($f) { $f.FullName })
                  }
        if (-not $seqSrc) { throw "Aucune sequence trouvee pour le profil $($selectedProf.name)" }
        $seq = if ($seqSrc -match '\.psd1$') { [PSCustomObject](Import-PowerShellDataFile $seqSrc) } else { Get-Content $seqSrc -Raw | ConvertFrom-Json }
        foreach ($step in $seq.steps) {
            if ($step.type -eq 'FormatDisk') { $step.params.diskNumber=$diskNumber; $step.params.firmwareType=$firmware }
            if ($step.type -eq 'ApplyWIM')   { $step.params.wimPath=$selectedOS.FilePath; $step.params.index=1 }
        }
        Save-AssistantPsd1 -Data $seq -Path $runtimePath
        Write-OK "Sequence profil patchee : $runtimePath"
    }

} else {
    # Mode Sequence : juste patcher les params disque/WIM
    $seq = if ($SequencePath -match '\.psd1$') { [PSCustomObject](Import-PowerShellDataFile $SequencePath) } else { Get-Content $SequencePath -Raw | ConvertFrom-Json }
    foreach ($step in $seq.steps) {
        if ($step.type -eq 'FormatDisk') { $step.params.diskNumber=$diskNumber; $step.params.firmwareType=$firmware }
        if ($step.type -eq 'ApplyWIM')   { $step.params.wimPath=$selectedOS.FilePath }
    }
    Save-AssistantPsd1 -Data $seq -Path $runtimePath
    Write-OK "Sequence patchee : $runtimePath"
}

# ---------------------------------------------------------------------------
# SAUVEGARDE FINALE + INSTRUCTIONS
# ---------------------------------------------------------------------------

Write-Header "Sequence prete"

# Copier aussi dans \Deploy\Sequences pour que le WinPE la trouve automatiquement
$seqShareDir = $null
try {
    $deployShare = $cfg.DeployShare
    if ($deployShare) {
        $seqShareDir = Join-Path $deployShare 'Sequences'
        if (-not (Test-Path $seqShareDir)) { New-Item -ItemType Directory $seqShareDir -Force | Out-Null }
        $seqSharePath = Join-Path $seqShareDir (Split-Path $runtimePath -Leaf)
        Copy-Item $runtimePath $seqSharePath -Force
        Write-OK "Sequence copiee sur le partage : $seqSharePath"
    }
} catch {
    Write-Warn "Copie sur partage echouee : $_ (sequence disponible localement)"
}

Write-OK "Sequence sauvegardee : $runtimePath"
Write-Host ""
Write-Host "  Pour deployer cette sequence :" -ForegroundColor Cyan
Write-Host "  1. Booter la machine cible sur le WinPE PSWinDeploy" -ForegroundColor Gray
Write-Host "  2. La sequence apparaitra automatiquement dans la liste" -ForegroundColor Gray
Write-Host "  3. Choisir le disque cible au boot" -ForegroundColor Gray
Write-Host ""
if ($seqShareDir) {
    Write-Info "Chemin partage : $seqShareDir"
}
Write-Host ""
