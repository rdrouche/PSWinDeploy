#Requires -Version 5.1
<#
.SYNOPSIS
    PSWinDeploy.Unattend -- Generation d'unattend.xml a la volee
.DESCRIPTION
    Genere un fichier unattend.xml (Windows Setup answer file) qui applique
    automatiquement, AU PREMIER DEMARRAGE de Windows, les parametres qui ne
    peuvent pas (ou mal) etre faits depuis WinPE :

      - Nom de la machine (sans toucher au registre offline)
      - Jonction de domaine / workgroup
      - Compte administrateur local + mot de passe
      - OOBE : skip EULA, region, clavier, reseau, privacy
      - Premier utilisateur / autologon
      - Fuseau horaire, langue, locale
      - Commandes FirstLogon (lancer la phase 2 du deploiement)

    AVANTAGE vs registre offline :
      - Methode officielle Microsoft, robuste
      - Applique au bon moment (specialize / oobeSystem)
      - Pas de manipulation de ruche risquee
      - Permet l'autologon pour enchainer la phase 2 automatiquement

    Le XML est ecrit dans W:\\Windows\\Panther\\unattend.xml (lu par Windows Setup
    au premier boot) ou passe a /unattend lors de l'application.
#>

Set-StrictMode -Version Latest

function New-UnattendXml {
    <#
    .SYNOPSIS Genere le contenu XML d'un unattend.xml.
    .PARAMETER ComputerName Nom de la machine (max 15 car).
    .PARAMETER Domain       Domaine AD a joindre (optionnel).
    .PARAMETER DomainOU     OU de destination (optionnel).
    .PARAMETER DomainUser   Compte de jonction (DOMAIN\\user).
    .PARAMETER DomainPassword Mot de passe de jonction.
    .PARAMETER Workgroup    Workgroup si pas de domaine (defaut WORKGROUP).
    .PARAMETER LocalAdminPassword Mot de passe admin local.
    .PARAMETER AutoLogonUser Compte pour l'autologon (enchainer phase 2).
    .PARAMETER AutoLogonPassword Mot de passe autologon.
    .PARAMETER AutoLogonCount Nombre de logons auto (defaut 1).
    .PARAMETER FirstLogonCommand Commande lancee au 1er logon (phase 2).
    .PARAMETER TimeZone     Fuseau (defaut 'Romance Standard Time' = Paris).
    .PARAMETER UILanguage   Langue UI (defaut fr-FR).
    .PARAMETER InputLocale  Disposition clavier (defaut 040c:0000040c = FR).
    .PARAMETER Architecture amd64 (defaut) ou x86.
    .OUTPUTS [string] contenu XML
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ComputerName,
        [string]$Domain,
        [string]$DomainOU,
        [string]$DomainUser,
        [string]$DomainPassword,
        [string]$Workgroup = 'WORKGROUP',
        [string]$LocalAdminPassword,
        [string]$AutoLogonUser,
        [string]$AutoLogonPassword,
        [int]$AutoLogonCount = 1,
        [string]$FirstLogonCommand,
        [string]$TimeZone = 'Romance Standard Time',
        [string]$UILanguage = 'fr-FR',
        [string]$SystemLocale = '',
        [string]$InputLocale = '040c:0000040c',
        [string]$Architecture = 'amd64',
        # -- Extensibilite --
        [string]$TemplatePath,                    # Template XML custom (remplace le defaut)
        [hashtable]$ExtraSpecialize = @{},        # Fragments XML additionnels pass specialize
        [hashtable]$ExtraOobe = @{},              # Fragments XML additionnels pass oobeSystem
        [string]$ExtraSpecializeXml = '',         # Bloc XML brut a injecter dans specialize
        [string]$ExtraOobeXml = '',               # Bloc XML brut a injecter dans oobeSystem
        [hashtable]$Replacements = @{}            # Substitutions {{CLE}} -> valeur dans le template
    )

    # Helper : echapper le XML
    function Esc { param([string]$s) if ($null -eq $s) { '' } else { [System.Security.SecurityElement]::Escape($s) } }

    # -- MODE TEMPLATE CUSTOM (si fourni) --------------------------------------
    if ($TemplatePath -and (Test-Path $TemplatePath -EA SilentlyContinue)) {
        $template = Get-Content $TemplatePath -Raw
        $effAdmin = if ($LocalAdminPassword) { $LocalAdminPassword } else { 'P@ssw0rd-Deploy!' }
        $subs = @{
            'COMPUTERNAME'  = (Esc $ComputerName); 'DOMAIN' = (Esc $Domain)
            'DOMAINOU'      = (Esc $DomainOU); 'DOMAINUSER' = (Esc ($DomainUser -replace '^.*\\',''))
            'DOMAINPASSWORD'= (Esc $DomainPassword); 'WORKGROUP' = (Esc $Workgroup)
            'ADMINPASSWORD' = (Esc $effAdmin); 'TIMEZONE' = (Esc $TimeZone)
            'UILANGUAGE'    = (Esc $UILanguage); 'INPUTLOCALE' = (Esc $InputLocale)
            'ARCH'          = $Architecture; 'PHASE2CMD' = (Esc $FirstLogonCommand)
        }
        foreach ($k in $Replacements.Keys) { $subs[$k] = $Replacements[$k] }
        foreach ($k in $subs.Keys) { $template = $template -replace [regex]::Escape("{{$k}}"), $subs[$k] }
        return $template
    }

    # SystemLocale par defaut = UILanguage (coherence langue)
    if (-not $SystemLocale) { $SystemLocale = $UILanguage }

    # -- specialize : UnattendedJoin SEULEMENT si jonction domaine (sinon rien) -----
    $joinComponent = ''
    if ($Domain -and $DomainUser) {
        $ouLine = if ($DomainOU) { "                    <MachineObjectOU>$(Esc $DomainOU)</MachineObjectOU>" } else { '' }
        $joinComponent = @"
        <component name="Microsoft-Windows-UnattendedJoin" processorArchitecture="$Architecture"
                   publicKeyToken="31bf3856ad364e35" language="neutral"
                   versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State">
            <Identification>
                <Credentials>
                    <Domain>$(Esc $Domain)</Domain>
                    <Username>$(Esc ($DomainUser -replace '^.*\\',''))</Username>
                    <Password>$(Esc $DomainPassword)</Password>
                </Credentials>
                <JoinDomain>$(Esc $Domain)</JoinDomain>
$ouLine
            </Identification>
        </component>
"@
    }

    # -- oobeSystem : compte admin + autologon (toujours, pour passer l'OOBE) -------
    $effectiveAdminPwd = if ($LocalAdminPassword) { $LocalAdminPassword } else { 'P@ssw0rd-Deploy!' }

    # FirstLogonCommands (phase 2)
    $firstLogonBlock = ''
    if ($FirstLogonCommand) {
        $firstLogonBlock = @"
            <FirstLogonCommands>
                <SynchronousCommand wcm:action="add">
                    <Order>1</Order>
                    <CommandLine>$(Esc $FirstLogonCommand)</CommandLine>
                    <Description>PSWinDeploy phase 2</Description>
                    <RequiresUserInput>false</RequiresUserInput>
                </SynchronousCommand>
            </FirstLogonCommands>
"@
    }

    # AutoLogon sur le compte Administrateur builtin (active par AdministratorPassword)
    # LogonCount limite pour eviter une boucle si phase 2 echoue
    $autoLogonBlock = ''
    if ($FirstLogonCommand) {
        $autoLogonBlock = @"
            <AutoLogon>
                <Password>
                    <Value>$(Esc $effectiveAdminPwd)</Value>
                    <PlainText>true</PlainText>
                </Password>
                <Enabled>true</Enabled>
                <LogonCount>$AutoLogonCount</LogonCount>
                <Username>Administrator</Username>
                <Domain>.</Domain>
            </AutoLogon>
"@
    }

    # -- Assemblage final ----------------------------------------------------------
    $xml = @"
