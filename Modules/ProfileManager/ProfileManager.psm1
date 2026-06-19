#Requires -RunAsAdministrator
<#
.SYNOPSIS
    ProfileManager.psm1 -- Gestion des profils de deploiement
.DESCRIPTION
    Charge les profils, applique les overrides sur les sequences,
    gere l'autologon entre reboots et le mot de passe administrateur local.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:ProfilesRoot  = '\\SERVEUR\Deploy\Profiles'
$script:CatalogueFile = '\\SERVEUR\Deploy\Catalogue\catalogue.psd1'
$script:DeployUser    = 'deploy-temp'

# -----------------------------------------------------------------------------
# LOGGING
# -----------------------------------------------------------------------------

function Write-PLog {
    param([string]$Msg, [string]$Level = 'INFO')
    $ts = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $icons  = @{INFO='[~]';WARN='[!]';ERROR='[X]';SUCCESS='[OK]';STEP='[>>]'}
    $colors = @{INFO='Cyan';WARN='Yellow';ERROR='Red';SUCCESS='Green';STEP='Magenta'}
    Write-Host "$ts $($icons[$Level]) $Msg" -ForegroundColor $colors[$Level]
}

# -----------------------------------------------------------------------------
# CHARGEMENT DES PROFILS
# -----------------------------------------------------------------------------

function Get-DeployProfile {
    <#
    .SYNOPSIS Liste ou charge un profil de deploiement.
    .PARAMETER ProfileId Si absent, retourne tous les profils disponibles.
    .PARAMETER ProfilesPath Dossier racine des profils JSON.
    .EXAMPLE
        $profiles = Get-DeployProfile
        $profil   = Get-DeployProfile -ProfileId 'profil-poste-rh'
    #>
    [CmdletBinding()]
    param(
        [string]$ProfileId,
        [string]$ProfilesPath = $script:ProfilesRoot
    )

    $searchPaths = @($ProfilesPath, 'C:\Deploy\Profiles', 'X:\Deploy\Profiles')
    $found = @()

    foreach ($path in $searchPaths) {
        if (Test-Path $path) {
            $found += Get-ChildItem $path -Filter '*.psd1' -ErrorAction SilentlyContinue
        }
    }

    if ($found.Count -eq 0) {
        Write-PLog "Aucun profil trouve dans les chemins configures" -Level WARN
        return @()
    }

    $profiles = $found | ForEach-Object {
        try {
            $ht = Import-PowerShellDataFile $_.FullName
            # Normaliser en PSCustomObject avec cle 'id' garantie
            $obj = [PSCustomObject]$ht
            if (-not $obj.PSObject.Properties['id'] -and $obj.PSObject.Properties['Id']) {
                $obj | Add-Member -NotePropertyName 'id' -NotePropertyValue $obj.Id -Force
            }
            if (-not ($obj.PSObject.Properties['id'])) {
                $obj | Add-Member -NotePropertyName 'id' -NotePropertyValue $_.BaseName -Force
            }
            $obj
        }
        catch { Write-PLog "Profil invalide : $($_.Name) -- $_" -Level WARN; $null }
    } | Where-Object { $_ -ne $null }

    if ($ProfileId) {
        $p = $profiles | Where-Object { $_.id -eq $ProfileId } | Select-Object -First 1
        if (-not $p) { throw "Profil introuvable : $ProfileId" }
        return $p
    }

    return $profiles
}

