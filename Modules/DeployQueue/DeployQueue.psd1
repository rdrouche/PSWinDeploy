@{
    RootModule        = 'DeployQueue.psm1'
    ModuleVersion     = '0.7.0'
    GUID              = 'c8f1e3b2-7a4d-4f9c-8e21-3b6d9a0c5e74'
    Author            = 'PSWinDeploy'
    Description       = 'File d attente de sequences par poste (mode en attente / pull interactif). Cote API.'
    PowerShellVersion = '5.1'
    FunctionsToExport = @('Initialize-DeployQueue','Register-WaitingDeployment','Get-WaitingDeployments','Set-PendingSequence','Get-PendingSequence','Clear-WaitingDeployment')
    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()
}
