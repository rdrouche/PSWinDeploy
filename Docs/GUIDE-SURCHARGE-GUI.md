# PSWinDeploy - Guide de la surcharge graphique (GUI)

Ce guide explique comment remplacer les interactions console de PSWinDeploy par
une interface graphique (WinForms, WPF, ou autre), SANS modifier le coeur du
programme. Il couvre : le principe, les fonctions surchargeables, ou placer les
fichiers, et des exemples complets (selecteur d'OS en WinPE, selecteur de
sequence en post-deploiement, selection de logiciels a cocher).

---

## 1. Principe

PSWinDeploy utilise des fonctions d'interaction abstraites (module Hooks). Par
defaut, elles fonctionnent en CONSOLE. On peut les rediriger vers une GUI en
fournissant un "provider" : une table de scriptblocks, un par type
d'interaction. Toute interaction non surchargee reste en console.

Avantage : le coeur appelle toujours les memes fonctions (Request-PSWDString,
Show-PSWDList, ...). Selon qu'un provider est defini ou non, l'interaction est
graphique ou console. Aucune modification du moteur necessaire.

---

## 2. Ou placer les fichiers de surcharge

Au demarrage, PSWinDeploy cherche AUTOMATIQUEMENT un fichier de surcharge dans :

```
<Deploy>\Overrides\gui.ps1
<Deploy>\Overrides\overrides.ps1
<Deploy>\Overrides\PSWD-Override.ps1
<Deploy>\gui.ps1
<Deploy>\overrides.ps1
```

ou `<Deploy>` est X:\Deploy (WinPE), C:\Deploy (phase 2) ou W:\Deploy.
Le PREMIER trouve est charge (dot-source). Vous placez donc toute votre GUI
dans, par exemple : `\\serveur\Deploy\Overrides\gui.ps1`, et le build/SimpleDeploy
la copie avec le reste.

Si aucun fichier n'est trouve : comportement console normal. Rien ne casse.

Pour charger manuellement un profil :
```powershell
Import-PSWDOverrideProfile -Path 'X:\Deploy\Overrides\gui.ps1'
```

---

## 3. Les fonctions surchargeables (le provider)

On definit le provider avec `Set-PSWDUIProvider -Provider @{ ... }`. Les cles
(toutes optionnelles) :

| Cle            | Signature du scriptblock                         | Retour attendu        |
|----------------|--------------------------------------------------|-----------------------|
| AskString      | `{ param($Question,$Default) }`                  | [string]              |
| AskYesNo       | `{ param($Question,$Default) }`                  | [bool]                |
| AskSecret      | `{ param($Question) }`                           | [string] (mot de passe)|
| ShowList       | `{ param($Title,$Items) }`                       | [int] (index 0-based) |
| ShowMultiList  | `{ param($Title,$Items) }`                       | [int[]] (indices coches)|
| Notify         | `{ param($Message,$Level) }`                     | (rien)                |
| Progress       | `{ param($Percent,$Activity) }`                  | (rien)                |

Cote coeur, ces fonctions sont appelees ainsi (vous n'avez PAS a les modifier) :
- `Request-PSWDString  -Question '...' -Default '...'`  -> AskString
- `Request-PSWDYesNo   -Question '...' -Default $true`  -> AskYesNo
- `Request-PSWDSecret  -Question '...'`                 -> AskSecret
- `Show-PSWDList       -Title '...' -Items @(...)`       -> ShowList
- `Show-PSWDMultiList  -Title '...' -Items @(...)`       -> ShowMultiList
- `Write-PSWDNotify    -Message '...' -Level 'INFO'`     -> Notify
- `Write-PSWDProgress  -Percent 50 -Activity '...'`      -> Progress

---

## 4. Deux modes de surcharge

### Mode A : fonctions natives deja fournies (le plus simple)

PSWinDeploy fournit deja une implementation WinForms native pour la selection
multiple : `Show-PSWDMultiList` ouvre une fenetre a cases a cocher SANS que vous
ayez rien a coder. Idem, les listes/questions ont un repli console propre.

Donc pour la SELECTION DE LOGICIELS A COCHER, vous n'avez RIEN a faire : c'est
deja graphique des qu'une session interactive est disponible (assistant
post-installation). Voir section 6.

### Mode B : votre propre GUI (provider personnalise)