function Resolve-ProfileSequence {
    <#
    .SYNOPSIS
        Charge la sequence d'un profil et applique ses overrides.
    .DESCRIPTION
        - Charge le JSON de sequence reference par le profil
        - Applique metadata overrides (domaine, locale...)
        - Applique stepOverrides (parametres par step)
        - Injecte les apps du catalogue selectionnees dans le step InstallSoftware
        - Injecte les steps de securite (autologon, admin password)
    .PARAMETER Profile Objet profil charge via Get-DeployProfile
    .PARAMETER SelectedApps Ids d'apps du catalogue a activer (surcharge le profil)
    .OUTPUTS PSCustomObject sequence complete prete a executer
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [PSCustomObject]$Profile,
        [string[]]$SelectedApps,
        [string]$MachineName
    )

    Write-PLog "Resolution sequence pour profil '$($Profile.name)'" -Level STEP

    # Chargement sequence de base
    if (-not (Test-Path $Profile.sequencePath)) {
        throw "Sequence introuvable : $($Profile.sequencePath)"
    }
    if ($Profile.sequencePath -match '\.psd1$') {
        $seqHt = Import-PowerShellDataFile $Profile.sequencePath
        $seq = [PSCustomObject]$seqHt
    } else {
        $seq = Get-Content $Profile.sequencePath -Raw | ConvertFrom-Json
    }
    # Deep clone via JSON round-trip (evite les mutations sur l'original)
    $seq = $seq | ConvertTo-Json -Depth 20 | ConvertFrom-Json

    # -- Overrides metadata globaux --
    if ($Profile.overrides) {
        foreach ($key in $Profile.overrides.PSObject.Properties.Name) {
            $parts = $key -split '\.'
            $target = $seq
            for ($i = 0; $i -lt $parts.Count - 1; $i++) {
                $target = $target.$($parts[$i])
            }
            $target.$($parts[-1]) = $Profile.overrides.$key
            Write-PLog "  Override : $key = $($Profile.overrides.$key)" -Level INFO
        }
    }

    # Nom machine si fourni
    if ($MachineName) {
        if (-not $seq.metadata) { $seq | Add-Member -NotePropertyName metadata -NotePropertyValue ([PSCustomObject]@{}) }
        $seq.metadata | Add-Member -NotePropertyName computerName -NotePropertyValue $MachineName -Force
    }

    # -- Overrides par step --
    if ($Profile.stepOverrides) {
        foreach ($stepId in $Profile.stepOverrides.PSObject.Properties.Name) {
            $step = $seq.steps | Where-Object { $_.id -eq $stepId } | Select-Object -First 1
            if (-not $step) {
                Write-PLog "  stepOverride ignore (step '$stepId' absent)" -Level WARN
                continue
            }
            $overrideProps = $Profile.stepOverrides.$stepId
            foreach ($prop in $overrideProps.PSObject.Properties.Name) {
                if ($prop -eq 'params') {
                    foreach ($p in $overrideProps.params.PSObject.Properties.Name) {
                        $step.params | Add-Member -NotePropertyName $p -NotePropertyValue $overrideProps.params.$p -Force
                    }
                } else {
                    $step | Add-Member -NotePropertyName $prop -NotePropertyValue $overrideProps.$prop -Force
                }
            }
            Write-PLog "  Override step '$stepId' applique" -Level INFO
        }
    }

    # -- Injection apps catalogue --
    $catalogue = Get-DeployCatalogue
    $appsToInstall = @()

    # Apps obligatoires du profil
    if ($Profile.requiredApps) {
        foreach ($appId in $Profile.requiredApps) {
            $app = $catalogue | Where-Object { $_.id -eq $appId } | Select-Object -First 1
            if ($app) { $appsToInstall += $app }
        }
    }

    # Apps optionnelles selectionnees
    $optionalIds = if ($SelectedApps) { $SelectedApps }
                   elseif ($Profile.defaultApps) { $Profile.defaultApps }
                   else { @() }

    foreach ($appId in $optionalIds) {
        if ($appId -notin ($appsToInstall | Select-Object -ExpandProperty id)) {
            $app = $catalogue | Where-Object { $_.id -eq $appId } | Select-Object -First 1
            if ($app) { $appsToInstall += $app }
        }
    }

    # Injection dans le step InstallSoftware
    $softStep = $seq.steps | Where-Object { $_.type -eq 'InstallSoftware' } | Select-Object -First 1
    if ($softStep -and $appsToInstall.Count -gt 0) {
        $packages = $appsToInstall | ForEach-Object {
            [PSCustomObject]@{
                name            = $_.name
                installer       = $_.installer
                args            = $_.args
                continueOnError = $_.continueOnError
            }
        }
        $softStep.params | Add-Member -NotePropertyName packages -NotePropertyValue $packages -Force
        Write-PLog "  $($appsToInstall.Count) application(s) injectees dans InstallSoftware" -Level INFO
    }

    # -- Injection scripts catalogue --
    $scriptsToRun = @()
    if ($Profile.requiredScripts) { $scriptsToRun += $Profile.requiredScripts }
    if ($Profile.defaultScripts)  { $scriptsToRun += $Profile.defaultScripts }

    foreach ($scriptId in $scriptsToRun) {
        $scriptDef = $catalogue | Where-Object { $_.id -eq $scriptId -and $_.type -eq 'script' } | Select-Object -First 1
        if ($scriptDef) {
            $newStep = [PSCustomObject]@{
                id             = "auto-script-$($scriptDef.id)"
                type           = 'RunScript'
                name           = $scriptDef.name
                enabled        = $true
                continueOnError = $true
                rebootAfter    = 'Never'
                params         = [PSCustomObject]@{
                    path  = $scriptDef.path
                    shell = 'PowerShell'
                    args  = $scriptDef.args
                }
            }
            # Inserer avant le dernier step
            $stepsList = [System.Collections.Generic.List[PSCustomObject]]$seq.steps
            $stepsList.Insert($stepsList.Count - 1, $newStep)
            $seq.steps = $stepsList.ToArray()
            Write-PLog "  Script '$($scriptDef.name)' injecte" -Level INFO
        }
    }

    # -- Injection securite (autologon + admin password) --
    $seq = Add-SecuritySteps -Sequence $seq -Profile $Profile

    Write-PLog "Sequence resolue : $($seq.steps.Count) steps" -Level SUCCESS
    return $seq
}

