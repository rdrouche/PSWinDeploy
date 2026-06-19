@echo off
@REM =========================================================================
@REM startnet.cmd — Mode Plain (credentials en clair, comme MDT)
@REM Adapter : SERVEUR, svc-winpe, MotDePasse
@REM =========================================================================

wpeinit
echo.
echo  [PSWinDeploy] Connexion partages reseau...

net use \\SERVEUR\Deploy     MotDePasse /user:SERVEUR\svc-winpe /persistent:No
net use \\SERVEUR\Images     MotDePasse /user:SERVEUR\svc-winpe /persistent:No
net use \\SERVEUR\Drivers    MotDePasse /user:SERVEUR\svc-winpe /persistent:No
net use \\SERVEUR\Logiciels  MotDePasse /user:SERVEUR\svc-winpe /persistent:No
net use \\SERVEUR\Scripts    MotDePasse /user:SERVEUR\svc-winpe /persistent:No
net use \\SERVEUR\Logs       MotDePasse /user:SERVEUR\svc-winpe /persistent:No

echo  [PSWinDeploy] Lancement deploiement...
PowerShell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Normal ^
    -File X:\Deploy\Scripts\Start-Deploy.ps1 ^
    -NetworkShare "\\SERVEUR\Deploy" ^
    -CredentialMode Skip

if %ERRORLEVEL% NEQ 0 (
    echo  [ERREUR] Echec deploiement - console de diagnostic
    pause
    cmd.exe /k
)
