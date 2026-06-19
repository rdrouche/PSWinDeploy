@{
    ModuleVersion     = '0.1.0'
    GUID              = 'a1b2c3d4-0001-0001-0001-000000000001'
    Author            = 'PSWinDeploy'
    Description       = "Construction d'environnements WinPE bootables"
    PowerShellVersion = '5.1'
    RequiredModules   = @('Config')
    RootModule        = 'WinPE-Builder.psm1'
    FunctionsToExport = @(
        'Set-WinPEConfig','Get-WinPEConfig',
        'New-WinPEEnvironment','Add-WinPEDriver','Add-WinPEPackage',
        'Get-WinPEAvailablePackages','Set-WinPECustomization',
        'Save-WinPEImage','Build-WinPEMedia','Invoke-WinPEBuild'
    )
}
