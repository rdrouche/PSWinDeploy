#Requires -Version 5.1
<#
.SYNOPSIS
    ConfigWriter.psm1 -- Ecriture SECURISEE de la section email de PSWinDeploy.psd1.
.DESCRIPTION
    Permet d'editer depuis l'interface web UNIQUEMENT les cles de notification
    email (liste blanche). Approche volontairement prudente :

      1. Sauvegarde horodatee avant toute ecriture :
           <root>\Config-Backup\PSWinDeploy.YYYYMMDD-HHMMSS.bak
         (historique complet conserve, jamais purge).
      2. Edition CHIRURGICALE : on remplace uniquement la valeur de chaque cle
         email dans le texte du fichier, en preservant commentaires, autres
         cles, indentation et mise en forme. Les cles absentes sont ajoutees.
      3. Ecriture dans un fichier temporaire, puis VALIDATION par
         Import-PowerShellDataFile. L'original n'est remplace QUE si le nouveau
         fichier est valide (sinon rollback, original intact).

    Seules ces cles sont editables (rien d'autre n'est touche) :
      NotifEmail, SMTP_FROM, SMTP_TO, SMTP_Server, SMTP_Port,
      SMTP_SECURE, SMTP_USER, SMTP_PASSWORD

    Le mot de passe est en clair dans le psd1 (compromis assume). Si la valeur
    recue vaut '********' (masque non modifie), le mot de passe existant est
    CONSERVE tel quel.
#>

# Cles email autorisees + leur type ('bool' | 'int' | 'string').
$script:EmailKeys = [ordered]@{
    NotifEmail    = 'bool'
    SMTP_FROM     = 'string'
    SMTP_TO       = 'string'
    SMTP_Server   = 'string'
    SMTP_Port     = 'int'
    SMTP_SECURE   = 'string'
    SMTP_USER     = 'string'
    SMTP_PASSWORD = 'string'
}

function Format-PsValue {
    <# .SYNOPSIS Serialise une valeur en litteral PowerShell selon son type. #>
    param([string]$Type, $Value)
    switch ($Type) {
        'bool' {
            $b = $false
            if ($Value -is [bool]) { $b = $Value }
            elseif ("$Value" -match '^(true|1|yes|on)$') { $b = $true }
            if ($b) { return '$true' } else { return '$false' }
        }
        'int' {
            $n = 0
            if ([int]::TryParse("$Value", [ref]$n)) { return "$n" }
            return '0'
        }
        default {
            # String : echapper les quotes simples (doublage) et encadrer.
            $s = "$Value" -replace "'", "''"
            return "'$s'"
        }
    }
}

