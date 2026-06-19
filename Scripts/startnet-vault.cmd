@echo off
@REM =========================================================================
@REM startnet.cmd — Mode Vault (credentials dans X:\Deploy\secrets.vault)
@REM Le vault doit etre injecte dans le WIM lors du build :
@REM   Invoke-WinPEBuild -Server SERVEUR -VaultPath C:\Deploy\secrets.vault
@REM Le vault doit contenir les cles : winpeUser, winpePassword
@REM =========================================================================

wpeinit
echo.
echo  [PSWinDeploy] Lancement deploiement (mode vault)...
PowerShell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Normal ^
    -File X:\Deploy\Scripts\Start-Deploy.ps1 ^
    -NetworkShare "\\SERVEUR\Deploy" ^
    -CredentialMode Vault

if %ERRORLEVEL% NEQ 0 (
    echo  [ERREUR] Echec deploiement - console de diagnostic
    pause
    cmd.exe /k
)
