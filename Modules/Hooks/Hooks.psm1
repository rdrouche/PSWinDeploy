#Requires -Version 5.1
<#
.SYNOPSIS
    PSWinDeploy.Hooks -- Couche de surcharge globale et abstraction UI
.DESCRIPTION
    Permet de surcharger n'importe quel comportement de PSWinDeploy sans
    modifier le code coeur. Trois mecanismes :

      1. HOOKS (events)    : s'aboncer a des evenements du cycle de deploiement
                             (OnStepStart, OnStepEnd, OnError, OnProgress...)
      2. UI PROVIDER       : remplacer les interactions console par une GUI
                             (WinForms, WPF, PrimalForms...) via une interface
      3. FUNCTION OVERRIDE : remplacer une fonction par sa propre implementation

    Tout est optionnel : sans surcharge, PSWinDeploy fonctionne en mode console.

.EXAMPLE
    # Dans un script GUI (ex: MaGui.ps1 fait avec PrimalForms)
    Import-Module PSWinDeploy.Hooks

    # 1. S'abonner a des evenements
    Register-PSWDHook -Event 'OnStepStart' -Action {
        param($Context)
        $form.lblStatus.Text = "Etape : $($Context.StepName)"
    }

    # 2. Remplacer les prompts console par la GUI
    Set-PSWDUIProvider -Provider @{
        AskString  = { param($Question, $Default) Show-MyInputBox $Question $Default }
        AskYesNo   = { param($Question, $Default) Show-MyConfirm $Question }
        ShowList   = { param($Title, $Items)      Show-MyListPicker $Title $Items }
        Notify     = { param($Message, $Level)    Update-MyStatusBar $Message $Level }
        Progress   = { param($Percent, $Activity) Update-MyProgressBar $Percent }
    }

    # 3. Surcharger une fonction entiere
    Set-PSWDOverride -Name 'Select-TargetDisk' -ScriptBlock {
        Show-MyDiskSelectorForm
    }
#>

Set-StrictMode -Version Latest

# ---------------------------------------------------------------------------
# ETAT GLOBAL DES SURCHARGES
# ---------------------------------------------------------------------------

# Table des hooks : nom_evenement -> liste de scriptblocks
$script:Hooks = @{}

# Provider UI courant (null = console par defaut)
$script:UIProvider = $null

# Table des fonctions surchargees : nom -> scriptblock
$script:Overrides = @{}

# Liste des evenements valides (documentation + validation)
$script:ValidEvents = @(
    'OnDeployStart'      # Debut du deploiement complet
    'OnDeployEnd'        # Fin du deploiement (succes)
    'OnDeployError'      # Erreur fatale
    'OnStepStart'        # Avant chaque step       (Context: StepId, StepName, StepType)
    'OnStepEnd'          # Apres chaque step        (Context: StepId, Success, Duration)
    'OnStepError'        # Erreur dans un step      (Context: StepId, Error)
    'OnProgress'         # Progression              (Context: Percent, Activity)
    'OnReboot'           # Avant un redemarrage     (Context: NextStep)
    'OnDiskFormat'       # Avant formatage disque   (Context: DiskNumber)
    'OnWIMApply'         # Avant application WIM     (Context: WimPath, Index)
    'OnLog'              # Chaque ligne de log      (Context: Message, Level)
)

# ---------------------------------------------------------------------------
# HOOKS (EVENEMENTS)
# ---------------------------------------------------------------------------

function Register-PSWDHook {
    <#
    .SYNOPSIS Abonne un scriptblock a un evenement du cycle de deploiement.
    .PARAMETER Event  Nom de l'evenement (voir Get-PSWDHookEvents).
    .PARAMETER Action Scriptblock recevant $Context en parametre.
    .EXAMPLE
        Register-PSWDHook -Event 'OnStepStart' -Action {
            param($Context)
            Write-Host "Demarre : $($Context.StepName)"
        }
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Event,
        [Parameter(Mandatory)][scriptblock]$Action
    )
    if ($Event -notin $script:ValidEvents) {
        Write-Warning "Evenement inconnu : $Event. Valides : $($script:ValidEvents -join ', ')"
    }
    if (-not $script:Hooks.ContainsKey($Event)) {
        $script:Hooks[$Event] = [System.Collections.Generic.List[scriptblock]]::new()
    }
    $script:Hooks[$Event].Add($Action)
}

