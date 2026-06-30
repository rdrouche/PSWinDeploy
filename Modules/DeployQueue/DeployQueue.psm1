#Requires -Version 5.1
<#
.SYNOPSIS
    DeployQueue.psm1 -- File d'attente de sequences par poste (mode "waiting").
.DESCRIPTION
    Responsabilite UNIQUE : gerer, cote API, la file d'attente du mode pull
    interactif. Un poste en phase 2 peut s'annoncer "waiting" ; un operateur
    lui pousse alors une sequence depuis l'interface web ; le poste la recupere
    et la joue.

    Modele de donnees (un fichier JSON par poste, identifie par sa MAC) dans le
    dossier Queue :
        waiting-<id>.json   -> le poste est en attente (MAC, nom, since)
        pending-<id>.json   -> une sequence a ete poussee, prete a etre tiree

    Cycle de vie :
        Register-WaitingDeployment   (poste)      -> cree waiting-<id>.json
        Get-WaitingDeployments       (GUI)        -> liste les postes en attente
        Set-PendingSequence          (GUI)        -> cree pending-<id>.json
        Get-PendingSequence          (poste)      -> lit puis CONSOMME pending +
                                                      retire waiting (le poste part)
        Clear-WaitingDeployment      (GUI/poste)  -> annule (supprime waiting+pending)

    Ce module ne depend d'aucun autre : il recoit son dossier de travail via
    Initialize-DeployQueue. Les routes API restent fines et delegent ici.
#>

$script:QueueDir = ''

function Initialize-DeployQueue {
    <# .SYNOPSIS Definit (et cree) le dossier de la file d'attente. #>
    param([Parameter(Mandatory)][string]$Path)
    $script:QueueDir = $Path
    if (-not (Test-Path $Path -EA SilentlyContinue)) {
        New-Item -ItemType Directory $Path -Force -EA SilentlyContinue | Out-Null
    }
}

# Normalise un identifiant de poste (MAC) en cle de fichier sure.
function Get-QueueId {
    param([string]$Id)
    $clean = "$Id" -replace '[^A-Za-z0-9_-]', ''
    return $clean.ToUpper()
}

function Test-QueueReady {
    if (-not $script:QueueDir) { throw "DeployQueue non initialise (Initialize-DeployQueue)." }
}

function Register-WaitingDeployment {
    <# .SYNOPSIS Un poste s'annonce "waiting" d'une sequence. Idempotent :
        re-enregistrer met juste a jour 'lastSeen'. #>
    param(
        [Parameter(Mandatory)][string]$Id,
        [string]$ComputerName = '',
        [string]$Mac = ''
    )
    Test-QueueReady
    $qid = Get-QueueId $Id
    if (-not $qid) { return $null }
    $file = Join-Path $script:QueueDir "waiting-$qid.json"

    $since = (Get-Date).ToString('o')
    if (Test-Path $file -EA SilentlyContinue) {
        try { $since = (Get-Content $file -Raw -EA SilentlyContinue | ConvertFrom-Json).since } catch {}
    }
    $obj = [PSCustomObject]@{
        id           = $qid
        computerName = $ComputerName
        mac          = $Mac
        since        = $since
        lastSeen     = (Get-Date).ToString('o')
    }
    try { $obj | ConvertTo-Json | Set-Content -Path $file -Encoding UTF8 -EA Stop } catch {}
    return $obj
}

function Get-WaitingDeployments {
    <# .SYNOPSIS Liste les postes en attente (pour la GUI), avec l'info "une
        sequence a-t-elle deja ete poussee ?". #>
    Test-QueueReady
    $result = @()
    foreach ($f in @(Get-ChildItem $script:QueueDir -Filter 'waiting-*.json' -EA SilentlyContinue)) {
        try {
            $o = Get-Content $f.FullName -Raw -EA Stop | ConvertFrom-Json
            $qid = $f.BaseName -replace '^waiting-', ''
            $hasPending = Test-Path (Join-Path $script:QueueDir "pending-$qid.json") -EA SilentlyContinue
            $result += [PSCustomObject]@{
                Id           = $qid
                ComputerName = $o.computerName
                Mac          = $o.mac
                Since        = $o.since
                LastSeen     = $o.lastSeen
                Pushed       = [bool]$hasPending
            }
        } catch {}
    }
    return $result
}

