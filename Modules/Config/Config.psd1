@{
    ModuleVersion     = '0.4.0'
    GUID              = 'a1b2c3d4-0006-0006-0006-000000000006'
    Author            = 'PSWinDeploy'
    Description       = 'Chargeur de configuration central PSWinDeploy'
    PowerShellVersion = '5.1'
    RootModule        = 'Config.psm1'
    FunctionsToExport = @(
        'Import-PSWinDeployConfig','Get-PSWinDeployConfig',
        'Set-PSWinDeployConfig','Show-PSWinDeployConfig'
    )
}
