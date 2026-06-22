# TaskContract.psm1 -- Contrat standard entre le moteur (TaskEngine) et les
# handlers de taches (TaskHandlers).
#
# RAISON D'ETRE :
#   Avant, chaque handler retournait un hashtable @{...} avec des cles variables.
#   Le moteur devait deviner si une cle existait (PSObject.Properties vs .Contains)
#   ce qui causait des bugs subtils (ex: 'Skipped' jamais detecte sur un hashtable).
#   Ici, TOUT resultat de tache est un PSCustomObject avec TOUJOURS les memes
#   proprietes, valeurs par defaut remplies. Le moteur lit ces proprietes sans
#   jamais se demander si elles existent.

Set-StrictMode -Version Latest

function New-TaskResult {
    <#
    .SYNOPSIS Cree un resultat de tache standard (le CONTRAT).
    .DESCRIPTION
        Retourne TOUJOURS un PSCustomObject avec les memes proprietes :
          Success        [bool] -- la tache a-t-elle reussi ? (defaut $true)
          RebootRequired [bool] -- un redemarrage est-il necessaire ? (defaut $false)
          Skipped        [bool] -- la tache a-t-elle ete sautee (idempotence) ? (defaut $false)
          StayOnStep     [bool] -- rejouer ce meme step apres reboot ? (defaut $false)
          Message        [string] -- message court pour les logs (defaut '')
          Data           [object] -- donnees libres optionnelles (defaut $null)
        Le moteur n'a JAMAIS a tester l'existence d'une propriete : elles sont
        toutes la, tout le temps.
    .EXAMPLE
        return New-TaskResult                                  # succes simple
        return New-TaskResult -RebootRequired                  # succes + reboot
        return New-TaskResult -Skipped -Message 'deja fait'    # saute
        return New-TaskResult -Success:$false -Message 'echec' # echec
    #>
    [CmdletBinding()]
    param(
        [bool]$Success        = $true,
        [switch]$RebootRequired,
        [switch]$Skipped,
        [switch]$StayOnStep,
        [string]$Message      = '',
        $Data                 = $null
    )
    return [PSCustomObject]@{
        Success        = [bool]$Success
        RebootRequired = [bool]$RebootRequired
        Skipped        = [bool]$Skipped
        StayOnStep     = [bool]$StayOnStep
        Message        = "$Message"
        Data           = $Data
    }
}

function ConvertTo-TaskResult {
    <#
    .SYNOPSIS Normalise une valeur quelconque vers le contrat standard.
    .DESCRIPTION
        Les anciens handlers (ou un handler simple) peuvent retourner un hashtable
        @{ Success=...; RebootRequired=... } ou rien du tout. Cette fonction
        convertit n'importe quelle valeur en PSCustomObject standard, en lisant
        les cles disponibles (hashtable OU objet) de facon SURE, et en remplissant
        les valeurs par defaut pour les cles absentes.
        Ainsi, meme un handler non encore migre fonctionne avec le moteur.
    #>
    [CmdletBinding()]
    param($Raw)

    # Helper interne : lire une cle dans un hashtable OU un objet, sans planter.
    $read = {
        param($obj, $key, $default)
        if ($null -eq $obj) { return $default }
        if ($obj -is [hashtable] -or $obj -is [System.Collections.IDictionary]) {
            if ($obj.Contains($key)) { return $obj[$key] } else { return $default }
        }
        $p = $obj.PSObject.Properties[$key]
        if ($p) { return $p.Value } else { return $default }
    }

    # Si $Raw est deja un de nos resultats (a la bonne forme), le renvoyer tel quel.
    if ($Raw -is [PSCustomObject] -and $Raw.PSObject.Properties['Success'] -and $Raw.PSObject.Properties['RebootRequired'] -and $Raw.PSObject.Properties['Skipped']) {
        return $Raw
    }

    # Un handler qui ne retourne rien = succes simple.
    if ($null -eq $Raw) { return New-TaskResult }

    # Un booleen simple : $true = succes, $false = echec.
    if ($Raw -is [bool]) { return New-TaskResult -Success:$Raw }

    # Sinon, lire les cles connues (avec defauts) depuis hashtable ou objet.
    $success = [bool](& $read $Raw 'Success' $true)
    $reboot  = [bool](& $read $Raw 'RebootRequired' $false)
    $skipped = [bool](& $read $Raw 'Skipped' $false)
    $stay    = [bool](& $read $Raw 'StayOnStep' $false)
    $msg     = "$(& $read $Raw 'Message' '')"
    $data    = (& $read $Raw 'Data' $null)

    return [PSCustomObject]@{
        Success        = $success
        RebootRequired = $reboot
        Skipped        = $skipped
        StayOnStep     = $stay
        Message        = $msg
        Data           = $data
    }
}

function Get-StepProperty {
    <#
    .SYNOPSIS Lit une propriete d'un STEP (hashtable ou objet) de facon sure.
    .DESCRIPTION
        Les steps d'une sequence peuvent etre des hashtables (charges depuis psd1)
        ou des PSCustomObject. Cette fonction lit une cle quelle que soit la forme,
        sans planter en StrictMode, avec une valeur par defaut.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Step,
        [Parameter(Mandatory)] [string]$Name,
        $Default = $null
    )
    if ($null -eq $Step) { return $Default }
    if ($Step -is [hashtable] -or $Step -is [System.Collections.IDictionary]) {
        if ($Step.Contains($Name)) { return $Step[$Name] } else { return $Default }
    }
    $p = $Step.PSObject.Properties[$Name]
    if ($p) { return $p.Value } else { return $Default }
}

function Get-StepParam {
    <#
    .SYNOPSIS Lit un parametre dans la sous-table 'params'/'Params' d'un step.
    .DESCRIPTION
        Les parametres specifiques d'un step sont dans step.params (ou step.Params).
        Cette fonction va chercher la sous-table puis la cle demandee, de facon
        sure (hashtable ou objet), avec valeur par defaut.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Step,
        [Parameter(Mandatory)] [string]$Name,
        $Default = $null
    )
    $params = Get-StepProperty -Step $Step -Name 'params'
    if ($null -eq $params) { $params = Get-StepProperty -Step $Step -Name 'Params' }
    if ($null -eq $params) { return $Default }
    $val = Get-StepProperty -Step $params -Name $Name
    if ($null -eq $val) { return $Default }
    return $val
}

Export-ModuleMember -Function @(
    'New-TaskResult'
    'ConvertTo-TaskResult'
    'Get-StepProperty'
    'Get-StepParam'
)
