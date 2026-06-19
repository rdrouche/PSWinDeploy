# Surcharge & GUI personnalisée — PSWinDeploy

PSWinDeploy expose une **couche de surcharge globale** qui permet de greffer
une interface graphique (WinForms, WPF, PrimalForms…) ou de modifier n'importe
quel comportement **sans toucher au code source**.

## Principe

Le module `Hooks.psm1` fournit trois mécanismes complémentaires :

| Mécanisme | Usage |
|-----------|-------|
| **Hooks (événements)** | Réagir aux étapes du déploiement (log, progression, début/fin d'étape) |
| **Provider UI** | Remplacer les prompts console par des boîtes de dialogue / formulaires |
| **Override de fonction** | Remplacer entièrement une fonction (ex: sélection disque) par sa version GUI |

## Chargement automatique

Au démarrage, PSWinDeploy cherche un fichier de surcharge dans :
- `Deploy\Overrides\gui.ps1`
- `Deploy\Overrides\overrides.ps1`
- `Deploy\overrides.ps1`

Le premier trouvé est chargé automatiquement. **Aucune modification du cœur n'est nécessaire.**

## Démarrage rapide

Créez `Deploy\Overrides\gui.ps1` :

```powershell
Add-Type -AssemblyName System.Windows.Forms

# 1. Rediriger les logs vers votre fenêtre
Register-PSWDHook -Event 'OnLog' -Action {
    param($Context)
    $maFenetre.LogBox.AppendText("$($Context.Message)`r`n")
}

# 2. Remplacer les prompts par des dialogues
Set-PSWDUIProvider -Provider @{
    AskYesNo = { param($Q,$D) [System.Windows.Forms.MessageBox]::Show($Q,'',"YesNo") -eq 'Yes' }
}

# 3. Surcharger la sélection de disque
Set-PSWDOverride -Name 'Select-TargetDisk' -ScriptBlock {
    Show-MonFormulaireDisque
}
```

## Événements disponibles

| Événement | Contexte fourni |
|-----------|-----------------|
| `OnDeployStart` | `SequencePath` |
| `OnDeployEnd` | — |
| `OnDeployError` | `Error` |
| `OnStepStart` | `StepId`, `StepName`, `StepType` |
| `OnStepEnd` | `StepId`, `Success`, `Duration` |
| `OnStepError` | `StepId`, `Error` |
| `OnProgress` | `Percent`, `Activity` |
| `OnReboot` | `NextStep` |
| `OnDiskFormat` | `DiskNumber` |
| `OnWIMApply` | `WimPath`, `Index` |
| `OnLog` | `Message`, `Level` |

Lister à tout moment : `Get-PSWDHookEvents`

## Provider UI — clés supportées

```powershell
Set-PSWDUIProvider -Provider @{
    AskString = { param($Question, $Default) ... return [string] }
    AskYesNo  = { param($Question, $Default) ... return [bool]   }
    AskSecret = { param($Question)           ... return [string] }
    ShowList  = { param($Title, $Items)      ... return [int]    }  # index 0-based
    Notify    = { param($Message, $Level)    ... }
    Progress  = { param($Percent, $Activity) ... }
}
```

Toute clé absente retombe automatiquement sur le comportement console.

## Override de fonctions

```powershell
# Remplacer
Set-PSWDOverride -Name 'Select-TargetDisk' -ScriptBlock { ... }

# Vérifier
Test-PSWDOverride -Name 'Select-TargetDisk'

# Retirer
Remove-PSWDOverride -Name 'Select-TargetDisk'
Remove-PSWDOverride -All
```

## Créer une GUI avec PrimalForms / Visual Studio

1. Construisez votre formulaire dans l'éditeur de votre choix
2. Exportez le code PowerShell du formulaire
3. Ajoutez les `Register-PSWDHook` / `Set-PSWDUIProvider` / `Set-PSWDOverride`
4. Placez le tout dans `Deploy\Overrides\gui.ps1`

Voir `exemple-gui-winforms.ps1` pour un modèle complet et fonctionnel.

## Tester sans déploiement réel

```powershell
Import-Module .\Modules\Hooks\Hooks.psm1

# Simuler des événements
Register-PSWDHook -Event 'OnLog' -Action { param($c) Write-Host "GUI: $($c.Message)" }
Invoke-PSWDHook -Event 'OnLog' -Context @{ Message = 'Test'; Level = 'OK' }
```