<?xml version="1.0" encoding="utf-8"?>
<unattend xmlns="urn:schemas-microsoft-com:unattend">

    <settings pass="specialize">
        <component name="Microsoft-Windows-International-Core" processorArchitecture="$Architecture"
                   publicKeyToken="31bf3856ad364e35" language="neutral"
                   versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State">
            <InputLocale>$(Esc $InputLocale)</InputLocale>
            <SystemLocale>$(Esc $SystemLocale)</SystemLocale>
            <UILanguage>$(Esc $UILanguage)</UILanguage>
            <UserLocale>$(Esc $UILanguage)</UserLocale>
        </component>
        <component name="Microsoft-Windows-Shell-Setup" processorArchitecture="$Architecture"
                   publicKeyToken="31bf3856ad364e35" language="neutral"
                   versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State">
            <ComputerName>$(Esc $ComputerName)</ComputerName>
            <TimeZone>$(Esc $TimeZone)</TimeZone>
        </component>
        <component name="Microsoft-Windows-Deployment" processorArchitecture="$Architecture"
                   publicKeyToken="31bf3856ad364e35" language="neutral"
                   versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State">
            <RunSynchronous>
                <RunSynchronousCommand wcm:action="add">
                    <Description>EnableAdmin</Description>
                    <Order>1</Order>
                    <Path>cmd /c net user Administrator /active:yes</Path>
                </RunSynchronousCommand>
                <RunSynchronousCommand wcm:action="add">
                    <Description>UnfilterAdministratorToken</Description>
                    <Order>2</Order>
                    <Path>cmd /c reg add HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System /v FilterAdministratorToken /t REG_DWORD /d 0 /f</Path>
                </RunSynchronousCommand>
                <RunSynchronousCommand wcm:action="add">
                    <Description>UnattendCreatedUser</Description>
                    <Order>3</Order>
                    <Path>reg add HKLM\Software\Microsoft\Windows\CurrentVersion\Setup\OOBE /v UnattendCreatedUser /t REG_DWORD /d 1 /f</Path>
                </RunSynchronousCommand>
            </RunSynchronous>
        </component>
