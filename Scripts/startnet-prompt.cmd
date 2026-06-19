@echo off
@REM =========================================================================
@REM startnet.cmd — Mode Prompt (saisie interactive operateur)
@REM L operateur saisit le compte et mot de passe dans la console WinPE
@REM =========================================================================

wpeinit
echo.
echo  [PSWinDeploy] Lancement deploiement (mode prompt)...
PowerShell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Normal ^
    -File X:\Deploy\Scripts\Start-Deploy.ps1 ^
    -NetworkShare "\\SERVEUR\Deploy" ^
    -CredentialMode Prompt

if %ERRORLEVEL% NEQ 0 (
    echo  [ERREUR] Echec deploiement - console de diagnostic
    pause
    cmd.exe /k
)
