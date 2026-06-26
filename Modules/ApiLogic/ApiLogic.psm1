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
    CataloguePath = ''     # \\srv\...\catalogue.psd1 ou local
    ScriptShare   = ''     # \\srv\Scripts (scripts de sequence)
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

function Initialize-ApiLogicFromProject {
    <#
    .SYNOPSIS Initialise la logique API a partir du ProjectRoot : lit la config
        PSWinDeploy.psd1, resout les partages (DNS/IP) et configure les chemins.
        Concentre toute la logique ici (appelable depuis Pode sans scriptblock).
    #>
    param([string]$ProjectRoot)

    # Defensif : si le ProjectRoot n'est pas fourni (State Pode pas encore pret),
    # on ne plante pas -- on laisse la config avec des chemins vides (les
    # fonctions retourneront des listes vides au lieu de crasher).
    if ([string]::IsNullOrWhiteSpace($ProjectRoot)) { return }

    $cfg = $null
    $cfgPath = Join-Path $ProjectRoot 'PSWinDeploy.psd1'
    if (Test-Path $cfgPath -EA SilentlyContinue) {
        try { $cfg = Import-PowerShellDataFile $cfgPath -EA Stop } catch {}
    }

    # Helper local : resout une valeur de chemin.
    #  - PRIORITE aux chemins LOCAUX de la section ApiPaths (API sur le serveur).
    #  - Sinon, valeur du partage : si @{DNS;IP} -> on prend DNS, sinon string.
    #  - $fallback si rien.
    $apiPaths = $null
    if ($cfg -and $cfg.ContainsKey('ApiPaths') -and ($cfg['ApiPaths'] -is [hashtable])) {
        $apiPaths = $cfg['ApiPaths']
    }
    $resolvePath = {
        param($Key, $Fallback)
        # 1) chemin local explicite (ApiPaths) -> priorite absolue
        if ($apiPaths -and $apiPaths.ContainsKey($Key) -and -not [string]::IsNullOrWhiteSpace("$($apiPaths[$Key])")) {
            return "$($apiPaths[$Key])"
        }
        # 2) valeur du partage dans la config racine (UNC, eventuellement @{DNS;IP})
        if ($cfg -and $cfg.ContainsKey($Key)) {
            $v = $cfg[$Key]
            if ($v -is [hashtable]) { if ($v.ContainsKey('DNS')) { return "$($v['DNS'])" } }
            elseif (-not [string]::IsNullOrWhiteSpace("$v")) { return "$v" }
        }
        return $Fallback
    }

    $seqPath  = & $resolvePath 'SequencesPath' ''
    $drvShare = & $resolvePath 'DriverShare'   ''
    $scrShare = & $resolvePath 'ScriptShare'   ''
    # Catalogue : priorite ApiPaths, sinon config CataloguePath (UNC), sinon local.
    $catPath  = & $resolvePath 'CataloguePath' (Join-Path $ProjectRoot 'Catalogue\catalogue.psd1')

    Initialize-ApiLogic -Config @{
        ProjectRoot   = $ProjectRoot
        SequencesPath = $seqPath
        DriverShare   = $drvShare
        ScriptShare   = $scrShare
        CataloguePath = $catPath
    }
}