$joinComponent$ExtraSpecializeXml
    </settings>

    <settings pass="oobeSystem">
        <component name="Microsoft-Windows-International-Core" processorArchitecture="$Architecture"
                   publicKeyToken="31bf3856ad364e35" language="neutral"
                   versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State">
            <InputLocale>$(Esc $InputLocale)</InputLocale>
            <SystemLocale>$(Esc $SystemLocale)</SystemLocale>
            <UILanguage>$(Esc $UILanguage)</UILanguage>
            <UserLocale>$(Esc $UILanguage)</UserLocale>
        </component>
        <component name="Microsoft-Windows-Shell-Setup" processorArchitecture="$Architecture"
                   publicKeyToken="31bf3856ad364e35" language="neutral"
                   versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State">
            <UserAccounts>
                <AdministratorPassword>
                    <Value>$(Esc $effectiveAdminPwd)</Value>
                    <PlainText>true</PlainText>
                </AdministratorPassword>
            </UserAccounts>
            <OOBE>
                <HideEULAPage>true</HideEULAPage>
                <HideLocalAccountScreen>true</HideLocalAccountScreen>
                <HideOnlineAccountScreens>true</HideOnlineAccountScreens>
                <HideWirelessSetupInOOBE>true</HideWirelessSetupInOOBE>
                <NetworkLocation>Work</NetworkLocation>
                <ProtectYourPC>1</ProtectYourPC>
            </OOBE>
            <TimeZone>$(Esc $TimeZone)</TimeZone>
$autoLogonBlock$firstLogonBlock$ExtraOobeXml
        </component>
    </settings>

</unattend>
"@

    return $xml

}

function Write-UnattendFile {
    <#
    .SYNOPSIS Genere et ecrit l'unattend.xml sur la partition Windows cible.
    .DESCRIPTION
        Ecrit dans <TargetDrive>\\Windows\\Panther\\unattend.xml -- emplacement
        lu automatiquement par Windows Setup au premier demarrage.
    .PARAMETER TargetDrive Lettre du disque Windows (ex: 'W:').
    .PARAMETER Parameters  Hashtable des parametres pour New-UnattendXml.
    .OUTPUTS [string] chemin du fichier ecrit
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$TargetDrive,
        [Parameter(Mandatory)][hashtable]$Parameters
    )
    $drive = $TargetDrive.TrimEnd('\').TrimEnd(':') + ':'
    $pantherDir = Join-Path $drive 'Windows\Panther'
    if (-not (Test-Path $pantherDir -EA SilentlyContinue)) {
        New-Item -ItemType Directory $pantherDir -Force | Out-Null
    }
    $xmlContent = New-UnattendXml @Parameters
    $xmlPath = Join-Path $pantherDir 'unattend.xml'
    # UTF-8 sans BOM (Windows Setup prefere)
    $utf8 = New-Object System.Text.UTF8Encoding $false
    [System.IO.File]::WriteAllText($xmlPath, $xmlContent, $utf8)

    # NE PAS appliquer l'unattend via dism /Apply-Unattend : la doc Microsoft
    # precise que DISM ne traite QUE le pass 'offlineServicing'. Les passes
    # 'specialize' et 'oobeSystem' (compte admin, OOBE, autologon, phase 2) sont
    # IGNOREES, et l'application offline entre en conflit avec l'unattend.xml place
    # dans Panther que Windows Setup retraite au premier boot. Cette double
    # application corrompt la configuration -> CRITICAL_PROCESS_DIED.
    #
    # La bonne methode (confirmee par le test minimal qui boote) : deposer
    # simplement l'unattend.xml dans Windows\Panther\. Windows Setup le detecte
    # automatiquement au premier demarrage et traite TOUTES les passes.

    return $xmlPath
}

Export-ModuleMember -Function @(
    'New-UnattendXml'
    'Write-UnattendFile'
)
