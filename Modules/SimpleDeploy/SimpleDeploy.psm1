<#
.SYNOPSIS
    Deploiement From Scratch SIMPLE et LINEAIRE (sans TaskSequence).
    Reproduit exactement la logique de Test-ModuleDirect (qui BOOTE), mais
    avec les vrais parametres du wizard. Lisible, debogable, sans dispatcher
    ni gestion d'etat complexe.
.DESCRIPTION
    Etapes, dans l'ordre, comme le test qui fonctionne :
      1. Initialize-DeployDisk  (partitionnement)
      2. Apply-WIMImage         (application du WIM)
      3. Set-WindowsBootloader  (bcdboot)
      4. Write-UnattendFile     (unattend dans Panther)
      5. [option] copier Deploy sur la cible (pour la phase 2)
      6. flush disque + reboot (wpeutil) OU pause si -NoReboot
    Chaque etape verifie son resultat et logue clairement.
#>

# Initialiser la variable de log AVANT toute utilisation (StrictMode)
$script:SimpleLogFile = $null

function Write-SimpleLog {
    param([string]$Message, [string]$Level = 'INFO')
    $colors = @{ INFO='Gray'; OK='Green'; WARN='Yellow'; ERR='Red'; STEP='Cyan' }
    $c = $colors[$Level]; if (-not $c) { $c = 'Gray' }
    $line = "[$([DateTime]::Now.ToString('HH:mm:ss'))] [$Level] $Message"
    Write-Host "  $line" -ForegroundColor $c
    # Logguer aussi sur le partage Logs si trouvable (survit au reboot)
    try {
        if ($script:SimpleLogFile) {
            Add-Content -Path $script:SimpleLogFile -Value $line -Encoding UTF8 -EA SilentlyContinue
        }
    } catch {}
}

function Find-SimpleLogShare {
    # Cherche un partage \\serveur\Logs accessible, retourne un chemin de fichier log
    foreach ($d in (Get-PSDrive -PSProvider FileSystem -EA SilentlyContinue)) {
        if ($d.DisplayRoot -and $d.DisplayRoot -like '\\*') {
            $base = Split-Path $d.DisplayRoot -Parent
            $cand = Join-Path $base 'Logs'
            if (Test-Path $cand -EA SilentlyContinue) {
                $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
                return (Join-Path $cand "simpledeploy_$($env:COMPUTERNAME)_$stamp.log")
            }
        }
    }
    return $null
}

