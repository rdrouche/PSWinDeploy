@{
    ModuleVersion     = '0.7.0'
    GUID              = 'a1b2c3d4-0004-0004-0004-000000000004'
    Author            = 'PSWinDeploy'
    Description       = 'Assistant interactif de selection de disque pour WinPE'
    PowerShellVersion = '5.1'
    RootModule        = 'DiskSelector.psm1'
    FunctionsToExport = @(
        'Show-DiskMap','Invoke-DiskSelector',
        'Invoke-WIMIndexSelector','Invoke-PreDeployWizard'
    )
}
