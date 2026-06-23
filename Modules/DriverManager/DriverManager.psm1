# DriverManager.psm1 -- Selection et injection de drivers.
#
# Deux usages :
#   1. Phase 1 (WinPE) : choisir un dossier MODELE sur \\srv\Drivers et injecter
#      les drivers sur l'image Windows OFFLINE (W:\) avant le 1er boot.
#   2. Assistant ISO/USB : charger des drivers depuis un autre support (2e ISO,
#      cle USB) DANS le WinPE en cours (drvload/pnputil), utile quand WinPE ne
#      voit pas le disque (ex: VirtIO/Proxmox) et qu'on n'a pas rebuild le WinPE.

Set-StrictMode -Version Latest

function Write-DrvLog {
    param([string]$Message, [string]$Level = 'INFO')
    $color = switch ($Level) { 'SUCCESS' {'Green'} 'WARN' {'Yellow'} 'ERROR' {'Red'} 'STEP' {'Cyan'} default {'Gray'} }
    Write-Host $Message -ForegroundColor $color
}

function Get-DriverModelFolders {
    <#
    .SYNOPSIS Liste les dossiers MODELE dans la racine Drivers (hors WinPE).
    .DESCRIPTION
        Chaque sous-dossier de \\srv\Drivers (sauf 'WinPE') est considere comme
        un modele (hp-probook-450, dell-optiplex-7090...). Retourne la liste avec
        le nombre de .inf trouves dans chacun.
    #>
    param([Parameter(Mandatory)][string]$DriversRoot)
    Write-DrvLog "  [diag] Scan du dossier drivers : '$DriversRoot'" 'INFO'
    if (-not (Test-Path $DriversRoot -EA SilentlyContinue)) {
        Write-DrvLog "  [diag] Test-Path NEGATIF : '$DriversRoot' inaccessible." 'WARN'
        return @()
    }
    # Liste simple (pas d'ArrayList : evite les soucis de retour/imbrication).
    $result = @()
    # Exclure le dossier WinPE (reserve aux drivers du WinPE lui-meme), insensible
    # a la casse. Get-ChildItem -Directory ne retourne que des dossiers.
    $folders = @(Get-ChildItem -LiteralPath $DriversRoot -Directory -Force -EA SilentlyContinue)
    Write-DrvLog "  [diag] $($folders.Count) sous-dossier(s) trouve(s)." 'INFO'
    foreach ($f in $folders) {
        $fName = if ($f.PSObject.Properties['Name']) { "$($f.Name)" } else { '' }
        $fPath = if ($f.PSObject.Properties['FullName']) { "$($f.FullName)" } else { '' }
        Write-DrvLog "  [diag]  - dossier: '$fName' ($fPath)" 'INFO'
        if (-not $fName -or -not $fPath) { Write-DrvLog "  [diag]    -> ignore (nom/chemin vide)" 'WARN'; continue }
        # Exclure WinPE (toute casse) -- c'est le dossier des drivers du WinPE.
        if ($fName -ieq 'WinPE') { Write-DrvLog "  [diag]    -> exclu (WinPE)" 'INFO'; continue }
        $infItems = @(Get-ChildItem -LiteralPath $fPath -Filter '*.inf' -Recurse -Force -EA SilentlyContinue)
        $infCount = $infItems.Count
        Write-DrvLog "  [diag]    -> $infCount fichier(s) .inf" 'INFO'
        $result += [PSCustomObject]@{
            Name     = $fName
            Path     = $fPath
            InfCount = $infCount
        }
    }
    Write-DrvLog "  [diag] $(@($result).Count) modele(s) retenu(s)." 'INFO'
    # RETOUR DIRECT (sans ,@()) : l'appelant fait deja @(...) qui re-emballe en
    # array. Utiliser ,@($result) ici creait une DOUBLE imbrication (un array
    # contenant l'array) -> l'appelant recevait 1 element de type Object[].
    # PowerShell deroule $result a l'enumeration ; @(...) cote appelant rebatit
    # l'array correctement (0->vide, 1->1 elem, N->N elems).
    return $result
}