function Unregister-PSWDHook {
    <# .SYNOPSIS Retire tous les hooks d'un evenement (ou tous si -All). #>
    [CmdletBinding()]
    param([string]$Event, [switch]$All)
    if ($All) { $script:Hooks = @{}; return }
    if ($Event -and $script:Hooks.ContainsKey($Event)) {
        $script:Hooks.Remove($Event) | Out-Null
    }
}

function Invoke-PSWDHook {
    <#
    .SYNOPSIS Declenche un evenement -- appele par le coeur PSWinDeploy.
    .DESCRIPTION
        Execute tous les scriptblocks abonnes a l'evenement, en passant $Context.
        Les erreurs dans un hook n'interrompent PAS le deploiement (try/catch).
    .PARAMETER Event   Nom de l'evenement.
    .PARAMETER Context Hashtable de donnees passee aux hooks.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Event,
        [hashtable]$Context = @{}
    )
    if (-not $script:Hooks.ContainsKey($Event)) { return }
    foreach ($action in $script:Hooks[$Event]) {
        try {
            & $action ([PSCustomObject]$Context)
        } catch {
            Write-Warning "Hook '$Event' a echoue : $_"
        }
    }
}

function Get-PSWDHookEvents {
    <# .SYNOPSIS Liste les evenements disponibles pour Register-PSWDHook. #>
    $script:ValidEvents
}

# ---------------------------------------------------------------------------
# PROVIDER UI (ABSTRACTION CONSOLE / GUI)
# ---------------------------------------------------------------------------

function Set-PSWDUIProvider {
    <#
    .SYNOPSIS Remplace les interactions console par un provider personnalise (GUI).
    .DESCRIPTION
        Le provider est une hashtable de scriptblocks. Cles supportees :
          AskString = { param($Question,$Default) ... return [string] }
          AskYesNo  = { param($Question,$Default) ... return [bool]   }
          AskSecret = { param($Question)          ... return [string] }
          ShowList      = { param($Title,$Items) ... return [int] (index) }
          ShowMultiList = { param($Title,$Items) ... return [int[]] (indices coches) }
          Notify        = { param($Message,$Level)    ... }
          Progress      = { param($Percent,$Activity) ... }
        Toute cle absente retombe sur le comportement console par defaut.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$Provider)
    $script:UIProvider = $Provider
}

function Clear-PSWDUIProvider {
    <# .SYNOPSIS Retire le provider UI -- retour au mode console. #>
    $script:UIProvider = $null
}

function Get-PSWDUIProvider {
    <# .SYNOPSIS Retourne le provider UI courant ($null si console). #>
    $script:UIProvider
}

# -- Fonctions UI utilisees par le coeur (delegent au provider ou console) ----

function Request-PSWDString {
    <#
    .SYNOPSIS Demande une chaine de texte a l'operateur (GUI si provider, sinon console).
    .PARAMETER Question  [string] Texte de la question affichee.
    .PARAMETER Default   [string] Valeur par defaut si l'operateur valide sans saisir.
    .OUTPUTS [string] La saisie de l'operateur, ou $Default si vide.
    #>
    param([string]$Question, [string]$Default = '')
    if ($script:UIProvider -and $script:UIProvider.ContainsKey('AskString')) {
        return & $script:UIProvider.AskString $Question $Default
    }
    $prompt = if ($Default) { "  $Question [$Default] : " } else { "  $Question : " }
    Write-Host $prompt -ForegroundColor Yellow -NoNewline
    $r = (Read-Host).Trim()
    if ([string]::IsNullOrWhiteSpace($r)) { return $Default }
    return $r
}

