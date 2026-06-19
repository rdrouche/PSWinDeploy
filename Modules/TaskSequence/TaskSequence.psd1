@{
    ModuleVersion     = '0.2.0'
    GUID              = 'a1b2c3d4-0003-0003-0003-000000000003'
    Author            = 'PSWinDeploy'
    Description       = "Moteur d'execution des sequences de deploiement JSON"
    PowerShellVersion = '5.1'
    RootModule        = 'TaskSequence.psm1'
    RequiredModules   = @('WIM-Manager','DiskSelector')
    FunctionsToExport = @(
        'Invoke-TaskSequence','Test-TaskSequence',
        'Initialize-SecretVault','Get-Secret',
        'Save-DeployState','Get-DeployState','Remove-DeployState','Invoke-DeployReboot'
    )
}