# -----------------------------------------------------------------------------
# CATALOGUE
# -----------------------------------------------------------------------------

function Get-DeployCatalogue {
    <#
    .SYNOPSIS Charge le catalogue d'applications et scripts.#>
    $searchPaths = @($script:CatalogueFile, 'C:\Deploy\Catalogue\catalogue.psd1', 'X:\Deploy\Catalogue\catalogue.psd1')
    foreach ($path in $searchPaths) {
        if (Test-Path $path) {
            if ($path -match '\.psd1$') {
                $catHt = Import-PowerShellDataFile $path
                return [PSCustomObject]$catHt
            }
            return Get-Content $path -Raw | ConvertFrom-Json
        }
    }
    Write-PLog "Catalogue introuvable -- retourne liste vide" -Level WARN
    return @()
}

# -----------------------------------------------------------------------------
# SECURITE -- AUTOLOGON
# -----------------------------------------------------------------------------

function Set-AutoLogon {
    <#
    .SYNOPSIS Configure l'autologon Windows pour la reprise post-reboot.
    .DESCRIPTION
        Ecrit les cles de registre AutoAdminLogon pour qu'au prochain
        demarrage Windows connecte automatiquement le compte de deploiement.
        Le compteur AutoLogonCount limite le nombre de logins automatiques.
    .PARAMETER Username Compte a connecter automatiquement.
    .PARAMETER Password Mot de passe en clair (sera mis en SecureString).
    .PARAMETER Domain   Domaine (optionnel, vide = local).
    .PARAMETER Count    Nombre de logins automatiques autorises (defaut: 5).
    .PARAMETER TargetHive Ruche cible (HKLM par defaut, ou chemin offline).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Username,
        [Parameter(Mandatory)]
        [string]$Password,
        [string]$Domain = '',
        [int]$Count     = 5,
        [string]$TargetHive = 'HKLM'
    )

    $regPath = "$TargetHive`:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon"

    Write-PLog "Configuration autologon : $Username (max $Count boots)" -Level INFO

    $props = @{
        AutoAdminLogon    = '1'
        DefaultUserName   = $Username
        DefaultPassword   = $Password
        AutoLogonCount    = $Count
        ForceAutoLogon    = '0'
    }
    if ($Domain) { $props.DefaultDomainName = $Domain }

    foreach ($key in $props.Keys) {
        Set-ItemProperty -Path $regPath -Name $key -Value $props[$key] -Type String -Force
    }

    # Desactiver le verrouillage de session pendant le deploiement
    Set-ItemProperty -Path "$TargetHive`:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System" `
        -Name 'DisableCAD' -Value 1 -Type DWord -Force -ErrorAction SilentlyContinue

    Write-PLog "Autologon configure" -Level SUCCESS
}

function Set-AutoLogonOffline {
    <#
    .SYNOPSIS Configure l'autologon dans un Windows offline (WIM monte ou partition W:\).
    .DESCRIPTION
        Monte la ruche SYSTEM du Windows cible et ecrit les cles d'autologon
        sans demarrer ce Windows. Appele depuis WinPE apres Apply-WIMImage.
    .PARAMETER WindowsPath Chemin racine du Windows offline (ex: W:\).
    .PARAMETER Username    Compte a configurer.
    .PARAMETER Password    Mot de passe.
    .PARAMETER Count       Nombre de logins automatiques.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$WindowsPath,
        [Parameter(Mandatory)]
        [string]$Username,
        [Parameter(Mandatory)]
        [string]$Password,
        [int]$Count = 5
    )

    $hivePath   = Join-Path $WindowsPath 'Windows\System32\config\SOFTWARE'
    $mountPoint = 'HKLM\DEPLOY_SOFT_TEMP'

    Write-PLog "Montage ruche offline : $hivePath" -Level INFO

    # Monter la ruche
    $result = & reg.exe LOAD $mountPoint $hivePath 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "Impossible de monter la ruche SOFTWARE : $result"
    }

    try {
        $regPath = 'HKLM:\DEPLOY_SOFT_TEMP\Microsoft\Windows NT\CurrentVersion\Winlogon'

        # Creer la cle si necessaire
        if (-not (Test-Path $regPath)) {
            New-Item -Path $regPath -Force | Out-Null
        }

        Set-ItemProperty -Path $regPath -Name 'AutoAdminLogon'  -Value '1'       -Type String -Force
        Set-ItemProperty -Path $regPath -Name 'DefaultUserName' -Value $Username  -Type String -Force
        Set-ItemProperty -Path $regPath -Name 'DefaultPassword' -Value $Password  -Type String -Force
        Set-ItemProperty -Path $regPath -Name 'AutoLogonCount'  -Value $Count     -Type String -Force
        Set-ItemProperty -Path $regPath -Name 'ForceAutoLogon'  -Value '0'        -Type String -Force

        Write-PLog "Autologon offline configure pour '$Username'" -Level SUCCESS
    } finally {
        # Demonter la ruche -- CRITIQUE, sinon corruption
        [GC]::Collect()
        Start-Sleep -Milliseconds 500
        $result = & reg.exe UNLOAD $mountPoint 2>&1
        if ($LASTEXITCODE -ne 0) {
            Write-PLog "ATTENTION : demontage ruche echoue ! $result" -Level WARN
        } else {
            Write-PLog "Ruche demontee proprement" -Level INFO
        }
    }
}

function Remove-AutoLogon {
    <#
    .SYNOPSIS Supprime la configuration d'autologon (fin de deploiement).
    .DESCRIPTION
        Efface les cles de registre AutoAdminLogon et DefaultPassword.
        DOIT etre appele en fin de sequence pour ne pas laisser un mot de passe
        en clair dans le registre de la machine deployee.
    #>
    [CmdletBinding()]
    param([string]$Hive = 'HKLM']
    )

    $regPath = "$Hive`:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon"
    Write-PLog "Suppression autologon..." -Level INFO

    $keysToRemove = @('AutoAdminLogon','DefaultPassword','AutoLogonCount','ForceAutoLogon')
    foreach ($key in $keysToRemove) {
        Remove-ItemProperty -Path $regPath -Name $key -ErrorAction SilentlyContinue
    }
    # Remettre AutoAdminLogon a 0 explicitement
    Set-ItemProperty -Path $regPath -Name 'AutoAdminLogon' -Value '0' -Type String -Force

    Write-PLog "Autologon supprime" -Level SUCCESS
}

