#Requires -Version 5.1
<#
.SYNOPSIS
    Exemple de surcharge GUI WinForms pour PSWinDeploy.
.DESCRIPTION
    Montre comment brancher une interface graphique sur le coeur PSWinDeploy
    SANS modifier le code source. Ce fichier est charge automatiquement par
    Find-PSWDOverrideProfile s'il est place dans Deploy\Overrides\.

    Pour creer votre propre GUI (PrimalForms, Visual Studio, etc.) :
      1. Construisez votre formulaire
      2. Branchez les hooks et le provider UI comme ci-dessous
      3. Placez le fichier dans Deploy\Overrides\gui.ps1

    Ce fichier est un EXEMPLE -- adaptez-le a votre formulaire.
#>

# Charger WinForms
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# ---------------------------------------------------------------------------
# CONSTRUCTION DU FORMULAIRE (exemple minimal)
# ---------------------------------------------------------------------------

$script:Form = New-Object System.Windows.Forms.Form
$script:Form.Text = 'PSWinDeploy -- Deploiement'
$script:Form.Size = New-Object System.Drawing.Size(640, 480)
$script:Form.StartPosition = 'CenterScreen'

# Zone de log
$script:LogBox = New-Object System.Windows.Forms.TextBox
$script:LogBox.Multiline = $true
$script:LogBox.ScrollBars = 'Vertical'
$script:LogBox.ReadOnly = $true
$script:LogBox.Location = New-Object System.Drawing.Point(10, 10)
$script:LogBox.Size = New-Object System.Drawing.Size(600, 350)
$script:LogBox.Font = New-Object System.Drawing.Font('Consolas', 9)
$script:Form.Controls.Add($script:LogBox)

# Barre de progression
$script:ProgressBar = New-Object System.Windows.Forms.ProgressBar
$script:ProgressBar.Location = New-Object System.Drawing.Point(10, 370)
$script:ProgressBar.Size = New-Object System.Drawing.Size(600, 25)
$script:Form.Controls.Add($script:ProgressBar)

# Label statut
$script:StatusLabel = New-Object System.Windows.Forms.Label
$script:StatusLabel.Location = New-Object System.Drawing.Point(10, 405)
$script:StatusLabel.Size = New-Object System.Drawing.Size(600, 25)
$script:StatusLabel.Text = 'Pret'
$script:Form.Controls.Add($script:StatusLabel)

# Helper : ajouter une ligne de log avec couleur
function Add-GuiLog {
    param([string]$Message, [string]$Level = 'INFO')
    $prefix = switch ($Level) {
        'OK'      { '[OK] ' }
        'SUCCESS' { '[OK] ' }
        'WARN'    { '[!]  ' }
        'ERROR'   { '[X]  ' }
        'STEP'    { '[>>] ' }
        default   { '[~]  ' }
    }
    $script:LogBox.AppendText("$prefix$Message`r`n")
    [System.Windows.Forms.Application]::DoEvents()
}

# ---------------------------------------------------------------------------
# BRANCHEMENT DES HOOKS PSWINDEPLOY
# ---------------------------------------------------------------------------

# Notification -> zone de log GUI
Register-PSWDHook -Event 'OnLog' -Action {
    param($Context)
    Add-GuiLog $Context.Message $Context.Level
}

# Progression -> barre de progression
Register-PSWDHook -Event 'OnProgress' -Action {
    param($Context)
    $script:ProgressBar.Value = [Math]::Min(100, [Math]::Max(0, $Context.Percent))
    [System.Windows.Forms.Application]::DoEvents()
}

# Debut d'etape -> mise a jour du statut
Register-PSWDHook -Event 'OnStepStart' -Action {
    param($Context)
    $script:StatusLabel.Text = "Etape : $($Context.StepName)"
    [System.Windows.Forms.Application]::DoEvents()
}

