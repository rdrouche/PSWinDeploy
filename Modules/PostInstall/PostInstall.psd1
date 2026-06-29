@{
    RootModule        = 'PostInstall.psm1'
    ModuleVersion     = '0.7.0'
    GUID              = 'c3d5f7b9-2468-3579-abcd-ef0123456789'
    Author            = 'PSWinDeploy'
    Description       = 'Assistant de post-installation (phase 2) : sequence par MAC ou construction interactive.'
    PowerShellVersion = '5.1'
    FunctionsToExport = @('Get-PrimaryMacAddress','Resolve-PostInstallSequence','New-PostInstallSequenceFromTemplate','Show-PostInstallWizard','Select-TemplateSequence','Build-SequenceInteractive')
}
