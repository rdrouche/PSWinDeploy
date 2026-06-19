@echo off
wpeinit

echo.
echo  PSWinDeploy - Initialisation reseau...
echo.

REM ─────────────────────────────────────────────────────────────────────────
REM CHOIX DU MODE DE CONNEXION AU PARTAGE
REM Decommenter UNE seule section selon votre environnement.
REM ─────────────────────────────────────────────────────────────────────────

REM ── MODE 1 : Auto (Vault -> Env -> Prompt) ──────────────────────────────
REM Recommande en production. Le vault secrets.vault doit etre dans X:\Deploy\
REM Lancer Start-Deploy.ps1 sans parametres supplementaires.
PowerShell.exe -NoProfile -ExecutionPolicy Bypass -File "X:\Deploy\Scripts\Start-Deploy.ps1"

REM ── MODE 2 : Plain (credentials en clair, comme MDT) ────────────────────
REM Simple, pratique pour les labs. Utiliser un compte dedie lecture seule.
REM PowerShell.exe -NoProfile -ExecutionPolicy Bypass -File "X:\Deploy\Scripts\Start-Deploy.ps1" ^
REM   -CredentialMode Plain ^
REM   -ShareUser "DEPLOYSRV\svc-winpe" ^
REM   -SharePassword "MotDePasseShare!"

REM ── MODE 3 : Plain via net use direct (MDT style) ───────────────────────
REM Connexion faite ici, avant PowerShell. Start-Deploy.ps1 passe en mode Skip.
REM net use \\DEPLOYSRV\Deploy    MotDePasseShare! /user:DEPLOYSRV\svc-winpe /persistent:no
REM net use \\DEPLOYSRV\Images    MotDePasseShare! /user:DEPLOYSRV\svc-winpe /persistent:no
REM net use \\DEPLOYSRV\Drivers   MotDePasseShare! /user:DEPLOYSRV\svc-winpe /persistent:no
REM net use \\DEPLOYSRV\Logs      MotDePasseShare! /user:DEPLOYSRV\svc-winpe /persistent:no
REM PowerShell.exe -NoProfile -ExecutionPolicy Bypass -File "X:\Deploy\Scripts\Start-Deploy.ps1" ^
REM   -CredentialMode Skip

REM ── MODE 4 : Vault AES avec mot de passe passe en argument ──────────────
REM Le mot de passe vault peut venir d'une variable WDS/PXE ou etre code ici.
REM PowerShell.exe -NoProfile -ExecutionPolicy Bypass -File "X:\Deploy\Scripts\Start-Deploy.ps1" ^
REM   -CredentialMode Vault ^
REM   -VaultPassword "MotDePasseVault!"
