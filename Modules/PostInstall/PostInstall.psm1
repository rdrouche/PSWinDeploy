#Requires -Version 5.1
<#
.SYNOPSIS
    PSWinDeploy.PostInstall -- Assistant de post-installation (phase 2 Windows).
.DESCRIPTION
    S'execute APRES le 1er boot Windows. Deux scenarios :

      SCENARIO A : une sequence est deja affectee au poste (fichier
                   <prefixe>-<MAC>.psd1 sur le partage). On la deroule.

      SCENARIO B : rien de prevu -> assistant interactif :
                     [1] Partir d'un modele de sequence
                     [2] Construire a la volee (apps / MAJ / scripts)
                   Les choix sont faits EN UNE FOIS, puis tout est execute.

    Gestion des reboots : tant que la sequence n'est pas terminee, l'assistant
    (ou la reprise) reprend apres chaque redemarrage.

    SURCHARGE GUI : utilise les fonctions Request-PSWDString / Show-PSWDList /
    Request-PSWDYesNo / Write-PSWDNotify du module Hooks. Sans provider GUI,
    fonctionne en console. Avec un provider, l'interface graphique remplace les
    prompts -- AUCUNE modif de ce module necessaire.
#>

Set-StrictMode -Version Latest

$script:PostInstallLog = 'C:\Deploy\Logs\postinstall.log'

function Write-PILog {
    param([string]$Message, [string]$Level = 'INFO')
    $line = "[$([DateTime]::Now.ToString('HH:mm:ss'))] [$Level] $Message"
    try {
        $d = Split-Path $script:PostInstallLog -Parent
        if (-not (Test-Path $d)) { New-Item -ItemType Directory $d -Force -EA SilentlyContinue | Out-Null }
        Add-Content -Path $script:PostInstallLog -Value $line -Encoding UTF8 -EA SilentlyContinue
    } catch {}
    # Passer par la couche Hooks si dispo (pour journalisation GUI), sinon console
    if (Get-Command Write-PSWDNotify -EA SilentlyContinue) {
        Write-PSWDNotify $Message $Level
    } else {
        Write-Host "  $line"
    }
}

function Get-PrimaryMacAddress {
    <#
    .SYNOPSIS Retourne la MAC de la carte active principale, format AABBCCDDEEFF
        (sans separateur, majuscules). Ce format DOIT etre identique a celui du
        resolver (SequenceResolver) pour que les sequences by-mac soient trouvees.
    #>
    try {
        $adapters = Get-CimInstance Win32_NetworkAdapter -EA SilentlyContinue |
            Where-Object { $_.PhysicalAdapter -and $_.MACAddress -and $_.NetEnabled }
        if (-not $adapters) {
            $adapters = Get-CimInstance Win32_NetworkAdapter -EA SilentlyContinue |
                Where-Object { $_.MACAddress }
        }
        $mac = ($adapters | Select-Object -First 1).MACAddress
        # Format UNIFIE : retirer TOUT separateur (: ou -) et passer en majuscules.
        if ($mac) { return ($mac -replace '[:-]', '').ToUpper() }
    } catch {}
    return $null
}

