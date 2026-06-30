@{
    ModuleVersion     = '0.8.0'
    GUID              = 'a1b2c3d4-0008-0008-0008-000000000008'
    Author            = 'PSWinDeploy'
    Description       = 'Connexion aux partages reseau depuis WinPE (svc-winpe, vault, plain)'
    PowerShellVersion = '5.1'
    RootModule        = 'NetShare.psm1'
    FunctionsToExport = @(
        'Connect-DeployShare','Disconnect-DeployShare',
        'Test-DeployShareAccess','Resolve-ShareCredential',
        'New-WinPEShareVault'
    )
}