Si vous voulez VOTRE interface (charte graphique, WPF, logo...), vous fournissez
un provider. Vous ecrivez les scriptblocks qui affichent VOS fenetres et
retournent la valeur attendue. C'est l'objet des exemples ci-dessous.

---

## 5. Exemple complet : fichier Overrides\gui.ps1

Ce fichier, place dans `<Deploy>\Overrides\gui.ps1`, est charge automatiquement.
Il definit un provider WinForms pour les interactions principales.

```powershell
# Overrides\gui.ps1 -- surcharge graphique PSWinDeploy (WinForms)
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

Set-PSWDUIProvider -Provider @{

    # Question texte
    AskString = {
        param($Question, $Default)
        $f = New-Object System.Windows.Forms.Form
        $f.Text = 'PSWinDeploy'; $f.Size = '420,180'; $f.StartPosition = 'CenterScreen'; $f.TopMost = $true
        $l = New-Object System.Windows.Forms.Label; $l.Text = $Question; $l.AutoSize = $true; $l.Location = '12,15'
        $t = New-Object System.Windows.Forms.TextBox; $t.Text = "$Default"; $t.Location = '12,45'; $t.Size = '380,24'
        $b = New-Object System.Windows.Forms.Button; $b.Text = 'OK'; $b.Location = '300,90'; $b.DialogResult = 'OK'
        $f.Controls.AddRange(@($l,$t,$b)); $f.AcceptButton = $b
        [void]$f.ShowDialog()
        return $t.Text
    }

    # Question oui/non
    AskYesNo = {
        param($Question, $Default)
        $r = [System.Windows.Forms.MessageBox]::Show($Question, 'PSWinDeploy', 'YesNo', 'Question')
        return ($r -eq 'Yes')
    }

    # Mot de passe (masque)
    AskSecret = {
        param($Question)
        $f = New-Object System.Windows.Forms.Form
        $f.Text = 'PSWinDeploy'; $f.Size = '420,180'; $f.StartPosition = 'CenterScreen'; $f.TopMost = $true
        $l = New-Object System.Windows.Forms.Label; $l.Text = $Question; $l.AutoSize = $true; $l.Location = '12,15'
        $t = New-Object System.Windows.Forms.TextBox; $t.UseSystemPasswordChar = $true; $t.Location = '12,45'; $t.Size = '380,24'
        $b = New-Object System.Windows.Forms.Button; $b.Text = 'OK'; $b.Location = '300,90'; $b.DialogResult = 'OK'
        $f.Controls.AddRange(@($l,$t,$b)); $f.AcceptButton = $b
        [void]$f.ShowDialog()
        return $t.Text
    }

    # Liste a choix unique -> retourne l'index choisi
    ShowList = {
        param($Title, $Items)
        $f = New-Object System.Windows.Forms.Form
        $f.Text = $Title; $f.Size = '460,400'; $f.StartPosition = 'CenterScreen'; $f.TopMost = $true
        $lb = New-Object System.Windows.Forms.ListBox; $lb.Location = '12,12'; $lb.Size = '420,300'
        foreach ($it in $Items) { [void]$lb.Items.Add($it) }
        $lb.SelectedIndex = 0
        $b = New-Object System.Windows.Forms.Button; $b.Text = 'Choisir'; $b.Location = '340,325'; $b.DialogResult = 'OK'
        $f.Controls.AddRange(@($lb,$b)); $f.AcceptButton = $b
        [void]$f.ShowDialog()
        return [int]$lb.SelectedIndex
    }

    # Liste a cases a cocher -> retourne les index coches
    ShowMultiList = {
        param($Title, $Items)
        $f = New-Object System.Windows.Forms.Form
        $f.Text = $Title; $f.Size = '460,440'; $f.StartPosition = 'CenterScreen'; $f.TopMost = $true
        $clb = New-Object System.Windows.Forms.CheckedListBox; $clb.Location = '12,12'; $clb.Size = '420,340'; $clb.CheckOnClick = $true
        foreach ($it in $Items) { [void]$clb.Items.Add($it) }
        $b = New-Object System.Windows.Forms.Button; $b.Text = 'Valider'; $b.Location = '340,365'; $b.DialogResult = 'OK'
        $f.Controls.AddRange(@($clb,$b)); $f.AcceptButton = $b
        [void]$f.ShowDialog()
        $picked = @(); foreach ($i in $clb.CheckedIndices) { $picked += [int]$i }
        return $picked
    }

    # Notification
    Notify = {
        param($Message, $Level)
        # Exemple : ne rien afficher en popup, juste tracer. Adaptez a votre UI.
        Write-Host "[$Level] $Message"
    }

    # Progression
    Progress = {
        param($Percent, $Activity)
        Write-Progress -Activity $Activity -PercentComplete $Percent
    }
}
```

