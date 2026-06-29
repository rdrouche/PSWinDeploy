@{
    ModuleVersion     = '0.7.0'
    GUID              = 'a1b2c3d4-0005-0005-0005-000000000005'
    Author            = 'PSWinDeploy'
    Description       = "Gestion des profils, autologon et securite post-deploiement"
    PowerShellVersion = '5.1'
    RootModule        = 'ProfileManager.psm1'
    RequiredModules   = @()  # charges manuellement par Import-DeployModule (ordre gere par les scripts)
    FunctionsToExport = @(
        'Get-DeployProfile','Resolve-ProfileSequence','Get-DeployCatalogue',
        'Set-AutoLogon','Set-AutoLogonOffline','Remove-AutoLogon',
        'New-DeployTempUser','Remove-DeployTempUser',
        'Set-LocalAdminPassword','Set-LocalAdminPasswordOffline',
        'Invoke-DeployCleanup','Invoke-ProfileSelector'
    )
}