function Set-EmailConfig {
    <#
    .SYNOPSIS
        Ecrit la section email dans PSWinDeploy.psd1 (backup + validation).
    .PARAMETER ConfigPath
        Chemin du PSWinDeploy.psd1.
    .PARAMETER Values
        Hashtable des cles email a ecrire (sous-ensemble autorise). La cle
        SMTP_PASSWORD valant '********' est ignoree (mot de passe conserve).
    .OUTPUTS
        PSCustomObject : @{ success = $true/$false; backup = '<nom.bak>'; error = '...' }
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$ConfigPath,
        [Parameter(Mandatory)] [hashtable]$Values
    )

    try {
        if (-not (Test-Path $ConfigPath)) {
            return [PSCustomObject]@{ success = $false; error = "Config file not found: $ConfigPath" }
        }

        # -- Lecture du texte original (avec BOM) --
        $rawBytes = [System.IO.File]::ReadAllBytes($ConfigPath)
        $hasBom = ($rawBytes.Length -ge 3 -and $rawBytes[0] -eq 0xEF -and $rawBytes[1] -eq 0xBB -and $rawBytes[2] -eq 0xBF)
        $text = [System.Text.Encoding]::UTF8.GetString($rawBytes)
        if ($hasBom) { $text = $text.TrimStart([char]0xFEFF) }

        # Detecter le style de fin de ligne du fichier pour rester coherent lors
        # d'un ajout de cle (evite de melanger \n et \r\n, ce qui cassait la
        # detection au tour suivant et provoquait des cles dupliquees).
        $nl = if ($text -match "`r`n") { "`r`n" } else { "`n" }

        # -- 1) Sauvegarde horodatee dans Config-Backup\ --
        $root = Split-Path $ConfigPath -Parent
        $backupDir = Join-Path $root 'Config-Backup'
        if (-not (Test-Path $backupDir)) { New-Item -ItemType Directory -Path $backupDir -Force | Out-Null }
        $stamp = (Get-Date).ToString('yyyyMMdd-HHmmss')
        $backupName = "PSWinDeploy.$stamp.bak"
        $backupPath = Join-Path $backupDir $backupName
        Copy-Item -Path $ConfigPath -Destination $backupPath -Force

        # -- 2) Edition chirurgicale cle par cle --
        $newText = $text

        # Deduplication defensive : si une cle email apparait plusieurs fois (par
        # exemple a cause d'un ancien bug qui ajoutait au lieu de remplacer), on
        # ne garde que la PREMIERE occurrence et on retire les suivantes. Cela
        # repare un fichier deja corrompu et evite l'erreur "Duplicate keys" au
        # chargement du psd1.
        foreach ($key in $script:EmailKeys.Keys) {
            $linePat = "(?m)^[ \t]*$([regex]::Escape($key))[ \t]*=[ \t]*(?:'([^']|'')*'|`"[^`"]*`"|\`$true|\`$false|\d+)[ \t]*(?:#[^\r\n]*)?\r?\n?"
            $matches = [regex]::Matches($newText, $linePat)
            if ($matches.Count -gt 1) {
                # Retirer de la fin vers le debut pour ne pas decaler les index,
                # en conservant la 1ere occurrence (index 0).
                for ($mi = $matches.Count - 1; $mi -ge 1; $mi--) {
                    $mm = $matches[$mi]
                    $newText = $newText.Remove($mm.Index, $mm.Length)
                }
            }
        }

        foreach ($key in $script:EmailKeys.Keys) {
            if (-not $Values.ContainsKey($key)) { continue }

            # Cas special : mot de passe masque non modifie -> ne pas reecrire.
            if ($key -eq 'SMTP_PASSWORD' -and "$($Values[$key])" -eq '********') { continue }

            $type = $script:EmailKeys[$key]
            $literal = Format-PsValue -Type $type -Value $Values[$key]

            # Regex : capture "    <key>   = <valeur>" en preservant tout ce qui
            # suit (commentaire eventuel). Le \r? optionnel avant la fin de ligne
            # rend la detection tolerante aux fichiers en CRLF (sinon la cle
            # n'etait pas retrouvee et etait ajoutee en double a chaque save).
            $pattern = "(?m)^(?<pre>[ \t]*$([regex]::Escape($key))[ \t]*=[ \t]*)(?<val>('([^']|'')*'|`"[^`"]*`"|\`$true|\`$false|\d+))(?<post>[ \t]*(#[^\r\n]*)?)\r?$"

            if ([regex]::IsMatch($newText, $pattern)) {
                $newText = [regex]::Replace($newText, $pattern, {
                    param($m)
                    "$($m.Groups['pre'].Value)$literal$($m.Groups['post'].Value)"
                })
            }
            else {
                # Cle absente : l'ajouter juste avant l'accolade fermante finale,
                # en respectant le style de fin de ligne du fichier.
                $insertion = "    $key = $literal$nl"
                $lastBrace = $newText.LastIndexOf('}')
                if ($lastBrace -ge 0) {
                    $newText = $newText.Substring(0, $lastBrace) + $insertion + $newText.Substring($lastBrace)
                }
            }
        }

        # -- 3) Ecriture temporaire + validation --
        $tmp = [System.IO.Path]::GetTempFileName()
        $enc = New-Object System.Text.UTF8Encoding($true)   # BOM
        [System.IO.File]::WriteAllText($tmp, $newText, $enc)

        $valid = $false
        try { $null = Import-PowerShellDataFile $tmp; $valid = $true } catch { $valid = $false; $parseErr = $_.ToString() }

        if (-not $valid) {
            Remove-Item $tmp -Force -EA SilentlyContinue
            return [PSCustomObject]@{ success = $false; error = "Generated config is invalid, original kept. $parseErr"; backup = $backupName }
        }

        # -- 4) Swap : remplacer l'original par le fichier valide --
        Copy-Item -Path $tmp -Destination $ConfigPath -Force
        Remove-Item $tmp -Force -EA SilentlyContinue

        return [PSCustomObject]@{ success = $true; backup = $backupName }
    }
    catch {
        return [PSCustomObject]@{ success = $false; error = $_.ToString() }
    }
}

Export-ModuleMember -Function @('Set-EmailConfig')