function Show-DriverFolderPicker {
    <#
    .SYNOPSIS Fenetre GUI (WinForms) avec un bouton radio par dossier modele.
        Retourne l'index choisi (0-based) ou -1 si annule/aucun.
    .DESCRIPTION
        Une seule selection possible (boutons radio). Bouton OK / Annuler.
        Si WinForms n'est pas disponible (WinPE minimal), retourne $null pour
        que l'appelant bascule en mode console.
    #>
    param(
        [string]$Title = 'Selection des drivers',
        [string[]]$Labels
    )
    $Labels = @($Labels)
    Write-DrvLog "  [diag] GUI : $($Labels.Count) label(s) recu(s) : $($Labels -join ' | ')" 'INFO'
    if (-not $Labels -or $Labels.Count -eq 0) { return -1 }

    try {
        Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
        Add-Type -AssemblyName System.Drawing -ErrorAction Stop
    } catch {
        # WinForms indisponible -> signaler a l'appelant (bascule console)
        Write-DrvLog "  [diag] WinForms indisponible -> bascule console." 'WARN'
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
        $label.Text = 'Choisissez le modele de drivers a injecter :'
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

        # Case "Aucun"
        $rbNone = New-Object System.Windows.Forms.RadioButton
        $rbNone.Text = 'Aucun (ne pas injecter de drivers)'
        $rbNone.Location = New-Object System.Drawing.Point(10, $y)
        $rbNone.AutoSize = $true
        $rbNone.Tag = '-1'
        $panel.Controls.Add($rbNone)
        [void]$radios.Add($rbNone)

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

function Select-DriverModel {
    <#
    .SYNOPSIS Demande a l'utilisateur de choisir UN dossier modele (GUI si dispo,
        sinon liste console). Retourne le chemin choisi, ou $null.
    #>
    param([Parameter(Mandatory)][string]$DriversRoot)

    $rawModels = @(Get-DriverModelFolders -DriversRoot $DriversRoot)
    Write-DrvLog "  [diag] Select : rawModels.Count = $($rawModels.Count)" 'INFO'
    for ($k = 0; $k -lt $rawModels.Count; $k++) {
        $rm = $rawModels[$k]
        $tn = if ($null -eq $rm) { '<null>' } else { $rm.GetType().Name }
        $nmv = ''
        if ($rm -and $rm.PSObject -and $rm.PSObject.Properties['Name']) { $nmv = "$($rm.Name)" }
        Write-DrvLog "  [diag]   rawModels[$k] type=$tn name='$nmv'" 'INFO'
    }

    # FILTRER : ne garder que les entrees ayant un Name ET un Path non vides.
    # On NE teste PAS le type exact (PSCustomObject) car selon le retour PowerShell
    # le type peut varier -- on teste juste que les proprietes existent et sont
    # remplies. Cela neutralise les valeurs parasites (int, $null) sans rejeter
    # les vrais objets.
    # Aplatir : si un element est lui-meme un tableau (securite anti-imbrication),
    # on deroule pour traiter ses elements.
    $flat = @()
    foreach ($item in $rawModels) {
        if ($item -is [System.Array] -or $item -is [System.Collections.IEnumerable] -and -not ($item -is [string]) -and -not ($item -is [hashtable])) {
            foreach ($sub in $item) { $flat += $sub }
        } else {
            $flat += $item
        }
    }

    $models = @()
    foreach ($m in $flat) {
        if ($null -eq $m) { continue }
        # Lire Name et Path de facon sure (objet OU hashtable)
        $mName = $null; $mPath = $null
        if ($m -is [hashtable] -or $m -is [System.Collections.IDictionary]) {
            if ($m.Contains('Name')) { $mName = $m['Name'] }
            if ($m.Contains('Path')) { $mPath = $m['Path'] }
        } else {
            $pn = $m.PSObject.Properties['Name']; if ($pn) { $mName = $pn.Value }
            $pp = $m.PSObject.Properties['Path']; if ($pp) { $mPath = $pp.Value }
        }
        if ([string]::IsNullOrWhiteSpace("$mName")) { continue }
        if ([string]::IsNullOrWhiteSpace("$mPath")) { continue }
        $models += $m
    }
    Write-DrvLog "  [diag] Select : $(@($models).Count) modele(s) valide(s) apres filtrage." 'INFO'

    if (@($models).Count -eq 0) {
        Write-DrvLog "Aucun dossier modele valide dans $DriversRoot." 'WARN'
        return $null
    }

    # Construire les libelles (objets deja valides).
    $labels = @()
    foreach ($m in $models) {
        $nm = "$($m.Name)"
        $ic = 0
        if ($m.PSObject.Properties['InfCount']) { $ic = [int]$m.InfCount }
        $labels += ("{0}  [{1} .inf]" -f $nm, $ic)
    }

    # 1) GUI WinForms a boutons radio (la methode preferee).
    $guiChoice = Show-DriverFolderPicker -Title 'Selection des drivers' -Labels $labels
    if ($null -ne $guiChoice) {
        # La GUI a fonctionne (-1 = annule/aucun, >=0 = index choisi)
        if ($guiChoice -lt 0 -or $guiChoice -ge $models.Count) { return $null }
        $sel = $models[$guiChoice]
        if ($sel -and $sel.PSObject.Properties['Path']) { return "$($sel.Path)" }
        return $null
    }
    # $guiChoice == $null -> WinForms indisponible -> bascule console.

    # 2) Repli console
    Write-DrvLog "" 'INFO'
    Write-DrvLog "Modeles de drivers disponibles :" 'STEP'
    for ($i = 0; $i -lt $models.Count; $i++) {
        Write-DrvLog ("  [{0}] {1}" -f ($i+1), $labels[$i]) 'INFO'
    }
    Write-DrvLog "  [0] Aucun (ne pas injecter)" 'INFO'
    $selInput = (Read-Host "  Votre choix").Trim()
    if ($selInput -eq '0' -or -not $selInput) { return $null }
    $idx = 0
    if ([int]::TryParse($selInput, [ref]$idx) -and $idx -ge 1 -and $idx -le $models.Count) {
        $sel = $models[$idx - 1]
        if ($sel -and $sel.PSObject.Properties['Path']) { return "$($sel.Path)" }
        return $null
    }
    Write-DrvLog "Choix invalide -- aucun driver injecte." 'WARN'
    return $null
}

function Add-OfflineDrivers {
    <#
    .SYNOPSIS Injecte tous les drivers d'un dossier dans une image Windows OFFLINE
        (ex: W:\ apres application du WIM, avant le 1er boot). Recursif.
    .PARAMETER ImagePath  racine de l'image montee/appliquee (ex: 'W:\')
    .PARAMETER DriverPath dossier contenant les .inf (sous-dossiers parcourus)
    #>
    param(
        [Parameter(Mandatory)][string]$ImagePath,
        [Parameter(Mandatory)][string]$DriverPath
    )
    if (-not (Test-Path $DriverPath -EA SilentlyContinue)) {
        Write-DrvLog "Dossier drivers introuvable : $DriverPath" 'WARN'
        return $false
    }
    $infCount = @(Get-ChildItem $DriverPath -Filter '*.inf' -Recurse -EA SilentlyContinue).Count
    if ($infCount -eq 0) {
        Write-DrvLog "Aucun .inf dans $DriverPath" 'WARN'
        return $false
    }
    Write-DrvLog "Injection de $infCount driver(s) dans l'image offline ($ImagePath)..." 'STEP'

    # DISM ne gere pas toujours les chemins UNC -> copier en local si besoin.
    $srcPath = $DriverPath
    $tempCopy = $null
    if ($DriverPath -like '\\*') {
        $tempCopy = Join-Path $env:TEMP ("drv_" + [System.Guid]::NewGuid().ToString('N').Substring(0,8))
        try {
            New-Item -ItemType Directory $tempCopy -Force -EA SilentlyContinue | Out-Null
            Copy-Item (Join-Path $DriverPath '*') $tempCopy -Recurse -Force -EA SilentlyContinue
            $srcPath = $tempCopy
            Write-DrvLog "  Drivers copies en local (UNC -> $tempCopy)" 'INFO'
        } catch { $srcPath = $DriverPath }
    }

    try {
        $dismArgs = @("/Image:$ImagePath", '/Add-Driver', "/Driver:$srcPath", '/Recurse', '/ForceUnsigned')
        $out = & dism.exe @dismArgs 2>&1
        $code = $LASTEXITCODE
        if ($code -eq 0) {
            Write-DrvLog "Drivers injectes avec succes dans l'image offline." 'SUCCESS'
            $ok = $true
        } else {
            Write-DrvLog "DISM a retourne le code $code." 'WARN'
            Write-DrvLog ("$out" | Select-Object -Last 1) 'WARN'
            $ok = $false
        }
    } catch {
        Write-DrvLog "Erreur injection offline : $_" 'ERROR'
        $ok = $false
    } finally {
        if ($tempCopy -and (Test-Path $tempCopy -EA SilentlyContinue)) {
            Remove-Item $tempCopy -Recurse -Force -EA SilentlyContinue
        }
    }
    return $ok
}

function Get-RemovableDriveLetters {
    <#
    .SYNOPSIS Liste les lettres de lecteurs amovibles/CD (pour chercher des
        drivers sur un 2e ISO ou une cle USB depuis WinPE).
    #>
    $drives = @()
    try {
        # CD/DVD (type 5) et amovibles (type 2)
        $vols = Get-WmiObject Win32_LogicalDisk -EA SilentlyContinue |
                Where-Object { $_.DriveType -eq 5 -or $_.DriveType -eq 2 }
        foreach ($v in $vols) {
            if ($v.DeviceID) { $drives += $v.DeviceID }
        }
    } catch {}
    # Repli : scanner les lettres et tester la presence de fichiers
    if ($drives.Count -eq 0) {
        foreach ($l in [char[]](68..90)) {  # D..Z
            $root = "${l}:\"
            if (Test-Path $root -EA SilentlyContinue) { $drives += "${l}:" }
        }
    }
    return $drives
}

function Import-DriversFromMedia {
    <#
    .SYNOPSIS ASSISTANT : charge des drivers depuis un autre support (2e ISO, USB)
        DANS le WinPE en cours d'execution. Utile quand WinPE ne voit pas le disque
        (VirtIO/Proxmox) et qu'on n'a pas rebuild le WinPE avec les bons drivers.
    .DESCRIPTION
        Scanne les lecteurs amovibles/CD, cherche les .inf, et les charge a chaud
        avec drvload (immediat) + pnputil (persistant dans la session WinPE).
        Apres ca, les disques/NIC apparaissent et on peut continuer le deploiement.
    #>
    param([string]$SubPath = '')

    Write-DrvLog "=== Assistant : chargement de drivers depuis un support externe ===" 'STEP'
    $drives = @(Get-RemovableDriveLetters)
    if ($drives.Count -eq 0) {
        Write-DrvLog "Aucun lecteur amovible/CD detecte." 'WARN'
        return $false
    }

    # Chercher les dossiers contenant des .inf sur ces lecteurs
    $candidates = [System.Collections.ArrayList]::new()
    foreach ($d in $drives) {
        $searchRoot = if ($SubPath) { Join-Path "$d\" $SubPath } else { "$d\" }
        if (-not (Test-Path $searchRoot -EA SilentlyContinue)) { continue }
        $infs = @(Get-ChildItem $searchRoot -Filter '*.inf' -Recurse -EA SilentlyContinue)
        if ($infs.Count -gt 0) {
            [void]$candidates.Add([PSCustomObject]@{ Drive = $d; Root = $searchRoot; InfCount = $infs.Count })
        }
    }
    $candidates = @($candidates.ToArray())
    if ($candidates.Count -eq 0) {
        Write-DrvLog "Aucun driver (.inf) trouve sur les supports detectes." 'WARN'
        Write-DrvLog "Lecteurs scannes : $($drives -join ', ')" 'INFO'
        return $false
    }

    Write-DrvLog "" 'INFO'
    Write-DrvLog "Drivers trouves :" 'STEP'
    for ($i = 0; $i -lt $candidates.Count; $i++) {
        Write-DrvLog ("  [{0}] {1}  ({2} .inf)" -f ($i+1), $candidates[$i].Root, $candidates[$i].InfCount) 'INFO'
    }
    Write-DrvLog "  [0] Annuler" 'INFO'
    $sel = (Read-Host "  Charger quels drivers").Trim()
    if ($sel -eq '0' -or -not $sel) { return $false }
    $idx = 0
    if (-not ([int]::TryParse($sel, [ref]$idx)) -or $idx -lt 1 -or $idx -gt $candidates.Count) {
        Write-DrvLog "Choix invalide." 'WARN'; return $false
    }
    $chosen = $candidates[$idx - 1]

    Write-DrvLog "Chargement des drivers depuis $($chosen.Root)..." 'STEP'
    $loaded = 0
    foreach ($inf in Get-ChildItem $chosen.Root -Filter '*.inf' -Recurse -EA SilentlyContinue) {
        try {
            # drvload : charge le driver IMMEDIATEMENT dans le WinPE en cours.
            $null = & drvload.exe $inf.FullName 2>&1
            if ($LASTEXITCODE -eq 0) { $loaded++ }
        } catch {}
    }
    # pnputil en complement (ajoute au store de pilotes de la session)
    try { & pnputil.exe /add-driver (Join-Path $chosen.Root '*.inf') /subdirs 2>&1 | Out-Null } catch {}

    Write-DrvLog "$loaded driver(s) charge(s). Les disques/NIC devraient maintenant apparaitre." 'SUCCESS'
    Write-DrvLog "Astuce : relancez la detection de disque si necessaire." 'INFO'
    return ($loaded -gt 0)
}

Export-ModuleMember -Function @(
    'Show-DriverFolderPicker'
    'Get-DriverModelFolders'
    'Select-DriverModel'
    'Add-OfflineDrivers'
    'Get-RemovableDriveLetters'
    'Import-DriversFromMedia'
)