function Request-PSWDYesNo {
    <#
    .SYNOPSIS Demande une confirmation oui/non (GUI si provider, sinon console).
    .PARAMETER Question  [string] Texte de la question.
    .PARAMETER Default   [bool]   Reponse par defaut ($true=oui) si validation a vide.
    .OUTPUTS [bool] $true si oui, $false si non.
    #>
    param([string]$Question, [bool]$Default = $true)
    if ($script:UIProvider -and $script:UIProvider.ContainsKey('AskYesNo')) {
        return [bool](& $script:UIProvider.AskYesNo $Question $Default)
    }
    $hint = if ($Default) { '[O/n]' } else { '[o/N]' }
    Write-Host "  $Question $hint : " -ForegroundColor Yellow -NoNewline
    $r = (Read-Host).Trim().ToLower()
    if ([string]::IsNullOrWhiteSpace($r)) { return $Default }
    return $r -in @('o','oui','y','yes')
}

function Request-PSWDSecret {
    <#
    .SYNOPSIS Demande un secret (mot de passe) en saisie masquee (GUI si provider, sinon console).
    .PARAMETER Question  [string] Texte de la question.
    .OUTPUTS [string] Le secret saisi, en CLAIR (chaine simple). L'appelant est
        responsable de le securiser/effacer apres usage.
    #>
    param([string]$Question)
    if ($script:UIProvider -and $script:UIProvider.ContainsKey('AskSecret')) {
        return & $script:UIProvider.AskSecret $Question
    }
    $sec = Read-Host "  $Question" -AsSecureString
    return [Runtime.InteropServices.Marshal]::PtrToStringAuto(
        [Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec))
}