# Fin de deploiement -> message de succes
Register-PSWDHook -Event 'OnDeployEnd' -Action {
    param($Context)
    $script:StatusLabel.Text = 'Deploiement termine !'
    [System.Windows.Forms.MessageBox]::Show('Deploiement termine avec succes.', 'PSWinDeploy')
}

# Erreur -> message d'erreur
Register-PSWDHook -Event 'OnDeployError' -Action {
    param($Context)
    [System.Windows.Forms.MessageBox]::Show("Erreur : $($Context.Error)", 'PSWinDeploy', 'OK', 'Error')
}

# ---------------------------------------------------------------------------
# PROVIDER UI : remplacer les prompts console par des boites de dialogue
# ---------------------------------------------------------------------------

Set-PSWDUIProvider -Provider @{

    AskString = {
        param($Question, $Default)
        $result = [Microsoft.VisualBasic.Interaction]::InputBox($Question, 'PSWinDeploy', $Default)
        if ([string]::IsNullOrWhiteSpace($result)) { return $Default }
        return $result
    }

    AskYesNo = {
        param($Question, $Default)
        $btn = [System.Windows.Forms.MessageBox]::Show($Question, 'PSWinDeploy', 'YesNo', 'Question')
        return ($btn -eq 'Yes')
    }

    ShowList = {
        param($Title, $Items)
        # Mini-formulaire de selection dans une liste
        $listForm = New-Object System.Windows.Forms.Form
        $listForm.Text = $Title
        $listForm.Size = New-Object System.Drawing.Size(400, 300)
        $listForm.StartPosition = 'CenterParent'
        $lb = New-Object System.Windows.Forms.ListBox
        $lb.Dock = 'Fill'
        $Items | ForEach-Object { $lb.Items.Add($_) | Out-Null }
        if ($lb.Items.Count -gt 0) { $lb.SelectedIndex = 0 }
        $btnOk = New-Object System.Windows.Forms.Button
        $btnOk.Text = 'OK'; $btnOk.Dock = 'Bottom'
        $btnOk.Add_Click({ $listForm.DialogResult = 'OK'; $listForm.Close() })
        $listForm.Controls.Add($lb)
        $listForm.Controls.Add($btnOk)
        $listForm.ShowDialog() | Out-Null
        return [Math]::Max(0, $lb.SelectedIndex)
    }

    Notify = {
        param($Message, $Level)
        Add-GuiLog $Message $Level
    }

    Progress = {
        param($Percent, $Activity)
        $script:ProgressBar.Value = [Math]::Min(100, [Math]::Max(0, $Percent))
        $script:StatusLabel.Text = $Activity
        [System.Windows.Forms.Application]::DoEvents()
    }
}

# ---------------------------------------------------------------------------
# OVERRIDE : remplacer la selection de disque par un formulaire dedie
# ---------------------------------------------------------------------------

Set-PSWDOverride -Name 'Select-TargetDisk' -ScriptBlock {
    $disks = @(Get-Disk | Sort-Object Number)
    $items = $disks | ForEach-Object {
        $sizeGB = if ($_.Size) { "$([Math]::Round($_.Size/1GB,0)) GB" } else { '?' }
        "Disque $($_.Number) -- $($_.FriendlyName) ($sizeGB)"
    }
    $idx = Show-PSWDList -Title 'Choisir le disque cible' -Items $items
    return $disks[$idx].Number
}

# ---------------------------------------------------------------------------
# AFFICHAGE DU FORMULAIRE
# ---------------------------------------------------------------------------
# Note : dans un vrai scenario, le formulaire serait affiche en mode non-bloquant
# et le deploiement lance depuis un bouton. Ici on se contente de l'afficher.

Add-GuiLog 'Interface GUI PSWinDeploy chargee' 'OK'
Add-GuiLog 'Hooks, provider UI et override disque actifs' 'INFO'

# Pour afficher : $script:Form.Show()  (non-bloquant)
# ou $script:Form.ShowDialog() (bloquant)