function Resolve-PostInstallSequence {
    <#
    .SYNOPSIS Cherche une sequence affectee au poste (par MAC) sur le partage.
    .DESCRIPTION
        Ordre de resolution (du plus specifique au plus general) :
          1. <SeqDir>\by-name\<COMPUTERNAME>.psd1  (specifique au nom de machine)
          2. <SeqDir>\by-mac\<MAC>.psd1            (specifique a la carte reseau)
          3. <SeqDir>\_default.psd1                 (defaut general)
        Retourne le chemin trouve, ou $null.
    .PARAMETER SeqDir Dossier des sequences sur le partage (\\serveur\Deploy\Sequences).
    #>
    param([string]$SeqDir)
    if (-not $SeqDir -or -not (Test-Path $SeqDir -EA SilentlyContinue)) { return $null }

    # 1) Par NOM de machine (le plus simple a gerer pour l'operateur)
    $name = $env:COMPUTERNAME
    if ($name) {
        $byName = Join-Path $SeqDir "by-name\$name.psd1"
        if (Test-Path $byName -EA SilentlyContinue) {
            Write-PILog "Sequence trouvee pour le nom '$name' : $byName" 'OK'
            return $byName
        }
        Write-PILog "Pas de sequence specifique pour le nom '$name'" 'INFO'
    }

    # 2) Par adresse MAC
    $mac = Get-PrimaryMacAddress
    if ($mac) {
        $byMac = Join-Path $SeqDir "by-mac\$mac.psd1"
        if (Test-Path $byMac -EA SilentlyContinue) {
            Write-PILog "Sequence trouvee pour la MAC $mac : $byMac" 'OK'
            return $byMac
        }
        Write-PILog "Pas de sequence specifique pour la MAC $mac" 'INFO'
    }

    # 3) Sequence par defaut
    $def = Join-Path $SeqDir '_default.psd1'
    if (Test-Path $def -EA SilentlyContinue) {
        Write-PILog "Sequence par defaut utilisee : $def" 'OK'
        return $def
    }
    return $null
}