# -----------------------------------------------------------------------------
# SECURITE -- COMPTE TEMPORAIRE DE DEPLOIEMENT
# -----------------------------------------------------------------------------

function New-DeployTempUser {
    <#
    .SYNOPSIS
        Cree le compte local temporaire utilise pour l'autologon de deploiement.
    .DESCRIPTION
        Cree un compte local avec mot de passe complexe, l'ajoute aux
        Administrateurs locaux (necessaire pour les etapes de deploiement),
        et marque le compte pour suppression en fin de sequence.
        Peut s'executer dans un Windows offline via DISM ou en live.
    .PARAMETER WindowsPath Chemin Windows offline (WinPE). Vide = live.
    .PARAMETER Username    Nom du compte (defaut : deploy-temp).
    .PARAMETER Password    Mot de passe du compte.
    #>
    [CmdletBinding()]
    param(
        [string]$WindowsPath,
        [string]$Username = $script:DeployUser,
        [Parameter(Mandatory)]
        [string]$Password
    )

    if ($WindowsPath) {
        # Mode offline -- via unattend.xml injecte dans le WIM
        Write-PLog "Creation compte deploy offline via unattend.xml" -Level INFO
        $unattend = New-DeployUnattend -Username $Username -Password $Password
        $unattendPath = Join-Path $WindowsPath 'Windows\Panther\unattend.xml'
        $unattendDir  = Split-Path $unattendPath -Parent
        if (-not (Test-Path $unattendDir)) { New-Item -ItemType Directory $unattendDir -Force | Out-Null }
        $unattend | Set-Content $unattendPath -Encoding UTF8
        Write-PLog "unattend.xml cree : $unattendPath" -Level SUCCESS
    } else {
        # Mode live -- net user direct
        Write-PLog "Creation compte deploy local : $Username" -Level INFO
        & net.exe user $Username $Password /add /passwordchg:no /expires:never 2>&1 | Out-Null
        & net.exe localgroup Administrators $Username /add 2>&1 | Out-Null
        # Masquer le compte sur l'ecran de connexion
        $regHide = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon\SpecialAccounts\UserList"
        if (-not (Test-Path $regHide)) { New-Item $regHide -Force | Out-Null }
        Set-ItemProperty -Path $regHide -Name $Username -Value 0 -Type DWord -Force
        Write-PLog "Compte $Username cree et masque" -Level SUCCESS
    }
}

