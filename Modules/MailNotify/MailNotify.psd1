@{
    RootModule        = 'MailNotify.psm1'
    ModuleVersion     = '0.9.0'
    GUID              = 'b8f3c1a2-6d94-4e57-9c31-7a2e5f0d84b6'
    Author            = 'PSWinDeploy'
    Description       = 'End-of-deployment email notification (simple flat SMTP config).'
    PowerShellVersion = '5.1'
    FunctionsToExport = @('Send-DeployMail','Test-MailNotifyEnabled','Get-MailNotifyConfig')
    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()
}