function Test-PostInstallSequenceExists {
    <#
    .SYNOPSIS Indique si une sequence est affectee a ce poste (sans l'executer).
        Retourne un objet @{ Found; Path; By } pour informer l'operateur.
    #>
    param([string]$SeqDir)
    $r = @{ Found = $false; Path = $null; By = $null }
    if (-not $SeqDir -or -not (Test-Path $SeqDir -EA SilentlyContinue)) { return $r }
    $name = $env:COMPUTERNAME
    if ($name) {
        $p = Join-Path $SeqDir "by-name\$name.psd1"
        if (Test-Path $p -EA SilentlyContinue) { return @{ Found=$true; Path=$p; By="nom ($name)" } }
    }
    $mac = Get-PrimaryMacAddress
    if ($mac) {
        $p = Join-Path $SeqDir "by-mac\$mac.psd1"
        if (Test-Path $p -EA SilentlyContinue) { return @{ Found=$true; Path=$p; By="MAC ($mac)" } }
    }
    $p = Join-Path $SeqDir '_default.psd1'
    if (Test-Path $p -EA SilentlyContinue) { return @{ Found=$true; Path=$p; By='_default' } }
    return $r
}

function New-PostInstallSequenceFromTemplate {
    <#
    .SYNOPSIS Copie un modele de sequence en le nommant par MAC (unique au poste).
    .DESCRIPTION
        Cree <SeqDir>\by-mac\<MAC>.psd1 a partir du modele choisi. Ce fichier
        unique pourra aussi etre provisionne par l'API web avant deploiement.
    .PARAMETER TemplatePath Chemin du modele de sequence.
    .PARAMETER SeqDir Dossier des sequences (pour y deposer la copie par MAC).
    .OUTPUTS Chemin de la copie creee (ou $null).
    #>
    param([string]$TemplatePath, [string]$SeqDir)
    if (-not (Test-Path $TemplatePath -EA SilentlyContinue)) { return $null }
    $mac = Get-PrimaryMacAddress
    if (-not $mac) { $mac = "UNKNOWN-$(Get-Random -Maximum 99999)" }

    $byMacDir = Join-Path $SeqDir 'by-mac'
    if (-not (Test-Path $byMacDir)) { New-Item -ItemType Directory $byMacDir -Force -EA SilentlyContinue | Out-Null }
    $dest = Join-Path $byMacDir "$mac.psd1"
    try {
        Copy-Item $TemplatePath $dest -Force
        Write-PILog "Modele copie pour ce poste : $dest" 'OK'
        return $dest
    } catch {
        Write-PILog "Copie du modele echouee : $_" 'ERROR'
        return $null
    }
}

function Show-PostInstallWizard {
    <#
    .SYNOPSIS Assistant interactif (scenario B) : aucune sequence prevue.
    .DESCRIPTION
        Propose : [1] partir d'un modele, [2] construire a la volee.
        Retourne le chemin d'une sequence prete a executer (.psd1), ou $null si
        l'operateur choisit de ne rien faire.
        Utilise les fonctions Hooks (surchargeable GUI).
    .PARAMETER SeqDir Dossier des modeles de sequence disponibles.
    .PARAMETER RuntimeDir Ou ecrire la sequence construite (C:\Deploy\Runtime).
    #>
    param([string]$SeqDir, [string]$RuntimeDir = 'C:\Deploy\Runtime', [string]$ScriptShare = '', [string]$SoftwareShare = '', [string]$CatalogueShare = '')

    Write-PILog "=== Menu de deploiement -- Que souhaitez-vous faire ? ===" 'STEP'

    $choice = Show-PSWDList -Title "Menu de deploiement -- Que souhaitez-vous faire ?" -Items @(
        'Partir d''un modele de sequence',
        'Construire a la volee (applications / MAJ / scripts)',
        'Attendre une sequence poussee depuis l''interface web',
        'Terminer le deploiement (nettoie C:\Deploy, garde Logs)',
        'Quitter SANS nettoyer (laisse C:\Deploy intact)'
    )

    switch ($choice) {
        0 { return (Select-TemplateSequence -SeqDir $SeqDir) }
        1 { return (Build-SequenceInteractive -RuntimeDir $RuntimeDir -ScriptShare $ScriptShare -SoftwareShare $SoftwareShare -CatalogueShare $CatalogueShare) }
        2 {
            # Mode "en attente" : le poste va poller l'API et jouer la sequence
            # poussee depuis l'interface web. La boucle d'attente est geree par
            # l'appelant (Start-Deploy), qui dispose de l'URL/token API.
            Write-PILog "Mode attente : en attente d'une sequence depuis l'interface web." 'STEP'
            return @{ __action = 'wait-web' }
        }
        3 {
            # Terminer = nettoyer (comportement par defaut souhaite)
            Invoke-PostInstallCleanup
            return @{ __action = 'done-cleaned' }
        }
        4 {
            Write-PILog "Quitter sans nettoyer : C:\Deploy laisse intact." 'INFO'
            return @{ __action = 'done-nocleanup' }
        }
        default {
            # Par defaut (Echap / rien) = terminer ET nettoyer, comme convenu.
            Write-PILog "Fin par defaut : nettoyage de C:\Deploy." 'INFO'
            Invoke-PostInstallCleanup
            return @{ __action = 'done-cleaned' }
        }
    }
}

function Invoke-PostInstallCleanup {
    <#
    .SYNOPSIS Nettoyage de fin depuis l'assistant : supprime les fichiers sensibles
        de C:\Deploy, conserve C:\Deploy\Logs. Equivalent du step 'Cleanup'.
    #>
    Write-PILog "Nettoyage de fin de deploiement (C:\Deploy)..." 'STEP'
    $root = 'C:\Deploy'
    if (-not (Test-Path $root)) { return }
    try { Unregister-ScheduledTask -TaskName 'PSWinDeployResume' -Confirm:`$false -EA SilentlyContinue | Out-Null } catch {}

    # Supprimer d'abord les fichiers sensibles (vault, config, state) -- toujours
    # possible. Les dossiers Scripts/Modules/Runtime contiennent le script en cours
    # d'execution : on ne peut PAS les supprimer maintenant (fichier verrouille).
    # On les marque pour suppression au prochain boot (ou on previent l'operateur).
    $deletedNow = @()
    $deferred   = @()
    foreach ($item in @('secrets.vault.psd1','secrets.vault','deploy-config.psd1','PSWinDeploy.psd1','state.psd1')) {
        $p = Join-Path $root $item
        if (Test-Path $p -EA SilentlyContinue) {
            try {
                Remove-Item $p -Recurse -Force -EA Stop
                $deletedNow += $item
            } catch { $deferred += $item }
        }
    }
    # Dossiers : tenter, mais ne PAS pretendre avoir reussi si echec (script actif).
    foreach ($item in @('Runtime','Modules','Scripts')) {
        $p = Join-Path $root $item
        if (Test-Path $p -EA SilentlyContinue) {
            try {
                Remove-Item $p -Recurse -Force -EA Stop
                $deletedNow += $item
            } catch { $deferred += $item }
        }
    }
    # Marqueurs internes
    foreach ($mk in @('.domain-joined','.current-step','.updates-passes','.resume-lock')) {
        try { Remove-Item (Join-Path $root "Logs\$mk") -Force -EA SilentlyContinue } catch {}
    }

    foreach ($d in $deletedNow) { Write-PILog "  Supprime : $d" 'INFO' }
    if ($deferred.Count -gt 0) {
        # Programmer la suppression des dossiers restants au prochain demarrage
        # (le script ne sera plus en cours d'execution). On utilise une tache
        # one-shot qui supprime puis se supprime elle-meme.
        try {
            $delList = ($deferred | ForEach-Object { "'$root\$_'" }) -join ','
            $cmd = "Start-Sleep 5; Remove-Item $delList -Recurse -Force -EA SilentlyContinue; Unregister-ScheduledTask -TaskName 'PSWinDeployFinalClean' -Confirm:`$false -EA SilentlyContinue"
            $psExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
            $act = New-ScheduledTaskAction -Execute $psExe -Argument "-NoProfile -ExecutionPolicy Bypass -Command `"$cmd`""
            $trg = New-ScheduledTaskTrigger -AtStartup
            $prn = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
            Register-ScheduledTask -TaskName 'PSWinDeployFinalClean' -Action $act -Trigger $trg -Principal $prn -Force -EA SilentlyContinue | Out-Null
            Write-PILog "  Dossiers restants ($($deferred -join ', ')) : suppression programmee au prochain demarrage." 'INFO'
        } catch {
            Write-PILog "  Dossiers restants ($($deferred -join ', ')) : a supprimer manuellement (script en cours d'execution)." 'WARN'
        }
    }
    Write-PILog "Nettoyage termine. Logs conserves : C:\Deploy\Logs" 'OK'
}

function Select-TemplateSequence {
    param([string]$SeqDir)
    if (-not $SeqDir -or -not (Test-Path $SeqDir -EA SilentlyContinue)) {
        Write-PILog "Aucun dossier de modeles disponible ($SeqDir)" 'WARN'
        return $null
    }
    $templates = @(Get-ChildItem $SeqDir -Filter '*.psd1' -EA SilentlyContinue | Sort-Object Name)
    if ($templates.Count -eq 0) {
        Write-PILog "Aucun modele de sequence trouve dans $SeqDir" 'WARN'
        return $null
    }
    # Selecteur GUI radio si disponible (meme fenetre que OS/Drivers), sinon liste.
    $idx = -1
    if (Get-Command Show-PSWDRadioPicker -EA SilentlyContinue) {
        $pick = Show-PSWDRadioPicker -Title 'Sequence' -Prompt 'Choisissez une sequence existante :' -Labels ($templates.BaseName)
        if ($null -ne $pick -and $pick -ge 0) { $idx = $pick }
    }
    if ($idx -lt 0) {
        $idx = Show-PSWDList -Title "Choisir un modele de sequence" -Items ($templates.BaseName)
    }
    if ($idx -lt 0 -or $idx -ge $templates.Count) { return $null }
    $chosen = $templates[$idx].FullName

    # Copier la sequence choisie DIRECTEMENT EN LOCAL (Runtime). On ne la
    # recopie PAS sur le serveur : elle y est deja, et le moteur travaille sur
    # la copie locale C:\Deploy\Runtime\sequence.psd1. (La copie par MAC sur le
    # serveur etait inutile pour une selection manuelle -- reservee a un futur
    # provisioning par API.)
    $localSeq = 'C:\Deploy\Runtime\sequence.psd1'
    try {
        $rtDir = Split-Path $localSeq -Parent
        if (-not (Test-Path $rtDir)) { New-Item -ItemType Directory $rtDir -Force -EA SilentlyContinue | Out-Null }
        Copy-Item $chosen $localSeq -Force -EA Stop
        Write-PILog "Sequence copiee en local : $localSeq" 'OK'
        return $localSeq
    } catch {
        Write-PILog "Copie locale echouee : $_ -- utilisation directe du modele." 'WARN'
        return $chosen
    }
}

function Build-SequenceInteractive {
    <#
    .SYNOPSIS Construit une sequence "a la volee" : choix groupes puis generation.
    .DESCRIPTION
        Demande EN UNE FOIS : MAJ Windows ? applications ? scripts ? Puis genere
        une sequence .psd1 dans RuntimeDir, avec les steps correspondants et la
        gestion des reboots (InstallUpdates -> RebootAfter IfRequired).
    #>
    param([string]$RuntimeDir = 'C:\Deploy\Runtime', [string]$ScriptShare = '', [string]$SoftwareShare = '', [string]$CatalogueShare = '')

    Write-PILog "Construction d'une sequence a la volee" 'STEP'

    # Jonction domaine : proposee en 1er (elle doit se faire avant le reste).
    # Le domaine/OU sont lus depuis PSWinDeploy.psd1 (DomainName/DomainOU), les
    # credentials depuis le vault (domainJoinUser/domainJoinPassword).
    $doDomain = $false
    $cfgDomainName = ''
    try { if (Get-Command Get-PSWinDeployConfig -EA SilentlyContinue) { $cfgDomainName = Get-PSWinDeployConfig -Key 'DomainName' } } catch {}
    if ($cfgDomainName) {
        $doDomain = Request-PSWDYesNo -Question "Joindre le domaine $cfgDomainName ?" -Default $false
    } else {
        if (Request-PSWDYesNo -Question "Joindre un domaine Active Directory ?" -Default $false) {
            $cfgDomainName = Request-PSWDString -Question "Nom du domaine (ex: corp.local)" -Default ''
            if ($cfgDomainName) { $doDomain = $true }
        }
    }

    $doUpdates = Request-PSWDYesNo -Question "Installer les mises a jour Windows ?" -Default $true
    $doApps    = Request-PSWDYesNo -Question "Installer des applications ?" -Default $false
    $doScript  = Request-PSWDYesNo -Question "Executer un ou des scripts PowerShell ?" -Default $false

    $selectedApps = @()
    if ($doApps) {
        # Charger le catalogue d'applications. CatalogueShare peut etre :
        #  - un FICHIER .psd1 (ex: ...\catalogue.psd1) -> lu directement
        #  - un DOSSIER -> on y cherche applications.psd1 (ou catalogue.psd1)
        $catalogue = @()
        $catPath = ''
        $catCandidates = @()
        if ($CatalogueShare) {
            if ($CatalogueShare -match '\.psd1$') { $catCandidates += $CatalogueShare }
            else { $catCandidates += (Join-Path $CatalogueShare 'applications.psd1'); $catCandidates += (Join-Path $CatalogueShare 'catalogue.psd1') }
        }
        $catCandidates += 'X:\Deploy\Catalogue\applications.psd1'
        foreach ($c in $catCandidates) {
            if ($c -and (Test-Path $c -EA SilentlyContinue)) { $catPath = $c; break }
        }
        if ($catPath) {
            try {
                $cat = Import-PowerShellDataFile $catPath -EA Stop
                if ($cat.Applications) { $catalogue = @($cat.Applications) }
                Write-PILog "$($catalogue.Count) application(s) au catalogue ($catPath)" 'INFO'
            } catch { Write-PILog "Lecture catalogue echouee : $_" 'WARN' }
        }
        if ($catalogue.Count -gt 0) {
            # Afficher la liste du catalogue avec le TYPE d'installation dispo,
            # puis laisser choisir (multi-selection si l'UI le permet).
        # Helper : lire une cle d'une app (hashtable OU objet) sans planter en StrictMode.
        $getKey = {
            param($obj, $key)
            if ($null -eq $obj) { return $null }
            if ($obj -is [hashtable] -or $obj -is [System.Collections.IDictionary]) {
                if ($obj.Contains($key)) { return $obj[$key] } else { return $null }
            }
            $p = $obj.PSObject.Properties[$key]
            if ($p) { return $p.Value } else { return $null }
        }
            $items = @()
            foreach ($app in $catalogue) {
                $types = @()
                if (& $getKey $app 'WingetId')  { $types += 'winget' }
                if (& $getKey $app 'ChocoId')   { $types += 'choco' }
                if (& $getKey $app 'Installer') { $types += 'exe/msi' }
                $typeStr = if ($types.Count) { ' [' + ($types -join '/') + ']' } else { '' }
                $appName = & $getKey $app 'Name'
                $items += "$appName$typeStr"
            }
            Write-PILog "Catalogue : $($catalogue.Count) application(s) disponibles" 'INFO'
            # Si l'UI offre une liste multi-choix, l'utiliser ; sinon oui/non par app.
            if (Get-Command Show-PSWDMultiList -EA SilentlyContinue) {
                $picked = Show-PSWDMultiList -Title "Choisir les applications a installer" -Items $items
                foreach ($idx in $picked) { if ($idx -ge 0 -and $idx -lt $catalogue.Count) { $selectedApps += $catalogue[$idx] } }
            } else {
                for ($i=0; $i -lt $catalogue.Count; $i++) {
                    if (Request-PSWDYesNo -Question "Installer : $($items[$i]) ?" -Default $false) {
                        $selectedApps += $catalogue[$i]
                    }
                }
            }
        } else {
            # Pas de catalogue : on N'INSTALLE RIEN (pas de saisie manuelle).
            # Le catalogue doit etre configure dans Deploy\Catalogue. On informe
            # clairement plutot que de demander des noms a l'aveugle.
            Write-PILog "Aucun catalogue d'applications trouve." 'WARN'
            Write-PILog "Configurez un catalogue dans Deploy\Catalogue (cle CataloguePath du psd1)." 'INFO'
            Write-PILog "Aucune application ne sera installee." 'INFO'
        }
    }
    $selectedScripts = @()
    if ($doScript) {
        # Le chemin vient deja propre de la config (Get-Cfg / Resolve-Share).
        # AUCUNE normalisation ici (c'etait la source du backslash manquant).
        Write-PILog "Recherche de scripts dans : $ScriptShare" 'INFO'
        $scriptsAvail = @()
        if ($ScriptShare -and (Test-Path $ScriptShare -EA SilentlyContinue)) {
            $scriptsAvail = @(Get-ChildItem $ScriptShare -Filter '*.ps1' -Recurse -EA SilentlyContinue | Sort-Object Name)
            Write-PILog "$($scriptsAvail.Count) script(s) .ps1 trouve(s)" 'INFO'
        } else {
            Write-PILog "Dossier scripts INACCESSIBLE : $ScriptShare" 'WARN'
        }
        if ($scriptsAvail.Count -gt 0) {
            Write-PILog "$($scriptsAvail.Count) script(s) trouve(s) sur le partage" 'INFO'
            # Liste a cases a cocher (GUI) si dispo, sinon oui/non par script.
            $scriptLabels = @()
            foreach ($sc in $scriptsAvail) { $scriptLabels += $sc.FullName.Substring($ScriptShare.Length).TrimStart('\') }
            if (Get-Command Show-PSWDMultiList -EA SilentlyContinue) {
                $picked = Show-PSWDMultiList -Title "Choisir les scripts a executer" -Items $scriptLabels
                foreach ($idx in $picked) { if ($idx -ge 0 -and $idx -lt $scriptsAvail.Count) { $selectedScripts += $scriptsAvail[$idx].FullName } }
            } else {
                for ($i=0; $i -lt $scriptsAvail.Count; $i++) {
                    if (Request-PSWDYesNo -Question "Inclure le script : $($scriptLabels[$i]) ?" -Default $false) {
                        $selectedScripts += $scriptsAvail[$i].FullName
                    }
                }
            }
        } else {
            # Pas de script sur le partage : on n'en met aucun (pas de saisie manuelle).
            Write-PILog "Aucun script trouve sur le partage ($ScriptShare)." 'WARN'
            Write-PILog "Deposez vos scripts .ps1 sur le partage Scripts pour les voir ici." 'INFO'
        }
    }

    # Generer la sequence
    $steps = @()
    $n = 1
    # Jonction domaine EN PREMIER (RebootAfter='Always' : reboot apres jonction)
    if ($doDomain -and $cfgDomainName) {
        $dnEsc3 = "$cfgDomainName".Replace("'","''")
        $steps += "        @{ Id = 'pi-$('{0:D2}' -f $n)'; Type = 'JoinDomain'; Name = 'Jonction au domaine'; Phase = 'Windows'; Enabled = `$true; RebootAfter = 'Always'; Params = @{ domain = '$dnEsc3' } }"
        $n++
    }
    if ($doUpdates) {
        $steps += "        @{ Id = 'pi-$('{0:D2}' -f $n)'; Type = 'InstallUpdates'; Name = 'Mises a jour Windows'; Phase = 'Windows'; Enabled = `$true; RebootAfter = 'IfRequired'; Params = @{} }"
        $n++
    }
    if ($doApps -and $selectedApps.Count -gt 0) {
        # Construire la liste des packages (objets riches) pour le step.
        $pkgLines = @()
        foreach ($app in $selectedApps) {
            $parts = @()
            foreach ($k in @('Name','WingetId','ChocoId','Installer','Args','RebootAfter')) {
                $v = $null
                if ($app -is [hashtable]) { if ($app.ContainsKey($k)) { $v = $app[$k] } }
                else { if ($app.PSObject.Properties[$k]) { $v = $app.$k } }
                if ($v) { $parts += "$k = '" + ("$v".Replace("'","''")) + "'" }
            }
            if ($parts.Count -gt 0) { $pkgLines += '            @{ ' + ($parts -join '; ') + ' }' }
        }
        $ssEsc = "$SoftwareShare".Replace("'","''")
        $pkgBlock = $pkgLines -join "`r`n"
        $steps += "        @{ Id = 'pi-$('{0:D2}' -f $n)'; Type = 'InstallApps'; Name = 'Applications'; Phase = 'Windows'; Enabled = `$true; RebootAfter = 'IfRequired'; Params = @{ softwareShare = '$ssEsc'; catalogApps = @(`r`n$pkgBlock`r`n        ) } }"
        $n++
    }
    if ($doScript -and $selectedScripts.Count -gt 0) {
        foreach ($sc in $selectedScripts) {
            $s = "$sc".Trim().Replace("'","''")
            # RebootAfter = 'Never' par defaut : un script ne reboote QUE s'il
            # retourne explicitement exit 3010. Evite les reboots non voulus.
            $steps += "        @{ Id = 'pi-$('{0:D2}' -f $n)'; Type = 'RunScript'; Name = 'Script: $s'; Phase = 'Windows'; Enabled = `$true; RebootAfter = 'Never'; Params = @{ Path = '$s'; Shell = 'PowerShell' } }"
            $n++
        }
    }

    if ($steps.Count -eq 0) {
        Write-PILog "Aucune action selectionnee -- rien a faire." 'INFO'
        return $null
    }

    $lines = @()
    $lines += '@{'
    $lines += "    Id = 'postinstall-volee'"
    $lines += "    Name = 'Post-installation (construite a la volee)'"
    $lines += "    Version = '1.0.0'"
    $lines += "    Metadata = @{ Os = 'Windows'; Locale = 'fr-FR' }"
    $lines += "    Options = @{ ContinueOnError = `$true; LogLevel = 'Info' }"
    $lines += '    Steps = @('
    $lines += ($steps -join "`r`n")
    $lines += '    )'
    $lines += '}'

    if (-not (Test-Path $RuntimeDir)) { New-Item -ItemType Directory $RuntimeDir -Force -EA SilentlyContinue | Out-Null }
    $dest = Join-Path $RuntimeDir 'sequence.psd1'
    $enc = New-Object System.Text.UTF8Encoding $true
    [System.IO.File]::WriteAllText($dest, ($lines -join "`r`n"), $enc)
    Write-PILog "Sequence construite : $dest ($($steps.Count) etape(s))" 'OK'
    return $dest
}

Export-ModuleMember -Function @(
    'Get-PrimaryMacAddress',
    'Test-PostInstallSequenceExists',
    'Resolve-PostInstallSequence',
    'New-PostInstallSequenceFromTemplate',
    'Show-PostInstallWizard',
    'Select-TemplateSequence',
    'Build-SequenceInteractive'
)