function Show-PSWDList {
    <#
    .SYNOPSIS Affiche une liste numerotee a choix unique (GUI si provider, sinon console).
    .PARAMETER Title  [string]   Titre de la liste.
    .PARAMETER Items  [string[]] Les libelles a afficher (1 par ligne).
    .OUTPUTS [int] L'index choisi en base 0 (0 = premier item). Retourne 0 par
        defaut si saisie invalide. (Pour une option "annuler", prevoir un item
        dedie dans $Items et tester l'index retourne.)
    #>
    param([string]$Title, [string[]]$Items)
    if ($script:UIProvider -and $script:UIProvider.ContainsKey('ShowList')) {
        return [int](& $script:UIProvider.ShowList $Title $Items)
    }
    Write-Host ""
    Write-Host "  $Title" -ForegroundColor Cyan
    for ($i = 0; $i -lt $Items.Count; $i++) {
        Write-Host "  [$($i+1)] $($Items[$i])" -ForegroundColor White
    }
    Write-Host "  [?]  Choix [1] : " -ForegroundColor Yellow -NoNewline
    $c = (Read-Host).Trim()
    if ($c -match '^\d+$' -and [int]$c -ge 1 -and [int]$c -le $Items.Count) { return [int]$c - 1 }
    return 0
}

function Show-PSWDMultiList {
    <#
    .SYNOPSIS Liste a CASES A COCHER -- retourne les index coches (0-based).
    .DESCRIPTION
        Si un provider GUI est defini (ShowMultiList), il est utilise. Sinon,
        affiche une fenetre WinForms avec une case a cocher par element
        (interface graphique native). En dernier repli (pas de GUI possible,
        ex: WinPE sans Windows Forms), bascule en mode console oui/non.
    .OUTPUTS Tableau d'index (int) coches.
    #>
    param([string]$Title, [string[]]$Items)
    if (-not $Items -or $Items.Count -eq 0) { return @() }

    # 1) Provider GUI surcharge
    if ($script:UIProvider -and $script:UIProvider.ContainsKey('ShowMultiList')) {
        return @(& $script:UIProvider.ShowMultiList $Title $Items)
    }

    # 2) Interface WinForms native (cases a cocher)
    try {
        Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
        Add-Type -AssemblyName System.Drawing -ErrorAction Stop
        $form = New-Object System.Windows.Forms.Form
        $form.Text = $Title
        $form.Size = New-Object System.Drawing.Size(520, 460)
        $form.StartPosition = 'CenterScreen'
        $form.TopMost = $true

        $label = New-Object System.Windows.Forms.Label
        $label.Text = $Title
        $label.AutoSize = $true
        $label.Location = New-Object System.Drawing.Point(12, 12)
        $form.Controls.Add($label)

        $clb = New-Object System.Windows.Forms.CheckedListBox
        $clb.Location = New-Object System.Drawing.Point(12, 38)
        $clb.Size = New-Object System.Drawing.Size(480, 330)
        $clb.CheckOnClick = $true
        foreach ($it in $Items) { [void]$clb.Items.Add($it) }
        $form.Controls.Add($clb)

        $btnOk = New-Object System.Windows.Forms.Button
        $btnOk.Text = 'Installer la selection'
        $btnOk.Location = New-Object System.Drawing.Point(280, 380)
        $btnOk.Size = New-Object System.Drawing.Size(150, 30)
        $btnOk.DialogResult = [System.Windows.Forms.DialogResult]::OK
        $form.Controls.Add($btnOk)
        $form.AcceptButton = $btnOk

        $btnCancel = New-Object System.Windows.Forms.Button
        $btnCancel.Text = 'Annuler'
        $btnCancel.Location = New-Object System.Drawing.Point(180, 380)
        $btnCancel.Size = New-Object System.Drawing.Size(90, 30)
        $btnCancel.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
        $form.Controls.Add($btnCancel)
        $form.CancelButton = $btnCancel

        $result = $form.ShowDialog()
        $picked = @()
        if ($result -eq [System.Windows.Forms.DialogResult]::OK) {
            foreach ($idx in $clb.CheckedIndices) { $picked += [int]$idx }
        }
        $form.Dispose()
        return @($picked)
    } catch {
        # 3) Repli console : oui/non par element
        Write-Host ""
        Write-Host "  $Title" -ForegroundColor Cyan
        $picked = @()
        for ($i = 0; $i -lt $Items.Count; $i++) {
            Write-Host "  $($Items[$i]) ? [o/N] : " -ForegroundColor Yellow -NoNewline
            if ((Read-Host).Trim().ToLower() -in @('o','oui','y','yes')) { $picked += $i }
        }
        return @($picked)
    }
}

function Write-PSWDNotify {
    <#
    .SYNOPSIS Notifie un message (GUI si provider, sinon console + declenche le hook OnLog).
    .PARAMETER Message  [string] Le message a notifier.
    .PARAMETER Level    [string] Niveau : INFO | SUCCESS | WARN | ERROR (defaut INFO).
    .OUTPUTS Aucun (void). Effet de bord : affichage + hook OnLog.
    #>
    param([string]$Message, [string]$Level = 'INFO')
    # Toujours declencher le hook OnLog (pour journalisation GUI)
    Invoke-PSWDHook -Event 'OnLog' -Context @{ Message = $Message; Level = $Level }
    if ($script:UIProvider -and $script:UIProvider.ContainsKey('Notify')) {
        & $script:UIProvider.Notify $Message $Level
        return
    }
    $color = switch ($Level) {
        'OK'      { 'Green' }
        'SUCCESS' { 'Green' }
        'WARN'    { 'Yellow' }
        'ERROR'   { 'Red' }
        'STEP'    { 'Magenta' }
        default   { 'Cyan' }
    }
    Write-Host "  $Message" -ForegroundColor $color
}

function Write-PSWDProgress {
    <#
    .SYNOPSIS Rapporte une progression (GUI si provider, sinon Write-Progress natif).
    .PARAMETER Percent   [int]    Pourcentage d'avancement, 0 a 100.
    .PARAMETER Activity  [string] Libelle de l'activite en cours (defaut 'Deploiement').
    .OUTPUTS Aucun (void). Effet de bord : barre de progression.
    #>
    param([int]$Percent, [string]$Activity = 'Deploiement')
    Invoke-PSWDHook -Event 'OnProgress' -Context @{ Percent = $Percent; Activity = $Activity }
    if ($script:UIProvider -and $script:UIProvider.ContainsKey('Progress')) {
        & $script:UIProvider.Progress $Percent $Activity
        return
    }
    Write-Progress -Activity $Activity -PercentComplete $Percent
}

# ---------------------------------------------------------------------------
# OVERRIDE DE FONCTIONS
# ---------------------------------------------------------------------------

function Set-PSWDOverride {
    <#
    .SYNOPSIS Remplace une fonction PSWinDeploy par sa propre implementation.
    .DESCRIPTION
        Permet de remplacer completement une fonction (ex: Select-TargetDisk)
        par une version GUI. Le coeur appelle Invoke-PSWDFunction qui verifie
        d'abord les overrides.
    .EXAMPLE
        Set-PSWDOverride -Name 'Select-TargetDisk' -ScriptBlock {
            param($Disks)
            Show-DiskSelectorForm -Disks $Disks
        }
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][scriptblock]$ScriptBlock
    )
    $script:Overrides[$Name] = $ScriptBlock
}