function New-DeployUnattend {
    <#
    .SYNOPSIS Genere un unattend.xml minimal pour creer le compte deploy au 1er boot.#>
    param(
        [string]$Username = $script:DeployUser,
        [string]$Password
    )
    return @"
<?xml version="1.0" encoding="utf-8"?>
<unattend xmlns="urn:schemas-microsoft-com:unattend">
  <settings pass="oobeSystem">
    <component name="Microsoft-Windows-Shell-Setup"
               processorArchitecture="amd64"
               publicKeyToken="31bf3856ad364e35"
               language="neutral"
               versionScope="nonSxS"
               xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State">
      <UserAccounts>
        <LocalAccounts>
          <LocalAccount wcm:action="add">
            <Password>
              <Value>$Password</Value>
              <PlainText>true</PlainText>
            </Password>
            <Name>$Username</Name>
            <Group>Administrators</Group>
            <DisplayName>Deploy Temp</DisplayName>
          </LocalAccount>
        </LocalAccounts>
      </UserAccounts>
      <AutoLogon>
        <Password>
          <Value>$Password</Value>
          <PlainText>true</PlainText>
        </Password>
        <Username>$Username</Username>
        <Enabled>true</Enabled>
        <LogonCount>5</LogonCount>
      </AutoLogon>
      <OOBE>
        <HideEULAPage>true</HideEULAPage>
        <HideLocalAccountScreen>true</HideLocalAccountScreen>
        <HideOnlineAccountScreens>true</HideOnlineAccountScreens>
        <HideWirelessSetupInOOBE>true</HideWirelessSetupInOOBE>
        <NetworkLocation>Work</NetworkLocation>
        <SkipUserOOBE>true</SkipUserOOBE>
        <SkipMachineOOBE>true</SkipMachineOOBE>
      </OOBE>
    </component>
  </settings>
</unattend>
"@
}

