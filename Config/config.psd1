# PSWinDeploy -- config.json
@{
    WinPE = @{
        Architecture = 'amd64'
        Locale = 'fr-FR'
        Packages = @(
            'PowerShell'
            'WMI'
            'NetFx'
            'Scripting'
        )
        WorkspacePath = 'D:\WinPE-Work'
    }
    Deploy = @{
        FirmwareType = 'UEFI'
        DiskNumber = 0
        WimIndex = 1
        Locale = 'fr-FR'
    }
    Network = @{
        ImageShare = '\\SERVEUR\Images'
        LogShare = '\\SERVEUR\Logs'
    }
}