function Remove-PSWDOverride {
    <# .SYNOPSIS Retire une surcharge de fonction (ou toutes si -All). #>
    param([string]$Name, [switch]$All)
    if ($All) { $script:Overrides = @{}; return }
    if ($Name -and $script:Overrides.ContainsKey($Name)) {
        $script:Overrides.Remove($Name) | Out-Null
    }
}

function Test-PSWDOverride {
    <# .SYNOPSIS Verifie si une fonction est surchargee. #>
    param([Parameter(Mandatory)][string]$Name)
    $script:Overrides.ContainsKey($Name)
}

function Invoke-PSWDFunction {
    <#
    .SYNOPSIS Appelle une fonction en respectant les overrides eventuels.
    .DESCRIPTION
        Le coeur appelle Invoke-PSWDFunction 'NomFonction' @args.
        Si un override existe, il est execute a la place. Sinon, la fonction
        native (passee via -Default) est appelee.
    .EXAMPLE
        $disk = Invoke-PSWDFunction -Name 'Select-TargetDisk' -Default { Select-TargetDisk } -Arguments $disks
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Name,
        [scriptblock]$Default,
        [object[]]$Arguments = @()
    )
    if ($script:Overrides.ContainsKey($Name)) {
        return & $script:Overrides[$Name] @Arguments
    }
    if ($Default) {
        return & $Default @Arguments
    }
    throw "Aucune implementation pour '$Name' (ni override ni default)"
}

# ---------------------------------------------------------------------------
# CHARGEMENT D'UN PROFIL DE SURCHARGE EXTERNE
# ---------------------------------------------------------------------------

function Import-PSWDOverrideProfile {
    <#
    .SYNOPSIS Charge un fichier .ps1 de surcharge (hooks + provider + overrides).
    .DESCRIPTION
        Permet de placer toute la personnalisation GUI dans un fichier separe
        (ex: Overrides\MaGui.ps1) charge automatiquement au demarrage si present.
        Le fichier appelle simplement Register-PSWDHook, Set-PSWDUIProvider, etc.
    .EXAMPLE
        Import-PSWDOverrideProfile -Path 'X:\Deploy\Overrides\gui.ps1'
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path $Path -EA SilentlyContinue)) {
        Write-Verbose "Aucun profil de surcharge : $Path"
        return $false
    }
    try {
        . $Path
        Write-PSWDNotify "Profil de surcharge charge : $(Split-Path $Path -Leaf)" 'OK'
        return $true
    } catch {
        Write-Warning "Echec chargement surcharge $Path : $_"
        return $false
    }
}

