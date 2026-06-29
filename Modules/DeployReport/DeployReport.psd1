@{
    RootModule        = 'DeployReport.psm1'
    ModuleVersion     = '0.7.0'
    GUID              = 'b7e4d2a1-9c3f-4e8a-b6d5-2f1a8c7e4b90'
    Author            = 'PSWinDeploy'
    Description       = 'Suivi de deploiement cote client : heartbeats vers l API web (Send-DeployReport) et depot des coordonnees API (Set-DeployApiEndpoint). Module leger sans dependance.'
    PowerShellVersion = '5.1'
    FunctionsToExport = @('Send-DeployReport','Set-DeployApiEndpoint','Register-DeployWaiting','Get-DeployPending','Get-DeployClientMac')
    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()
}
