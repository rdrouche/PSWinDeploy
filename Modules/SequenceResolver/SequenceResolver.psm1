# SequenceResolver.psm1 -- POINT D'ENTREE UNIQUE pour trouver LA sequence.
#
# Quelle que soit l'origine (deja en local, by-name, by-mac, _default), ce module
# resout UNE sequence et la COPIE TOUJOURS vers C:\Deploy\Runtime\sequence.psd1.
# Apres lui, TOUT le monde (assistant, by-name, reprise) a le MEME fichier local.
# C'est ce qui rend les flux IDENTIQUES.
#
# Ordre de priorite :
#   1. C:\Deploy\Runtime\sequence.psd1 (deja resolu / genere a la volee / reprise)
#   2. <Sequences>\by-name\<COMPUTERNAME>.psd1
#   3. <Sequences>\by-mac\<MAC>.psd1
#   4. <Sequences>\_default.psd1
#   5. rien -> retourne $null (l'appelant lance l'assistant interactif)

Set-StrictMode -Version Latest

$script:LocalSeq = 'C:\Deploy\Runtime\sequence.psd1'

function Get-PrimaryMacAddress {
    try {
        $a = Get-NetAdapter -Physical -EA SilentlyContinue |
             Where-Object { $_.Status -eq 'Up' } | Sort-Object ifIndex | Select-Object -First 1
        if ($a -and $a.MacAddress) { return ($a.MacAddress -replace '[:-]', '').ToUpper() }
    } catch {}
    return ''
}

function Resolve-DeploySequence {
    <#
    .SYNOPSIS Resout LA sequence et la copie en local. Retourne le chemin local
        (C:\Deploy\Runtime\sequence.psd1) ou $null si aucune trouvee.
    .PARAMETER SequencesDir  dossier des sequences (partage Deploy\Sequences)
    .PARAMETER Force         ignorer la sequence locale existante et re-resoudre
    #>
    param(
        [string]$SequencesDir = '',
        [switch]$Force
    )

    $rtDir = Split-Path $script:LocalSeq -Parent
    if (-not (Test-Path $rtDir -EA SilentlyContinue)) { New-Item -ItemType Directory $rtDir -Force -EA SilentlyContinue | Out-Null }

    # 1. Sequence locale deja presente (sauf si -Force)
    if (-not $Force -and (Test-Path $script:LocalSeq -EA SilentlyContinue)) {
        Write-Host "Sequence locale trouvee : $script:LocalSeq" -ForegroundColor Gray
        return $script:LocalSeq
    }

    # Resoudre le dossier des sequences si non fourni
    if (-not $SequencesDir) {
        $candidates = @('C:\Deploy\Sequences')
        foreach ($c in $candidates) { if (Test-Path $c -EA SilentlyContinue) { $SequencesDir = $c; break } }
    }

    $found = $null
    if ($SequencesDir -and (Test-Path $SequencesDir -EA SilentlyContinue)) {
        # 2. by-name
        $byName = Join-Path $SequencesDir "by-name\$env:COMPUTERNAME.psd1"
        if (Test-Path $byName -EA SilentlyContinue) {
            Write-Host "Sequence by-name : $byName" -ForegroundColor Gray
            $found = $byName
        }
        # 3. by-mac
        if (-not $found) {
            $mac = Get-PrimaryMacAddress
            if ($mac) {
                $byMac = Join-Path $SequencesDir "by-mac\$mac.psd1"
                if (Test-Path $byMac -EA SilentlyContinue) {
                    Write-Host "Sequence by-mac : $byMac" -ForegroundColor Gray
                    $found = $byMac
                }
            }
        }
        # 4. _default
        if (-not $found) {
            $def = Join-Path $SequencesDir '_default.psd1'
            if (Test-Path $def -EA SilentlyContinue) {
                Write-Host "Sequence _default : $def" -ForegroundColor Gray
                $found = $def
            }
        }
    }

    if (-not $found) {
        Write-Host "Aucune sequence resolue (by-name/by-mac/_default)." -ForegroundColor Yellow
        return $null
    }

    # COPIE TOUJOURS en local -> apres ca, le flux est identique pour tous.
    try {
        Copy-Item $found $script:LocalSeq -Force -EA Stop
        Write-Host "Sequence copiee en local : $script:LocalSeq" -ForegroundColor Green
        return $script:LocalSeq
    } catch {
        Write-Host "Echec copie de la sequence : $_" -ForegroundColor Red
        # On peut quand meme retourner la source si la copie echoue
        return $found
    }
}

Export-ModuleMember -Function @(
    'Resolve-DeploySequence'
    'Get-PrimaryMacAddress'
)