function Find-PSWDOverrideProfile {
    <#
    .SYNOPSIS Cherche automatiquement un profil de surcharge dans les emplacements standards.
    .DESCRIPTION
        Cherche 'overrides.ps1' ou 'gui.ps1' dans :
          - dossier Overrides/ a cote des modules
          - racine Deploy
        Charge le premier trouve. Permet le branchement GUI sans modifier le coeur.
    #>
    [CmdletBinding()]
    param([string[]]$SearchRoots = @())

    if (-not $SearchRoots) {
        $SearchRoots = @('X:\Deploy', 'C:\Deploy', 'W:\Deploy', $PSScriptRoot)
    }
    # Ne garder que les racines dont le DRIVE existe (evite 'Cannot find drive')
    $validRoots = @()
    foreach ($root in $SearchRoots) {
        if ([string]::IsNullOrWhiteSpace($root)) { continue }
        # Extraire la lettre de lecteur si presente
        if ($root -match '^([A-Za-z]):') {
            $drive = $Matches[1]
            if (-not (Get-PSDrive -Name $drive -PSProvider FileSystem -EA SilentlyContinue)) {
                continue  # drive absent -- ignorer cette racine
            }
        }
        $validRoots += $root
    }

    $names = @('overrides.ps1', 'gui.ps1', 'PSWD-Override.ps1')
    foreach ($root in $validRoots) {
        foreach ($n in $names) {
            $candidate = Join-Path $root "Overrides\$n"
            if (Test-Path $candidate -EA SilentlyContinue) { return $candidate }
            $candidate2 = Join-Path $root $n
            if (Test-Path $candidate2 -EA SilentlyContinue) { return $candidate2 }
        }
    }
    return $null
}

