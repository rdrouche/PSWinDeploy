@{
    Id       = 'test-phase2'
    Name     = 'Test Phase 2 (validation)'
    Version  = '1.0.0'
    Metadata = @{ Os = 'Windows'; Locale = 'fr-FR' }
    Options  = @{ ContinueOnError = $true; LogLevel = 'Info' }
    Steps    = @(
        @{
            Id          = 'test-01'
            Type        = 'RunScript'
            Name        = 'Script de test (cree C:\test\test.txt)'
            Phase       = 'Windows'
            Enabled     = $true
            RebootAfter = 'Never'
            Params      = @{ Path = 'C:\Deploy\Scripts\Test-PostInstall.ps1'; Shell = 'PowerShell' }
        }
    )
}