function Remove-DeployTempUser {
    <#
    .SYNOPSIS Supprime le compte temporaire de deploiement.
    .DESCRIPTION Appele en fin de sequence -- Invoke-DeployCleanup.#>
    param([string]$Username = $script:DeployUser)
    Write-PLog "Suppression compte deploy : $Username" -Level INFO
    & net.exe user $Username /delete 2>&1 | Out-Null
    # Nettoyer la cle de masquage
    $regHide = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon\SpecialAccounts\UserList"
    Remove-ItemProperty -Path $regHide -Name $Username -ErrorAction SilentlyContinue
    Write-PLog "Compte $Username supprime" -Level SUCCESS
}

# -----------------------------------------------------------------------------
# SECURITE -- MOT DE PASSE ADMINISTRATEUR LOCAL
# -----------------------------------------------------------------------------

function Set-LocalAdminPassword {
    <#
    .SYNOPSIS
        Definit le mot de passe du compte Administrateur local.
    .DESCRIPTION
        Recupere le mot de passe depuis le vault (jamais en clair dans les logs)
        et l'applique via [ADSI] pour eviter de passer par net.exe qui loggue.
        Active le compte s'il est desactive.
    .PARAMETER Password    Mot de passe a appliquer.
    .PARAMETER AccountName Nom du compte (defaut: Administrator / Administrateur).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Password,
        [string]$AccountName = 'Administrator'
    )

    Write-PLog "Configuration mot de passe administrateur local..." -Level INFO

    # Tenter le nom localise si Administrator n'existe pas
    $names = @($AccountName, 'Administrateur', 'Administrator')
    $account = $null
    foreach ($name in $names) {
        try {
            $account = [ADSI]"WinNT://./$name,user"
            if ($account.Name) { break }
        } catch { $account = $null }
    }

    if (-not $account) {
        throw "Compte Administrateur local introuvable (teste: $($names -join ', '))"
    }

    # Definir le mot de passe (pas de trace en clair dans les logs)
    $account.SetPassword($Password)
    $account.UserFlags = $account.UserFlags.Value -band (-bnot 2)  # Activer le compte (bit 2 = disabled)
    $account.SetInfo()

    Write-PLog "Mot de passe administrateur local configure" -Level SUCCESS

    # Verification sans afficher le mot de passe
    Write-PLog "Compte : $($account.Name) -- Active" -Level INFO
}

function Set-LocalAdminPasswordOffline {
    <#
    .SYNOPSIS Definit le mot de passe admin via unattend.xml (injection offline).
    .DESCRIPTION
        Pour la configuration du mot de passe admin dans un Windows non encore
        demarre, on injecte l'info dans unattend.xml au moment du Apply-WIM.
        L'unattend.xml sera lu par Windows Setup au 1er demarrage.
        Note : Le mot de passe sera en clair dans unattend.xml temporairement
        -- Windows le supprime apres le 1er demarrage si AutoLogon est configure.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$WindowsPath,
        [Parameter(Mandatory)]
        [string]$AdminPassword,
        [string]$DeployUsername = $script:DeployUser,
        [string]$DeployPassword
    )

    Write-PLog "Injection unattend.xml (admin password + compte deploy)..." -Level INFO

    $unattend = New-DeployUnattend -Username $DeployUsername -Password $DeployPassword

    # Ajouter la config du mot de passe admin dans l'unattend
    $unattend = $unattend -replace '</LocalAccounts>', @"
        </LocalAccounts>
      </UserAccounts>
      <!-- Mot de passe admin via AutoLogon premiere phase -->
"@

    $panther = Join-Path $WindowsPath 'Windows\Panther'
    if (-not (Test-Path $panther)) { New-Item -ItemType Directory $panther -Force | Out-Null }

    $unattend | Set-Content (Join-Path $panther 'unattend.xml') -Encoding UTF8
    Write-PLog "unattend.xml injecte dans $panther" -Level SUCCESS
}

# -----------------------------------------------------------------------------
# INJECTION STEPS DE SECURITE DANS LA SEQUENCE
# -----------------------------------------------------------------------------

