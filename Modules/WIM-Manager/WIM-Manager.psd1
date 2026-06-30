@{
    ModuleVersion     = '0.8.0'
    GUID              = 'a1b2c3d4-0002-0002-0002-000000000002'
    Author            = 'PSWinDeploy'
    Description       = "Gestion des images WIM - capture, montage, deploiement"
    PowerShellVersion = '5.1'
    RootModule        = 'WIM-Manager.psm1'
    FunctionsToExport = @(
        'Get-WIMInfo','New-WIMCapture','Mount-WIMImage','Save-WIMImage',
        'Repair-WIMMountCleanup','Apply-WIMImage','Export-WIMImage',
        'Initialize-DeployDisk','Set-WindowsBootloader','Invoke-WIMDeploy'
    )
}