# ===========================================================================
#  CATALOGUE (synchro JSON <-> PSD1)
# ===========================================================================
function Read-TextFileSafe {
    <# .SYNOPSIS Lit un fichier texte de facon ROBUSTE : ouverture en lecture
        partagee (n'echoue pas si le fichier est ouvert ailleurs), detection
        d'encodage (BOM), sans pipeline PowerShell. Retourne le texte ou un
        message d'erreur lisible (jamais d'exception qui remonte en 500). #>
    param([Parameter(Mandatory)][string]$Path)
    try {
        $fs = [System.IO.FileStream]::new($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
        try {
            $sr = [System.IO.StreamReader]::new($fs, [System.Text.Encoding]::UTF8, $true)
            try { return $sr.ReadToEnd() }
            finally { $sr.Dispose() }
        } finally { $fs.Dispose() }
    } catch {
        return "(lecture impossible : $($_.Exception.Message))"
    }
}

function Get-CataloguePath {
    <# .SYNOPSIS Retourne le chemin du catalogue actuellement resolu (diagnostic). #>
    $path = $script:ApiConfig.CataloguePath
    if (-not $path) { $path = Join-Path $script:ApiConfig.ProjectRoot 'Catalogue\catalogue.psd1' }
    return $path
}

function Get-AppCatalogue {
    <# .SYNOPSIS Lit le catalogue d'applications (PSD1) et retourne la liste d'apps. #>
    $path = Get-CataloguePath
    $data = ConvertFrom-Psd1File -Path $path
    if (-not $data) { return @() }
    $apps = if ($data.ContainsKey('Applications')) { $data['Applications'] } else { $data }
    return @($apps)
}

function Save-AppCatalogue {
    <# .SYNOPSIS Ecrit le catalogue (depuis une liste d'apps) en PSD1 avec BOM.
        PRESERVE la structure existante : si le fichier actuel a une cle
        'Applications', on garde @{Applications=@(...)} ; sinon on ecrit la liste
        directement. Ainsi le format reste celui que le deploiement attend. #>
    param([Parameter(Mandatory)]$Apps)
    $path = $script:ApiConfig.CataloguePath
    if (-not $path) { $path = Join-Path $script:ApiConfig.ProjectRoot 'Catalogue\catalogue.psd1' }

    # Determiner la structure existante pour la conserver.
    $wrapInApplications = $true   # defaut : @{ Applications = @(...) }
    $existing = ConvertFrom-Psd1File -Path $path
    if ($existing) {
        if ($existing -is [hashtable] -and $existing.ContainsKey('Applications')) {
            $wrapInApplications = $true
        } elseif ($existing -is [System.Array] -or ($existing -is [System.Collections.IEnumerable] -and $existing -isnot [string] -and $existing -isnot [hashtable])) {
            # Le fichier actuel est une LISTE directe d'apps -> on garde ce format.
            $wrapInApplications = $false
        }
    }

    if ($wrapInApplications) {
        $obj = @{ Applications = @($Apps) }
    } else {
        $obj = @($Apps)
    }
    Save-Psd1File -Object $obj -Path $path | Out-Null
    return $path
}

function Add-AppToCatalogue {
    <#
    .SYNOPSIS Ajoute UNE application au catalogue, ou la MET A JOUR si une app
        du meme Name existe deja (fusion, pas ecrasement du catalogue entier).
    .PARAMETER App  hashtable de l'app (doit avoir au moins Name).
    .OUTPUTS hashtable : @{ path; count; updated=$true/$false }
    #>
    param([Parameter(Mandatory)][hashtable]$App)

    $name = "$($App['Name'])"
    if ([string]::IsNullOrWhiteSpace($name)) { throw "L'application doit avoir un 'Name'." }

    # Lire l'existant et fusionner.
    $apps = @(Get-AppCatalogue)
    $found = $false
    $merged = @()
    foreach ($a in $apps) {
        $aName = ''
        if ($a -is [hashtable]) { if ($a.ContainsKey('Name')) { $aName = "$($a['Name'])" } }
        elseif ($a.PSObject.Properties['Name']) { $aName = "$($a.Name)" }

        if ($aName -ieq $name) {
            # Remplacer l'app existante par la nouvelle version.
            $merged += $App
            $found = $true
        } else {
            $merged += $a
        }
    }
    if (-not $found) { $merged += $App }   # nouvelle app -> on l'ajoute

    $path = Save-AppCatalogue -Apps $merged
    return @{ path = $path; count = @($merged).Count; updated = $found }
}

function Remove-AppFromCatalogue {
    <#
    .SYNOPSIS Retire une application du catalogue par son Name.
    .OUTPUTS hashtable : @{ path; count; removed=$true/$false }
    #>
    param([Parameter(Mandatory)][string]$Name)
    if ([string]::IsNullOrWhiteSpace($Name)) { throw "Name requis." }

    $apps = @(Get-AppCatalogue)
    $kept = @()
    $removed = $false
    foreach ($a in $apps) {
        $aName = ''
        if ($a -is [hashtable]) { if ($a.ContainsKey('Name')) { $aName = "$($a['Name'])" } }
        elseif ($a.PSObject.Properties['Name']) { $aName = "$($a.Name)" }

        if ($aName -ieq $Name) { $removed = $true }   # on saute (= on retire)
        else { $kept += $a }
    }
    $path = Save-AppCatalogue -Apps $kept
    return @{ path = $path; count = @($kept).Count; removed = $removed }
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

function Save-SequenceTemplate {
    <# .SYNOPSIS Genere une sequence TEMPLATE a la racine du dossier Sequences
        (au meme niveau que by-name/ et by-mac/). Reutilisable directement en P2
        via le choix de l'assistant sur le poste. #>
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)]$Sequence
    )
    # Nettoyer le nom (pas de separateurs de chemin).
    $safe = ($Name -replace '[\\/:*?"<>|]', '_').Trim()
    if ([string]::IsNullOrWhiteSpace($safe)) { throw "Nom de template invalide." }
    $root = $script:ApiConfig.SequencesPath
    if (-not $root) { throw "SequencesPath non configure." }
    if (-not (Test-Path $root -EA SilentlyContinue)) { New-Item -ItemType Directory $root -Force -EA SilentlyContinue | Out-Null }
    $path = Join-Path $root "$safe.psd1"
    Save-Psd1File -Object $Sequence -Path $path | Out-Null
    return $path
}