function Show-PSWDRadioPicker {
    <#
    .SYNOPSIS Fenetre GUI (WinForms) GENERIQUE a choix unique (boutons radio).
        Reutilisable pour n'importe quelle selection (drivers, OS, editions...).
    .DESCRIPTION
        Affiche une option par bouton radio + boutons OK / Annuler. Le premier
        item est coche par defaut. Option "none" ajoutee si -NoneLabel fourni.
    .PARAMETER Title      [string]   Titre de la fenetre.
    .PARAMETER Labels     [string[]] Les libelles, un par bouton radio.
    .PARAMETER Prompt     [string]   Texte affiche au-dessus de la liste.
    .PARAMETER NoneLabel  [string]   Si non vide, ajoute une option "none"
                                     (qui retourne -1). Vide = pas d'option aucun.
    .OUTPUTS [int] ou $null :
        >= 0  : index choisi (base 0) dans $Labels.
        -1    : l'operateur a annule OU choisi l'option "none".
        $null : WinForms INDISPONIBLE (WinPE minimal). L'appelant DOIT alors
                basculer sur un mode console. C'est la difference cle : -1 =
                choix explicite de ne rien prendre, $null = GUI impossible.
    #>
    param(
        [string]$Title = 'Selection',
        [string[]]$Labels,
        [string]$Prompt = 'Choisissez une option :',
        [string]$NoneLabel = ''          # si non vide, ajoute une option "none" (-1)
    )
    $Labels = @($Labels)
    if ($Global:PSWDDebug) { Write-Host "  [diag] GUI : $($Labels.Count) label(s) recu(s) : $($Labels -join ' | ')" -ForegroundColor DarkGray }
    if (-not $Labels -or $Labels.Count -eq 0) { return -1 }

    try {
        Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
        Add-Type -AssemblyName System.Drawing -ErrorAction Stop
    } catch {
        # WinForms indisponible -> signaler a l'appelant (bascule console)
        if ($Global:PSWDDebug) { Write-Host "  [diag] WinForms indisponible -> bascule console." -ForegroundColor Yellow }
        return $null
    }

    try {
        $form = New-Object System.Windows.Forms.Form
        $form.Text = $Title
        $form.StartPosition = 'CenterScreen'
        $form.TopMost = $true
        $form.FormBorderStyle = 'FixedDialog'
        $form.MaximizeBox = $false
        $form.MinimizeBox = $false

        $label = New-Object System.Windows.Forms.Label
        $label.Text = $Prompt
        $label.AutoSize = $true
        $label.Location = New-Object System.Drawing.Point(15, 15)
        $form.Controls.Add($label)

        # Un RadioButton par dossier, dans un panel scrollable
        $panel = New-Object System.Windows.Forms.Panel
        $panel.Location = New-Object System.Drawing.Point(15, 45)
        $panel.Size = New-Object System.Drawing.Size(460, 260)
        $panel.AutoScroll = $true
        $panel.BorderStyle = 'FixedSingle'
        $form.Controls.Add($panel)

        $radios = New-Object System.Collections.ArrayList
        $y = 10
        for ($i = 0; $i -lt $Labels.Count; $i++) {
            $rb = New-Object System.Windows.Forms.RadioButton
            $rb.Text = [string]$Labels[$i]
            $rb.Location = New-Object System.Drawing.Point(10, $y)
            $rb.AutoSize = $true
            $rb.Tag = [string]$i      # index stocke en string (relu en int plus bas)
            if ($i -eq 0) { $rb.Checked = $true }
            $panel.Controls.Add($rb)
            [void]$radios.Add($rb)
            $y += 30
        }

        # Option "None" (seulement si demandee)
        if ($NoneLabel) {
            $rbNone = New-Object System.Windows.Forms.RadioButton
            $rbNone.Text = $NoneLabel
            $rbNone.Location = New-Object System.Drawing.Point(10, $y)
            $rbNone.AutoSize = $true
            $rbNone.Tag = '-1'
            $panel.Controls.Add($rbNone)
            [void]$radios.Add($rbNone)
        }

        # Boutons OK / Annuler
        $btnOK = New-Object System.Windows.Forms.Button
        $btnOK.Text = 'OK'
        $btnOK.Location = New-Object System.Drawing.Point(300, 320)
        $btnOK.Size = New-Object System.Drawing.Size(85, 30)
        $btnOK.DialogResult = [System.Windows.Forms.DialogResult]::OK
        $form.Controls.Add($btnOK)
        $form.AcceptButton = $btnOK

        $btnCancel = New-Object System.Windows.Forms.Button
        $btnCancel.Text = 'Annuler'
        $btnCancel.Location = New-Object System.Drawing.Point(390, 320)
        $btnCancel.Size = New-Object System.Drawing.Size(85, 30)
        $btnCancel.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
        $form.Controls.Add($btnCancel)
        $form.CancelButton = $btnCancel

        $form.ClientSize = New-Object System.Drawing.Size(490, 365)

        $result = $form.ShowDialog()
        if ($result -ne [System.Windows.Forms.DialogResult]::OK) { return -1 }

        $chosenIdx = -1
        foreach ($rb in $radios) {
            if ($rb.Checked) {
                $tmp = 0
                if ([int]::TryParse([string]$rb.Tag, [ref]$tmp)) { $chosenIdx = $tmp }
                break
            }
        }
        return $chosenIdx
    } catch {
        return $null
    }
}

Export-ModuleMember -Function @(
    'Show-PSWDMultiList'
    'Register-PSWDHook'
    'Unregister-PSWDHook'
    'Invoke-PSWDHook'
    'Get-PSWDHookEvents'
    'Set-PSWDUIProvider'
    'Clear-PSWDUIProvider'
    'Get-PSWDUIProvider'
    'Request-PSWDString'
    'Request-PSWDYesNo'
    'Request-PSWDSecret'
    'Show-PSWDList'
    'Show-PSWDRadioPicker'
    'Write-PSWDNotify'
    'Write-PSWDProgress'
    'Set-PSWDOverride'
    'Remove-PSWDOverride'
    'Test-PSWDOverride'
    'Invoke-PSWDFunction'
    'Import-PSWDOverrideProfile'
    'Find-PSWDOverrideProfile'
)