function Invoke-SimpleDeploy {
    <#
    .SYNOPSIS Deploiement From Scratch lineaire.
    .PARAMETER WimPath      Chemin du WIM (UNC ou local).
    .PARAMETER Index        Index dans le WIM (defaut 1).
    .PARAMETER DiskNumber   Disque cible (defaut 0).
    .PARAMETER UnattendParams Hashtable pour New-UnattendXml (nom, mdp, locale...).
    .PARAMETER CopyDeploy   Copier X:\Deploy vers W:\Deploy (pour la phase 2).
    .PARAMETER NoReboot     Ne pas rebooter ; rendre la main pour 'wpeutil reboot'.
    .PARAMETER ModulesRoot  Dossier des modules (pour importer WIM-Manager/Unattend).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$WimPath,
        [int]$Index = 1,
        [int]$DiskNumber = 0,
        [hashtable]$UnattendParams = @{},
        [switch]$CopyDeploy,
        [string]$DriverModelPath,
        [string]$DriverShare,
        [switch]$NoDriverPrompt,
        [switch]$NoReboot,
        [string]$ModulesRoot = '',
        [string]$SequencePath = '',  # sequence a copier sur C:\Deploy\Runtime pour la phase 2
        [hashtable]$DeployConfig = @{}  # infos pour la phase 2 : NetworkShare, ServerIP, etc.
    )

    $script:SimpleLogFile = Find-SimpleLogShare
    if ($script:SimpleLogFile) { Write-SimpleLog "Log : $script:SimpleLogFile" 'INFO' }

    Write-SimpleLog "===== DEPLOIEMENT SIMPLE (lineaire) =====" 'STEP'
    Write-SimpleLog "WIM=$WimPath Index=$Index Disque=$DiskNumber" 'INFO'

    # -- Import des modules necessaires --
    if (-not $ModulesRoot) { $ModulesRoot = Split-Path $PSScriptRoot -Parent }
    foreach ($m in @('WIM-Manager','Unattend')) {
        $mp = Join-Path $ModulesRoot "$m\$m.psm1"
        if (Test-Path $mp) { Import-Module $mp -Force }
        else { Write-SimpleLog "Module introuvable : $mp" 'WARN' }
    }

    # -- 1. Partitionnement --
    Write-SimpleLog "[1/6] Partitionnement du disque $DiskNumber..." 'STEP'
    Initialize-DeployDisk -DiskNumber $DiskNumber -FirmwareType UEFI -Force | Out-Null
    foreach ($l in @('S','W')) {
        if (-not (Test-Path "${l}:\" -EA SilentlyContinue)) {
            Write-SimpleLog "Partition ${l}: ABSENTE apres partitionnement -- ARRET" 'ERR'
            throw "Partitionnement echoue : ${l}: manquante"
        }
    }
    Write-SimpleLog "Partitions S:/W: OK" 'OK'

    # -- 2. Application du WIM --
    Write-SimpleLog "[2/6] Application du WIM..." 'STEP'
    Apply-WIMImage -WimPath $WimPath -Index $Index -TargetPath 'W:\' | Out-Null
    if (-not (Test-Path 'W:\Windows\System32\ntoskrnl.exe' -EA SilentlyContinue)) {
        Write-SimpleLog "ntoskrnl.exe ABSENT apres WIM -- image incomplete -- ARRET" 'ERR'
        throw "Application WIM echouee : Windows incomplet"
    }
    Write-SimpleLog "WIM applique (ntoskrnl.exe present)" 'OK'

    # -- 2b. INJECTION DRIVERS (offline) --
    # Selection d'un dossier modele sur \\srv\Drivers et injection sur l'image
    # Windows OFFLINE (W:\) AVANT le 1er boot. Les sous-dossiers du modele n'ont
    # pas d'importance (DISM /Recurse). Si DriverModelPath fourni, on l'utilise
    # directement ; sinon on demande (sauf si pas de module/dossier).
    if ($DriverModelPath) {
        Write-SimpleLog "[2b/6] Injection drivers : $DriverModelPath" 'STEP'
        # Charger DriverManager si besoin
        if (-not (Get-Command Add-OfflineDrivers -EA SilentlyContinue)) {
            foreach ($base in @('X:\Deploy\Modules','C:\Deploy\Modules', $ModulesRoot)) {
                if (-not $base) { continue }
                $p = Join-Path $base 'DriverManager\DriverManager.psm1'
                if (Test-Path $p -EA SilentlyContinue) { try { Import-Module $p -Force -Global -DisableNameChecking } catch {}; break }
            }
        }
        if (Get-Command Add-OfflineDrivers -EA SilentlyContinue) {
            Add-OfflineDrivers -ImagePath 'W:\' -DriverPath $DriverModelPath | Out-Null
        } else {
            Write-SimpleLog "  Module DriverManager indisponible -- injection sautee." 'WARN'
        }
    } else {
        Write-SimpleLog "[2b/6] Drivers : selection du modele a injecter..." 'STEP'
        # Charger le module DriverManager si pas deja charge dans ce contexte.
        if (-not (Get-Command Select-DriverModel -EA SilentlyContinue)) {
            $dmPath = $null
            foreach ($base in @('X:\Deploy\Modules','C:\Deploy\Modules', $ModulesRoot)) {
                if (-not $base) { continue }
                $p = Join-Path $base 'DriverManager\DriverManager.psm1'
                if (Test-Path $p -EA SilentlyContinue) { $dmPath = $p; break }
            }
            if ($dmPath) {
                try { Import-Module $dmPath -Force -Global -DisableNameChecking; Write-SimpleLog "  DriverManager charge : $dmPath" 'INFO' } catch { Write-SimpleLog "  DriverManager : $_" 'WARN' }
            }
        }
        if (-not (Get-Command Select-DriverModel -EA SilentlyContinue)) {
            Write-SimpleLog "  Module DriverManager indisponible -- pas d'injection de drivers." 'WARN'
        } elseif ($NoDriverPrompt) {
            Write-SimpleLog "  Selection drivers desactivee (NoDriverPrompt)." 'INFO'
        } else {
            $drvRoot = $DriverShare
            if (-not $drvRoot) { $drvRoot = '\\SERVEUR\Drivers' }
            Write-SimpleLog "  Partage drivers : $drvRoot" 'INFO'
            if (Test-Path $drvRoot -EA SilentlyContinue) {
                $chosen = Select-DriverModel -DriversRoot $drvRoot
                if ($chosen) {
                    Add-OfflineDrivers -ImagePath 'W:\' -DriverPath $chosen | Out-Null
                } else {
                    Write-SimpleLog "  Aucun driver modele injecte (choix utilisateur ou aucun dossier)." 'INFO'
                }
            } else {
                Write-SimpleLog "  Partage drivers inaccessible ($drvRoot) -- injection sautee." 'WARN'
            }
        }
    }

    # -- 3. Bootloader --
    Write-SimpleLog "[3/6] Bootloader (bcdboot)..." 'STEP'
    Set-WindowsBootloader -WindowsDrive 'W:' -SystemDrive 'S:' -FirmwareType UEFI -RecoveryDrive 'R:' | Out-Null
    if (-not (Test-Path 'S:\EFI\Microsoft\Boot\BCD' -EA SilentlyContinue)) {
        Write-SimpleLog "BCD ABSENT sur l'ESP -- boot non prepare -- ARRET" 'ERR'
        throw "Bootloader echoue : BCD manquant"
    }
    Write-SimpleLog "Bootloader OK (BCD present)" 'OK'

    # -- 4. Unattend --
    Write-SimpleLog "[4/6] Ecriture de l'unattend..." 'STEP'
    if ($UnattendParams.Count -gt 0) {
        $xmlPath = Write-UnattendFile -TargetDrive 'W:' -Parameters $UnattendParams
        Write-SimpleLog "Unattend ecrit : $xmlPath" 'OK'
    } else {
        Write-SimpleLog "Pas de parametres unattend -- etape sautee" 'WARN'
    }

    # -- 5. Copie Deploy (optionnel, pour phase 2) --
    if ($CopyDeploy) {
        Write-SimpleLog "[5/6] Copie de Deploy vers W:\Deploy..." 'STEP'
        $src = if (Test-Path 'X:\Deploy') { 'X:\Deploy' } else { $null }
        if ($src) {
            New-Item -ItemType Directory 'W:\Deploy' -Force -EA SilentlyContinue | Out-Null
            foreach ($sub in @('Scripts','Modules','Runtime')) {
                $s = Join-Path $src $sub
                if (Test-Path $s) { Copy-Item $s 'W:\Deploy' -Recurse -Force -EA SilentlyContinue }
            }
            # Copier PSWinDeploy.psd1 (LA source unique de config) sur la cible.
            # En phase 2, Config le lira depuis C:\Deploy\PSWinDeploy.psd1 :
            # meme fichier, meme mecanisme qu'en phase 1. Plus de deploy-config separe.
            if (Test-Path 'X:\Deploy\PSWinDeploy.psd1' -EA SilentlyContinue) {
                Copy-Item 'X:\Deploy\PSWinDeploy.psd1' 'W:\Deploy\PSWinDeploy.psd1' -Force -EA SilentlyContinue
                Write-SimpleLog "Config PSWinDeploy.psd1 copiee sur la cible (C:\Deploy)" 'OK'
            }
            # Copier la sequence pour la phase 2 (la TaskSequence la relira)
            if ($SequencePath -and (Test-Path $SequencePath -EA SilentlyContinue)) {
                New-Item -ItemType Directory 'W:\Deploy\Runtime' -Force -EA SilentlyContinue | Out-Null
                Copy-Item $SequencePath 'W:\Deploy\Runtime\sequence.psd1' -Force -EA SilentlyContinue
                Write-SimpleLog "Sequence copiee pour la phase 2 : W:\Deploy\Runtime\sequence.psd1" 'OK'
            }
            # Ecrire la config de deploiement pour la phase 2 (serveur REEL, IP,
            # partage...). Sans ca, la phase 2 ne sait pas a quel serveur se
            # reconnecter (le defaut \\SERVEUR\Deploy est un placeholder).
            if ($DeployConfig.Count -gt 0) {
                $cfgLines = @('@{')
                foreach ($k in $DeployConfig.Keys) {
                    $v = "$($DeployConfig[$k])".Replace("'","''")
                    $cfgLines += "    $k = '$v'"
                }
                $cfgLines += '}'
                $enc = New-Object System.Text.UTF8Encoding $true
                [System.IO.File]::WriteAllText('W:\Deploy\deploy-config.psd1', ($cfgLines -join "`r`n"), $enc)
                Write-SimpleLog "Config phase 2 ecrite : W:\Deploy\deploy-config.psd1" 'OK'
            }
            # Copier le vault sur la cible pour que la phase 2 ait les credentials
            foreach ($vc in @('X:\Deploy\secrets.vault.psd1','X:\Deploy\secrets.vault')) {
                if (Test-Path $vc -EA SilentlyContinue) {
                    Copy-Item $vc ('W:\Deploy\' + (Split-Path $vc -Leaf)) -Force -EA SilentlyContinue
                    Write-SimpleLog "Vault copie pour la phase 2 : $(Split-Path $vc -Leaf)" 'OK'
                    break
                }
            }
            Write-SimpleLog "Deploy copie" 'OK'
        } else {
            Write-SimpleLog "X:\Deploy introuvable -- copie sautee" 'WARN'
        }
    } else {
        Write-SimpleLog "[5/6] Copie Deploy non demandee" 'INFO'
    }

    # -- 6. Flush + reboot --
    Write-SimpleLog "[6/6] Flush des ecritures disque..." 'STEP'
    foreach ($vol in @('S','W','R')) {
        if (Test-Path "${vol}:\" -EA SilentlyContinue) {
            try { [System.IO.File]::WriteAllText("${vol}:\.flush", '1'); Remove-Item "${vol}:\.flush" -Force -EA SilentlyContinue } catch {}
        }
    }
    Start-Sleep -Seconds 2
    Write-SimpleLog "Flush OK" 'OK'

    # -- Fenetre de fin : recapitulatif clair --
    $cn = if ($UnattendParams.ContainsKey('ComputerName')) { $UnattendParams.ComputerName } else { '(defaut)' }
    $hasPwd = $UnattendParams.ContainsKey('LocalAdminPassword')
    Write-Host ""
    Write-Host "  +========================================================+" -ForegroundColor Green
    Write-Host "  |              DEPLOIEMENT TERMINE AVEC SUCCES            |" -ForegroundColor Green
    Write-Host "  +========================================================+" -ForegroundColor Green
    Write-Host ""
    Write-Host "  Recapitulatif :" -ForegroundColor White
    Write-Host "    - Disque        : $DiskNumber (partitionne GPT/UEFI)" -ForegroundColor Gray
    Write-Host "    - Windows       : applique sur W: (futur C:)" -ForegroundColor Gray
    Write-Host "    - Nom machine   : $cn" -ForegroundColor Gray
    Write-Host "    - Mot de passe  : $(if($hasPwd){'depuis le vault'}else{'defaut du module (vault non lu)'})" -ForegroundColor $(if($hasPwd){'Gray'}else{'Yellow'})
    Write-Host "    - Bootloader    : configure (UEFI)" -ForegroundColor Gray
    Write-Host "    - Phase 2       : $(if($CopyDeploy){'preparee (C:\Deploy)'}else{'non preparee'})" -ForegroundColor Gray
    if ($script:SimpleLogFile) {
        Write-Host "    - Log           : $script:SimpleLogFile" -ForegroundColor DarkGray
    }
    Write-Host ""

    if ($NoReboot) {
        Write-Host "  >> MODE SANS REBOOT AUTO <<" -ForegroundColor Yellow
        Write-Host "     La machine NE redemarre PAS automatiquement." -ForegroundColor Yellow
        Write-Host "     Pour demarrer Windows, tape :  " -ForegroundColor White -NoNewline
        Write-Host "wpeutil reboot" -ForegroundColor Cyan
        Write-Host ""
        Write-SimpleLog "Termine (mode no-reboot). En attente de 'wpeutil reboot' manuel." 'OK'
        return
    }

    Write-Host "  La machine va redemarrer pour finaliser l'installation Windows." -ForegroundColor White
    Write-Host "  (OOBE -> autologon -> phase 2 si configuree)" -ForegroundColor DarkGray
    Write-Host ""
    for ($i = 10; $i -ge 1; $i--) {
        Write-Host "`r  Redemarrage dans $i secondes...  (Ctrl+C pour annuler)   " -ForegroundColor Yellow -NoNewline
        Start-Sleep -Seconds 1
    }
    Write-Host ""
    Write-SimpleLog "Reboot via wpeutil reboot" 'OK'
    & wpeutil.exe reboot
    Start-Sleep -Seconds 60
}

function Get-StepPhase {
    <#
    .SYNOPSIS Retourne la phase d'un step : 'Windows' si declare explicitement,
    sinon 'WinPE' par defaut. (Choix : ne casse pas les sequences existantes --
    seuls les steps post-OS doivent ajouter Phase = 'Windows'.)
    #>
    param($Step)
    $p = $null
    if ($Step.PSObject.Properties['Phase']) { $p = $Step.Phase }
    elseif ($Step -is [hashtable] -and $Step.ContainsKey('Phase')) { $p = $Step['Phase'] }
    if ($p -and "$p".Trim().ToLower() -eq 'windows') { return 'Windows' }
    return 'WinPE'
}

function Split-SequenceByPhase {
    <#
    .SYNOPSIS Separe les steps d'une sequence en deux listes : WinPE et Windows.
    #>
    param($Sequence)
    $winpe = @(); $windows = @()
    foreach ($s in $Sequence.Steps) {
        if ((Get-StepPhase $s) -eq 'Windows') { $windows += $s } else { $winpe += $s }
    }
    return @{ WinPE = $winpe; Windows = $windows }
}

Export-ModuleMember -Function Invoke-SimpleDeploy, Get-StepPhase, Split-SequenceByPhase
