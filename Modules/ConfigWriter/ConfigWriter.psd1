@{
    RootModule        = 'ConfigWriter.psm1'
    ModuleVersion     = '0.9.0'
    GUID              = 'c4e7a9f1-3b28-4d65-8a02-9f1e6c5b7d40'
    Author            = 'PSWinDeploy'
    Description       = 'Secure surgical editing of the PSWinDeploy.psd1 email section (backup + validation).'
    PowerShellVersion = '5.1'
    FunctionsToExport = @('Set-EmailConfig')
    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()
}