function Get-SequenceContent {
    <# .SYNOPSIS Lit le contenu BRUT d'une sequence (pour affichage lecture seule
        dans l'UI). Securise : n'autorise que les .psd1 SOUS le dossier Sequences
        (anti-traversee de chemin). Type = template|by-name|by-mac. #>
    param(
        [Parameter(Mandatory)][string]$Type,
        [Parameter(Mandatory)][string]$Name
    )
    $root = $script:ApiConfig.SequencesPath
    if (-not $root) { return $null }
    $safe = ($Name -replace '[\\/:*?"<>|]', '_')
    switch ($Type) {
        'by-name' { $dir = Join-Path $root 'by-name' }
        'by-mac'  { $dir = Join-Path $root 'by-mac' }
        default   { $dir = $root }   # template a la racine
    }
    $path = Join-Path $dir "$safe.psd1"
    # Securite anti-traversee : le nom est deja nettoye ($safe), donc le fichier
    # est forcement dans $dir. On evite Resolve-Path (couteux sur UNC).
    $item = Get-Item -LiteralPath $path -EA SilentlyContinue
    if (-not $item) { return $null }
    # DOIT etre un fichier (pas un dossier) -- sinon Get-Content boucle/bloque.
    if ($item.PSIsContainer) { return $null }
    if ($item.Length -gt 1MB) { return "(fichier trop volumineux pour l'affichage : $([math]::Round($item.Length/1KB)) Ko)" }
    return (Read-TextFileSafe -Path $item.FullName)
}

function Get-SequenceObject {
    <# .SYNOPSIS Lit une sequence et la retourne en OBJET (hashtable), pas en
        texte. Pode la serialisera en JSON pour le front (qui peut alors la
        charger dans l'editeur). Memes garde-fous de chemin que Get-SequenceContent. #>
    param(
        [Parameter(Mandatory)][string]$Type,
        [Parameter(Mandatory)][string]$Name
    )
    $root = $script:ApiConfig.SequencesPath
    if (-not $root) { return $null }
    $safe = ($Name -replace '[\\/:*?"<>|]', '_')
    switch ($Type) {
        'by-name' { $dir = Join-Path $root 'by-name' }
        'by-mac'  { $dir = Join-Path $root 'by-mac' }
        default   { $dir = $root }
    }
    $path = Join-Path $dir "$safe.psd1"
    $item = Get-Item -LiteralPath $path -EA SilentlyContinue
    if (-not $item) { return $null }
    if ($item.Length -gt 1MB) { return $null }
    return (ConvertFrom-Psd1File -Path $path)
}

function Get-ScriptShareDebug {
    <# .SYNOPSIS Retourne le ScriptShare resolu (diagnostic). #>
    return $script:ApiConfig.ScriptShare
}

function Get-ScriptContent {
    <# .SYNOPSIS Lit le contenu BRUT d'un script .ps1 du partage Scripts (lecture
        seule UI). Securise : seulement les .ps1 SOUS ScriptShare. #>
    param([Parameter(Mandatory)][string]$RelativePath)
    $root = $script:ApiConfig.ScriptShare
    if (-not $root) { return $null }
    # Refuser toute tentative de remontee.
    if ($RelativePath -match '\.\.') { return $null }
    # Normaliser : retirer un eventuel separateur initial (sinon Join-Path
    # traite le chemin comme absolu et la jointure echoue) ; uniformiser les /.
    $relClean = $RelativePath.TrimStart([char]0x5C, [char]0x2F).Replace([char]0x2F, [char]0x5C)
    if ([System.IO.Path]::GetExtension($relClean) -ne '.ps1') { return $null }
    $path = Join-Path $root $relClean
    $item = Get-Item -LiteralPath $path -EA SilentlyContinue
    if (-not $item -or $item.PSIsContainer) { return $null }
    if ($item.Length -gt 1MB) { return "(fichier trop volumineux pour l'affichage : $([math]::Round($item.Length/1KB)) Ko)" }
    return (Read-TextFileSafe -Path $item.FullName)
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
        # Compter les .inf avec une profondeur BORNEE (-Depth) : meme si le
        # dossier contient une jonction cyclique, la descente s'arrete et ne
        # boucle pas a l'infini.
        $infCount = @(Get-ChildItem $d.FullName -Filter '*.inf' -Recurse -Depth 6 -EA SilentlyContinue).Count
        $result += [PSCustomObject]@{
            Name     = $d.Name
            InfCount = $infCount
            Path     = $d.FullName
        }
    }
    return $result
}

