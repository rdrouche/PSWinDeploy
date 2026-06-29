@{
    ModuleVersion     = '0.7.0'
    GUID              = 'a1b2c3d4-0007-0007-0007-000000000007'
    Author            = 'PSWinDeploy'
    Description       = 'Notifications deploiement -- SMTP et Teams Webhook'
    PowerShellVersion = '5.1'
    RootModule        = 'Notify.psm1'
    FunctionsToExport = @(
        'Send-DeployNotification','Send-DeployMailNotification',
        'Send-DeployTeamsNotification','Build-DeployMessage','Test-NotifyConfig'
    )
}
