# PsdJson.psm1 -- Conversion robuste PSD1 <-> JSON dans les DEUX sens.
#
# RAISON D'ETRE :
#   L'interface web travaille en JSON, le moteur de deploiement (WinPE/Windows)
#   lit du PSD1 (Import-PowerShellDataFile). Il faut convertir proprement dans
#   les deux sens, en preservant la structure (hashtables, arrays, types).
#
#   Sert a : synchroniser le catalogue d'applications, generer/lire les sequences
#   by-name / by-mac, echanger des donnees entre l'API et le frontend.
#
# Le PSD1 genere est toujours en BOM UTF-8 et ASCII-safe (pour WinPE/PS 5.1).

Set-StrictMode -Version Latest

function ConvertTo-Psd1String {
    <#
    .SYNOPSIS Convertit un objet PowerShell (hashtable/array/scalaire) en texte
        PSD1 indente, pret a etre ecrit dans un fichier .psd1.
    .PARAMETER Object  L'objet a convertir (hashtable, array, PSCustomObject, scalaire).
    .PARAMETER Indent  Niveau d'indentation initial (usage interne, defaut 0).
    .OUTPUTS [string] Le PSD1 formate.
    #>
    [CmdletBinding()]
    param(
        $Object,
        [int]$Indent = 0
    )
    $sp  = '    ' * $Indent
    $sp1 = '    ' * ($Indent + 1)

    if ($null -eq $Object) { return '$null' }

    # Booleen
    if ($Object -is [bool]) { return $(if ($Object) { '$true' } else { '$false' }) }

    # Nombre
    if ($Object -is [int] -or $Object -is [long] -or $Object -is [double] -or $Object -is [decimal]) {
        return "$Object"
    }

    # Hashtable / dictionnaire / PSCustomObject -> @{ ... }
    if ($Object -is [hashtable] -or $Object -is [System.Collections.IDictionary]) {
        $keys = @($Object.Keys)
        if ($keys.Count -eq 0) { return '@{}' }
        $lines = @('@{')
        foreach ($k in $keys) {
            $val = ConvertTo-Psd1String -Object $Object[$k] -Indent ($Indent + 1)
            $lines += "$sp1$k = $val"
        }
        $lines += "$sp}"
        return ($lines -join "`r`n")
    }
    if ($Object -is [PSCustomObject]) {
        $props = @($Object.PSObject.Properties)
        if ($props.Count -eq 0) { return '@{}' }
        $lines = @('@{')
        foreach ($p in $props) {
            $val = ConvertTo-Psd1String -Object $p.Value -Indent ($Indent + 1)
            $lines += "$sp1$($p.Name) = $val"
        }
        $lines += "$sp}"
        return ($lines -join "`r`n")
    }

    # Array / collection -> @( ... )
    if ($Object -is [System.Array] -or ($Object -is [System.Collections.IEnumerable] -and $Object -isnot [string])) {
        $items = @($Object)
        if ($items.Count -eq 0) { return '@()' }
        $lines = @('@(')
        foreach ($it in $items) {
            $val = ConvertTo-Psd1String -Object $it -Indent ($Indent + 1)
            $lines += "$sp1$val"
        }
        $lines += "$sp)"
        return ($lines -join "`r`n")
    }

    # Chaine (par defaut) : echapper les apostrophes, quoter en simple
    $s = "$Object".Replace("'", "''")
    return "'$s'"
}

function Save-Psd1File {
    <#
    .SYNOPSIS Ecrit un objet en fichier PSD1, avec BOM UTF-8 (lisible par WinPE/PS 5.1).
    .PARAMETER Object  L'objet a serialiser.
    .PARAMETER Path    Chemin du fichier .psd1 a creer/ecraser.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Object,
        [Parameter(Mandatory)] [string]$Path
    )
    $content = ConvertTo-Psd1String -Object $Object
    $dir = Split-Path $Path -Parent
    if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory $dir -Force -EA SilentlyContinue | Out-Null }
    $enc = New-Object System.Text.UTF8Encoding($true)   # $true = avec BOM
    [System.IO.File]::WriteAllText($Path, $content, $enc)
    return $Path
}

function ConvertFrom-Psd1File {
    <#
    .SYNOPSIS Lit un fichier PSD1 en objet PowerShell (hashtable).
    .PARAMETER Path  Chemin du fichier .psd1.
    .OUTPUTS [hashtable] ou $null si echec.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path $Path -EA SilentlyContinue)) { return $null }
    try { return Import-PowerShellDataFile -Path $Path -EA Stop } catch { return $null }
}

function ConvertTo-JsonSafe {
    <#
    .SYNOPSIS Convertit un objet (issu d'un PSD1) en JSON propre pour le web.
        Gere la profondeur et les hashtables.
    .PARAMETER Object  L'objet a convertir.
    .PARAMETER Depth   Profondeur max (defaut 10).
    .OUTPUTS [string] JSON.
    #>
    [CmdletBinding()]
    param($Object, [int]$Depth = 10)
    return ($Object | ConvertTo-Json -Depth $Depth -Compress)
}

function ConvertFrom-JsonToHashtable {
    <#
    .SYNOPSIS Convertit du JSON en hashtable PowerShell (recursif), pour ensuite
        le serialiser en PSD1. ConvertFrom-Json donne des PSCustomObject ; on les
        transforme en hashtables pour un PSD1 propre.
    .PARAMETER Json  La chaine JSON.
    .OUTPUTS [hashtable] / [array] / scalaire.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Json)

    function Convert-Node {
        param($Node)
        if ($null -eq $Node) { return $null }
        if ($Node -is [System.Management.Automation.PSCustomObject]) {
            $h = @{}
            foreach ($p in $Node.PSObject.Properties) { $h[$p.Name] = Convert-Node $p.Value }
            return $h
        }
        if ($Node -is [System.Array] -or ($Node -is [System.Collections.IEnumerable] -and $Node -isnot [string])) {
            $arr = @()
            foreach ($it in $Node) { $arr += , (Convert-Node $it) }
            return , $arr
        }
        return $Node
    }

    $parsed = $Json | ConvertFrom-Json
    return (Convert-Node $parsed)
}

Export-ModuleMember -Function @(
    'ConvertTo-Psd1String'
    'Save-Psd1File'
    'ConvertFrom-Psd1File'
    'ConvertTo-JsonSafe'
    'ConvertFrom-JsonToHashtable'
)