function Set-PendingSequence {
    <# .SYNOPSIS Depose une sequence pour un poste en attente (push depuis la GUI).
        Le contenu est le .psd1 de la sequence (texte) + un libelle.
    .PARAMETER Id            identifiant du poste (MAC).
    .PARAMETER SequenceText  contenu .psd1 de la sequence a jouer.
    .PARAMETER Label         nom lisible de la sequence (pour le suivi). #>
    param(
        [Parameter(Mandatory)][string]$Id,
        [Parameter(Mandatory)][string]$SequenceText,
        [string]$Label = ''
    )
    Test-QueueReady
    $qid = Get-QueueId $Id
    if (-not $qid) { return $null }
    # On n'accepte de pousser que vers un poste effectivement en attente.
    if (-not (Test-Path (Join-Path $script:QueueDir "waiting-$qid.json") -EA SilentlyContinue)) {
        return [PSCustomObject]@{ Success = $false; Error = 'Poste non en attente.' }
    }
    $file = Join-Path $script:QueueDir "pending-$qid.json"
    $obj = [PSCustomObject]@{
        id           = $qid
        label        = $Label
        sequenceText = $SequenceText
        pushedAt     = (Get-Date).ToString('o')
    }
    try {
        $obj | ConvertTo-Json -Depth 4 | Set-Content -Path $file -Encoding UTF8 -EA Stop
        return [PSCustomObject]@{ Success = $true }
    } catch {
        return [PSCustomObject]@{ Success = $false; Error = "$($_.Exception.Message)" }
    }
}

function Get-PendingSequence {
    <# .SYNOPSIS Le poste tire sa sequence. Si presente, on la retourne et on
        CONSOMME la file pour ce poste (suppression waiting + pending) : le poste
        quitte l'attente et va jouer la sequence. Retourne $null si rien en file. #>
    param([Parameter(Mandatory)][string]$Id)
    Test-QueueReady
    $qid = Get-QueueId $Id
    if (-not $qid) { return $null }
    $pending = Join-Path $script:QueueDir "pending-$qid.json"
    if (-not (Test-Path $pending -EA SilentlyContinue)) { return $null }
    try {
        $o = Get-Content $pending -Raw -EA Stop | ConvertFrom-Json
        # Consommer : le poste part en deploiement.
        Remove-Item $pending -Force -EA SilentlyContinue
        Remove-Item (Join-Path $script:QueueDir "waiting-$qid.json") -Force -EA SilentlyContinue
        return [PSCustomObject]@{
            Id           = $qid
            Label        = $o.label
            SequenceText = $o.sequenceText
            PushedAt     = $o.pushedAt
        }
    } catch {
        return $null
    }
}

function Clear-WaitingDeployment {
    <# .SYNOPSIS Annule l'attente d'un poste (bouton GUI, ou abandon poste).
        Supprime waiting + pending. #>
    param([Parameter(Mandatory)][string]$Id)
    Test-QueueReady
    $qid = Get-QueueId $Id
    if (-not $qid) { return $false }
    Remove-Item (Join-Path $script:QueueDir "waiting-$qid.json") -Force -EA SilentlyContinue
    Remove-Item (Join-Path $script:QueueDir "pending-$qid.json") -Force -EA SilentlyContinue
    return $true
}

Export-ModuleMember -Function @(
    'Initialize-DeployQueue'
    'Register-WaitingDeployment'
    'Get-WaitingDeployments'
    'Set-PendingSequence'
    'Get-PendingSequence'
    'Clear-WaitingDeployment'
)