function Add-SecuritySteps {
    <#
    .SYNOPSIS Injecte les steps autologon et admin password dans une sequence.#>
    param(
        [Parameter(Mandatory)]
        [PSCustomObject]$Sequence,
        [Parameter(Mandatory)]
        [PSCustomObject]$Profile
    )

    $sec = $Profile.security
    if (-not $sec) { return $Sequence }

    $stepsList = [System.Collections.Generic.List[PSCustomObject]]($Sequence.steps)

    # -- Step autologon setup (apres ApplyWIM, avant 1er reboot) --
    if ($sec.autologon -and $sec.autologon.enabled) {
        $autoLogonSetupStep = [PSCustomObject]@{
            id          = 'sec-autologon-setup'
            type        = 'RunScript'
            name        = 'Configuration autologon deploiement'
            enabled     = $true
            rebootAfter = 'Never'
            params      = [PSCustomObject]@{
                shell         = 'PowerShell'
                path          = 'INLINE'
                inlineScript  = @"
Import-Module C:\Deploy\Modules\ProfileManager\ProfileManager.psm1 -Force
`$pwd = Get-Secret -Source vault -Key '$($sec.autologon.credential.key)'
Set-AutoLogon -Username '$($sec.autologon.user)' -Password `$pwd -Count $(if ($sec.autologon.maxReboots) { $sec.autologon.maxReboots } else { 5 })
"@
            }
        }

        # Inserer juste apres ApplyWIM
        $applyIdx = 0
        for ($i = 0; $i -lt $stepsList.Count; $i++) {
            if ($stepsList[$i].type -eq 'ApplyWIM') { $applyIdx = $i + 1; break }
        }
        $stepsList.Insert($applyIdx, $autoLogonSetupStep)
    }

    # -- Step cleanup (tout a la fin) --
    $cleanupStep = [PSCustomObject]@{
        id          = 'sec-cleanup'
        type        = 'RunScript'
        name        = 'Nettoyage securite post-deploiement'
        enabled     = $true
        rebootAfter = 'Never'
        continueOnError = $true
        params      = [PSCustomObject]@{
            shell        = 'PowerShell'
            path         = 'INLINE'
            inlineScript = 'Import-Module C:\Deploy\Modules\ProfileManager\ProfileManager.psm1 -Force; Invoke-DeployCleanup'
        }
    }
    $stepsList.Add($cleanupStep)

    # -- Step mot de passe admin (avant cleanup) --
    if ($sec.localAdmin -and $sec.localAdmin.setPassword) {
        $adminPwdStep = [PSCustomObject]@{
            id          = 'sec-admin-password'
            type        = 'RunScript'
            name        = 'Definition mot de passe administrateur local'
            enabled     = $true
            rebootAfter = 'Never'
            params      = [PSCustomObject]@{
                shell        = 'PowerShell'
                path         = 'INLINE'
                inlineScript = @"
Import-Module C:\Deploy\Modules\ProfileManager\ProfileManager.psm1 -Force
Import-Module C:\Deploy\Modules\TaskSequence\TaskSequence.psm1 -Force
`$pwd = Get-Secret -Source vault -Key '$($sec.localAdmin.credential.key)'
Set-LocalAdminPassword -Password `$pwd
"@
            }
        }
        $stepsList.Insert($stepsList.Count - 1, $adminPwdStep)
    }

    $Sequence.steps = $stepsList.ToArray()
    return $Sequence
}

# -----------------------------------------------------------------------------
# CLEANUP FINAL
# -----------------------------------------------------------------------------