function Get-ScriptList {
    <# .SYNOPSIS Liste les scripts .ps1 du partage Scripts. Pour que l'interface
        web les propose dans l'editeur (type RunScript). Parcours recursif BORNE
        et SANS suivre les liens symboliques/jonctions (anti-boucle infinie sur
        les partages avec des jonctions cycliques). #>
    $root = $script:ApiConfig.ScriptShare
    $result = @()
    if (-not $root -or -not (Test-Path $root -EA SilentlyContinue)) { return $result }

    # Normaliser le root (chemin complet, sans backslash final) pour calculer
    # des chemins relatifs fiables.
    $rootFull = (Resolve-Path $root -EA SilentlyContinue).Path
    if (-not $rootFull) { return $result }
    $rootTrim = $rootFull.TrimEnd([char]0x5C)

    # Parcours en LARGEUR avec une file, profondeur bornee, en IGNORANT les
    # ReparsePoint (liens/jonctions) -> impossible de boucler a l'infini.
    $maxDepth = 8
    $queue = [System.Collections.Generic.Queue[object]]::new()
    $queue.Enqueue([PSCustomObject]@{ Dir = $rootTrim; Depth = 0 })

    while ($queue.Count -gt 0) {
        $cur = $queue.Dequeue()
        # Fichiers .ps1 du dossier courant.
        foreach ($f in @(Get-ChildItem -LiteralPath $cur.Dir -Filter '*.ps1' -File -EA SilentlyContinue)) {
            $rel = $f.FullName
            if ($rel.Length -gt $rootTrim.Length) { $rel = $rel.Substring($rootTrim.Length).TrimStart([char]0x5C) }
            $result += [PSCustomObject]@{ Name = $f.Name; RelativePath = $rel; FullPath = $f.FullName }
        }
        # Sous-dossiers (si on n'a pas atteint la profondeur max), en sautant les
        # points de reparse (jonctions/liens symboliques) qui peuvent boucler.
        if ($cur.Depth -lt $maxDepth) {
            foreach ($d in @(Get-ChildItem -LiteralPath $cur.Dir -Directory -EA SilentlyContinue)) {
                $isReparse = ($d.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -eq [System.IO.FileAttributes]::ReparsePoint
                if (-not $isReparse) {
                    $queue.Enqueue([PSCustomObject]@{ Dir = $d.FullName; Depth = ($cur.Depth + 1) })
                }
            }
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

    # IDENTIFIANT STABLE = la MAC. Elle est unique par machine et CONSTANTE de
    # la phase 1 (WinPE) a la phase 2 (Windows renomme). On NE se base PAS sur
    # le nom : en WinPE il vaut MINWINPC pour toutes les machines (collision),
    # et il change au renommage entre P1 et P2 (creerait deux deploiements).
    # Le nom est conserve comme simple attribut d'affichage.
    $mac = "$($Report['mac'])" -replace '[^A-Za-z0-9]', ''
    if ($mac) {
        $id = $mac
    } else {
        # Pas de MAC : repli sur le nom (hors WinPE), sinon identifiant aleatoire.
        $id = "$($Report['computerName'])"
        if (-not $id -or $id -eq 'MINWINPC') { $id = "unknown-$(Get-Random -Maximum 99999)" }
    }
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

function Get-DeployCompleted {
    <# .SYNOPSIS Parcourt l'historique et retourne la liste des deploiements
        TERMINES avec leur duree (du 1er au dernier evenement). Un deploiement
        est considere termine si son historique contient un evenement 'done'. #>
    $dir = $script:ApiConfig.HistoryPath
    $result = @()
    if (-not $dir -or -not (Test-Path $dir -EA SilentlyContinue)) { return $result }

    foreach ($f in @(Get-ChildItem $dir -Filter 'history-*.jsonl' -EA SilentlyContinue)) {
        $events = @()
        foreach ($line in @(Get-Content -LiteralPath $f.FullName -EA SilentlyContinue)) {
            if ([string]::IsNullOrWhiteSpace($line)) { continue }
            try { $events += ($line | ConvertFrom-Json) } catch {}
        }
        if ($events.Count -eq 0) { continue }

        $done = $events | Where-Object { "$($_.status)" -eq 'done' } | Select-Object -First 1
        $first = $events[0]
        $last  = $events[-1]
        $start = $null; $end = $null
        try { $start = [datetime]::Parse($first.timestamp) } catch {}
        try { $end   = [datetime]::Parse($last.timestamp) } catch {}
        $durationSec = $null
        if ($start -and $end) { $durationSec = [math]::Round(($end - $start).TotalSeconds) }

        # Nom affiche : le DERNIER nom reel connu (apres renommage en P2). On
        # ignore le nom generique WinPE 'MINWINPC'. Si jamais nomme, on retombe
        # sur la MAC.
        $displayName = ''
        for ($k = $events.Count - 1; $k -ge 0; $k--) {
            $cn = "$($events[$k].computerName)"
            if ($cn -and $cn -ne 'MINWINPC') { $displayName = $cn; break }
        }
        $macVal = "$($last.mac)"; if (-not $macVal) { $macVal = "$($first.mac)" }
        if (-not $displayName) { $displayName = $macVal }

        $result += [PSCustomObject]@{
            Id           = $f.BaseName -replace '^history-', ''
            ComputerName = $displayName
            Mac          = $macVal
            Status       = if ($done) { 'done' } else { "$($last.status)" }
            Completed    = [bool]$done
            Start        = if ($start) { $start.ToString('o') } else { $null }
            End          = if ($end) { $end.ToString('o') } else { $null }
            DurationSec  = $durationSec
            Events       = $events.Count
        }
    }
    return $result
}

function Get-DeployStats {
    <# .SYNOPSIS Agrege l'historique en statistiques : nombre de deploiements
        termines aujourd'hui / semaine / mois / annee, et duree moyenne. #>
    $all = @(Get-DeployCompleted) | Where-Object { $_.Completed }
    $now = Get-Date
    $today = $now.Date
    $weekStart = $today.AddDays( - [int](([int]$today.DayOfWeek + 6) % 7) )  # lundi
    $monthStart = Get-Date -Day 1 -Hour 0 -Minute 0 -Second 0
    $yearStart  = Get-Date -Month 1 -Day 1 -Hour 0 -Minute 0 -Second 0

    $cntDay = 0; $cntWeek = 0; $cntMonth = 0; $cntYear = 0; $cntTotal = 0
    $durations = @()
    foreach ($d in $all) {
        $cntTotal++
        if ($d.DurationSec -ne $null) { $durations += [double]$d.DurationSec }
        $end = $null
        try { $end = [datetime]::Parse($d.End) } catch { continue }
        if ($end -ge $today)      { $cntDay++ }
        if ($end -ge $weekStart)  { $cntWeek++ }
        if ($end -ge $monthStart) { $cntMonth++ }
        if ($end -ge $yearStart)  { $cntYear++ }
    }
    $avg = if ($durations.Count -gt 0) { [math]::Round(($durations | Measure-Object -Average).Average) } else { 0 }
    $min = if ($durations.Count -gt 0) { [math]::Round(($durations | Measure-Object -Minimum).Minimum) } else { 0 }
    $max = if ($durations.Count -gt 0) { [math]::Round(($durations | Measure-Object -Maximum).Maximum) } else { 0 }

    return [PSCustomObject]@{
        Today          = $cntDay
        Week           = $cntWeek
        Month          = $cntMonth
        Year           = $cntYear
        Total          = $cntTotal
        AvgDurationSec = $avg
        MinDurationSec = $min
        MaxDurationSec = $max
    }
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
    'Initialize-ApiLogicFromProject'
    'Get-ApiConfig'
    'Read-TextFileSafe'
    'Get-CataloguePath'
    'Get-AppCatalogue'
    'Save-AppCatalogue'
    'Add-AppToCatalogue'
    'Remove-AppFromCatalogue'
    'Format-MacAddress'
    'Save-SequenceByName'
    'Save-SequenceByMac'
    'Get-SequenceList'
    'Save-SequenceTemplate'
    'Get-SequenceContent'
    'Get-SequenceObject'
    'Get-ScriptContent'
    'Get-ScriptShareDebug'
    'Get-DriverModelList'
    'Get-ScriptList'
    'Write-DeployReport'
    'Get-DeployCurrentList'
    'Get-DeployHistory'
    'Get-DeployCompleted'
    'Get-DeployStats'
)