Avec ce fichier en place, toutes les interactions du deploiement passent par vos
fenetres. Si vous ne definissez que CERTAINES cles, les autres restent en console.

---

## 6. Exemple : selecteur de logiciels a cocher (deja natif)

Le coeur appelle deja `Show-PSWDMultiList` pour choisir les applications et les
scripts dans l'assistant post-installation. Sans aucune surcharge, une fenetre
WinForms a cases a cocher s'affiche (implementation native fournie).

Pour la PERSONNALISER (votre charte), surchargez `ShowMultiList` comme en
section 5. Le coeur passe `$Items` = liste de libelles (ex: "Chrome
[winget/choco]") et attend en retour les index coches.

---

## 7. Exemple : selecteur de sequence en post-deploiement

Pour proposer graphiquement le choix d'une sequence apres le deploiement, vous
pouvez soit surcharger `ShowList`, soit ecrire un OVERRIDE de fonction dediee.

### Via ShowList (simple)

L'assistant utilise deja `Show-PSWDList` pour ses menus. En definissant
`ShowList` dans le provider (section 5), votre fenetre s'affiche partout, y
compris pour le choix de sequence.

### Via un override de fonction nomme (avance)

Vous pouvez remplacer une fonction precise du coeur sans toucher au reste :

```powershell
# Dans Overrides\gui.ps1
Set-PSWDOverride -Name 'Select-DeploySequence' -ScriptBlock {
    param($SeqDir)
    $files = Get-ChildItem $SeqDir -Filter '*.psd1' -EA SilentlyContinue
    $labels = $files | ForEach-Object { $_.BaseName }
    $idx = Show-PSWDList -Title 'Choisir une sequence' -Items $labels
    return $files[$idx].FullName
}
```

Le coeur appelle alors votre version si elle est definie (via Invoke-PSWDFunction),
sinon sa version par defaut.

---

## 8. Exemple : selecteur d'OS en WinPE

En phase 1 (WinPE), pour choisir l'image Windows a deployer parmi plusieurs WIM :

```powershell
# Dans Overrides\gui.ps1 (charge aussi en WinPE si depose dans X:\Deploy\Overrides)
Set-PSWDOverride -Name 'Select-OSImage' -ScriptBlock {
    param($ImageShare)
    # Lister les .wim disponibles sur le partage Images
    $wims = Get-ChildItem $ImageShare -Filter '*.wim' -EA SilentlyContinue
    if (-not $wims) { return $null }
    $labels = $wims | ForEach-Object { $_.Name }
    $idx = Show-PSWDList -Title 'Choisir le systeme a deployer' -Items $labels
    return $wims[$idx].FullName
}
```

ATTENTION WinPE : WinForms fonctionne en WinPE SEULEMENT si le package
WinPE-NetFx (et eventuellement WinPE-PowerShell) est inclus dans l'image. Sinon,
restez sur le repli console (ne pas definir de provider GUI en WinPE, ou prevoir
un fallback). Les packages sont configures dans PSWinDeploy.psd1 (WinPEPackages).

---

## 9. Recapitulatif : comment integrer votre GUI

1. Creez `\\serveur\Deploy\Overrides\gui.ps1`.
2. Dedans, appelez `Set-PSWDUIProvider -Provider @{ ... }` avec les cles voulues
   (section 3), et/ou `Set-PSWDOverride -Name '...' -ScriptBlock { ... }` pour
   des fonctions precises (sections 7-8).
3. Le fichier est charge AUTOMATIQUEMENT au demarrage (Find-PSWDOverrideProfile).
4. Aucune modification du coeur. Pour revenir au mode console : supprimez le
   fichier ou appelez `Clear-PSWDUIProvider`.

### Fonctions disponibles dans votre GUI (rappel)

Vous pouvez appeler depuis vos scriptblocks toutes les fonctions du module
Hooks : Show-PSWDList, Show-PSWDMultiList, Request-PSWDString/YesNo/Secret,
Write-PSWDNotify, Write-PSWDProgress. Et lire la config via
Get-PSWinDeployConfig -Key '...'.