function Invoke-DeployCleanup {
    <#
    .SYNOPSIS
        Nettoyage complet post-deploiement.
    .DESCRIPTION
        - Supprime l'autologon
        - Supprime le compte temporaire de deploiement
        - Supprime les fichiers de deploiement sensibles
        - Supprime RunOnce
        - Nettoie les logs si demande
    #>
    [CmdletBinding()]
    param([switch]$KeepLogs)

    Write-PLog "=== Nettoyage post-deploiement ===" -Level STEP

    # Suppression autologon
    try { Remove-AutoLogon } catch { Write-PLog "Autologon deja absent" -Level INFO }

    # Suppression compte temporaire
    try { Remove-DeployTempUser } catch { Write-PLog "Compte deploy deja absent" -Level INFO }

    # Suppression RunOnce
    try {
        Remove-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce' `
            -Name 'PSWinDeploy-Resume' -ErrorAction SilentlyContinue
    } catch {}

    # Suppression fichiers sensibles
    $sensitiveFiles = @(
        'C:\Deploy\secrets.vault',
        'C:\Deploy\state.psd1',
        'C:\Windows\Panther\unattend.xml'
    )
    foreach ($f in $sensitiveFiles) {
        if (Test-Path $f) {
            Remove-Item $f -Force -ErrorAction SilentlyContinue
            Write-PLog "Supprime : $f" -Level INFO
        }
    }

    if (-not $KeepLogs) {
        Write-PLog "Logs conserves dans C:\Deploy\Logs" -Level INFO
    }

    Write-PLog "Nettoyage termine -- machine prete" -Level SUCCESS
}

# -----------------------------------------------------------------------------
# SELECTEUR INTERACTIF DE PROFIL (CONSOLE WINPE)
# -----------------------------------------------------------------------------

function Invoke-ProfileSelector {
    <#
    .SYNOPSIS Assistant console WinPE de selection de profil.
    .OUTPUTS PSCustomObject profil selectionne
    #>
    [CmdletBinding()]
    param([string]$ProfilesPath)

    $profiles = Get-DeployProfile -ProfilesPath:$(if ($ProfilesPath) { $ProfilesPath } else { $script:ProfilesRoot })
    if ($profiles.Count -eq 0) { throw "Aucun profil disponible" }

    Clear-Host
    Write-Host ""
    Write-Host "  +-----------------------------------------------------+" -ForegroundColor Cyan
    Write-Host "  |         PSWinDeploy -- Selection du profil           |" -ForegroundColor Cyan
    Write-Host "  +-----------------------------------------------------+" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "  Profils disponibles :" -ForegroundColor White
    Write-Host ""

    $i = 1
    foreach ($p in $profiles) {
        $appCount   = if ($p.requiredApps)  { $p.requiredApps.Count  } else { 0 }
        $optCount   = if ($p.defaultApps)   { $p.defaultApps.Count   } else { 0 }
        $domainStr  = if ($p.overrides.'metadata.domain') { " [Domaine: $($p.overrides.'metadata.domain')]" } else { " [Standalone]" }
        $colorIcon  = switch ($p.color) {
            'teal'   { 'Green'   }
            'purple' { 'Magenta' }
            'amber'  { 'Yellow'  }
            default  { 'Cyan'    }
        }

        Write-Host "    " -NoNewline
        Write-Host "[$i]" -ForegroundColor Yellow -NoNewline
        Write-Host " $($p.name)" -ForegroundColor White -NoNewline
        Write-Host $domainStr -ForegroundColor $colorIcon
        Write-Host "        $($p.description)" -ForegroundColor DarkGray
        Write-Host "        $appCount app(s) obligatoire(s) . $optCount app(s) par defaut" -ForegroundColor DarkGray
        Write-Host ""
        $i++
    }

    $choice = $null
    while ($null -eq $choice) {
        Write-Host "  Choisissez un profil [1-$($profiles.Count)] : " -ForegroundColor Cyan -NoNewline
        $in = Read-Host
        if ($in -match '^\d+$' -and [int]$in -ge 1 -and [int]$in -le $profiles.Count) {
            $choice = [int]$in - 1
        } else {
            Write-Host "  Choix invalide." -ForegroundColor Red
        }
    }

    $selected = $profiles[$choice]
    Write-Host ""
    Write-Host "  Profil selectionne : $($selected.name)" -ForegroundColor Green
    Write-Host ""
    return $selected
}

Export-ModuleMember -Function @(
    'Get-DeployProfile'
    'Resolve-ProfileSequence'
    'Get-DeployCatalogue'
    'Set-AutoLogon'
    'Set-AutoLogonOffline'
    'Remove-AutoLogon'
    'New-DeployTempUser'
    'Remove-DeployTempUser'
    'Set-LocalAdminPassword'
    'Set-LocalAdminPasswordOffline'
    'Invoke-DeployCleanup'
    'Invoke-ProfileSelector'
)
