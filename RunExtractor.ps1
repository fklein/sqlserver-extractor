<#
.SYNOPSIS
    F¨¹hre eine Reihe von definierten Import- und Export-Tasks durch.

.DESCRIPTION
    Der Extraktor liest in einer Konfigurationsdatei definierte Import- und Export-Tasks aus und
    f¨¹hrt diese gegen eine Datenbank aus. Der Ablauf kann über Script-Tasks frei erweitert werden.
    Dabei werden immer nur die zu den angegebenen Actions gehörenden Tasks ausgeführt.
    Die angegebenen Ein- und Ausgabedateien werden automatisch als Zip-Archiv gesichert.

.PARAMETER Action
    Die "Actions" die der Extraktor durchführen soll. Es werden nur die Tasks ausgeführt und die
    Einstellungen verwendet, die einer der angegeben Actions zugeordnet sind. Tasks und Einstellung
    die *keiner* Action zugeordnet sind gelten als universell und werden unabhängig von den
    gewählten Actions *immer* ausgeführt bzw. verwendet.

    Wird keine Action explizit angegeben, wird der Standardwert "Default" verwendet.

.PARAMETER ConfigFile
    Die Konfigurationsdatei mit den Task-Definitionen und Datenbankeinstellungen.
    Per Default wird die Datei "config.xml" im Script-Verzeichnis verwendet.

.PARAMETER CustomValues
    Ein Dictionary/Hash mit beliebigen Werten. Diese werden global im Kontext des Extraktors
    verfügbar gemacht und können so in der Konfiguration (z.B. in Script-Tasks oder per Expansion)
    referenziert werden.

.EXAMPLE
    C:\PS> RunExtractor.ps1 -Config D:\test\testconfig.xml -CustomValues @{"Date" = "20151016; "Suffix" = "csv"; "size" = 4711}

.EXAMPLE
    C:\PS> RunExtractor.ps1 -Action Initial -Verbose

.NOTES
    Author: Florian Klein
#>
[CmdletBinding()]
Param(
    [string[]]$Action = @("Default"),
    [string]$ConfigFile,
    [hashtable]$CustomValues
)

# Bei Fehlern standardmäßig beenden.
$ErrorActionPreference = "Stop"

# Die frei übergebenen Werte global Verfügbar machen.
# Diese sind dann auch in der Konfiguration (Script-Task) nutzbar.
Set-Variable -Name CustomValues -Value $CustomValues -Scope Global

# Das Verzeichnis dieses Scripts bestimmen (nur nötig für PowerShell v2)
$PSScriptRoot = Split-Path -Parent -Path $MyInvocation.MyCommand.Definition
if (!$PSScriptRoot) {
    $PSScriptRoot = Get-Location
}

# Das Extraktor-Modul und das Utility-Modul aus dem Scriptverzeichnis laden.
Import-Module -DisableNameChecking $PSScriptRoot\SQLServerExtractor.psm1
Import-Module -DisableNameChecking $PSScriptRoot\Utilities.psm1

# Falls keine Konfigurationsdatei angegeben ist, den Default nutzen.
if (!$ConfigFile) {
    $ConfigFile = $PSScriptRoot + "\config.xml"
}

# Den Extraktor aufrufen.
Invoke-Extractor -ConfigFile $ConfigFile -Action $Action -Secure -Verbose:($PSBoundParameters['Verbose'] -eq $True) -ErrorAction Stop

# Das Installationsverzeichnis des Extraktors ermitteln und ggf. dahin wechseln.
[xml]$config = Get-Content $ConfigFile
if ($config.Settings.BaseDirectory) {
    $BaseDirectory = $config.Settings.BaseDirectory
    if ((-not (Split-Path -IsAbsolute $BaseDirectory)) -and (Split-Path -Parent $ConfigFile)) {
        $BaseDirectory = Join-Path (Split-Path -Parent $ConfigFile) $BaseDirectory
    }
    Set-Location $BaseDirectory
}

# Eingabe und Ausgabedateien sichern.
$archiveDir = "archive"
Assert-Directory $archiveDir

if ($config.Settings.Tasks.Import) {
    $zipName = ("{0}\inputfiles_{1}.zip" -f $archiveDir, $(Get-Date -f yyyyMMdd-HHmmss))
    Write-Host ("Archiving all input files to {0}" -f $zipName)
    foreach ($import in $config.Settings.Tasks.Import) {
        $import.ChildNodes | ForEach-Object {
            if ($_.LocalName -eq "SourceFile") {
                $Filename = $_.'#text'
                if ($_.Expand -eq "True") {
                    $Filename = $ExecutionContext.InvokeCommand.ExpandString($_.'#text')
                }
                if (Test-Path $Filename) {
                    Write-Verbose ("Adding {0} to archive" -f $Filename)
                    Compress-ZipFile -Path $Filename -DestinationPath $zipName -Update
                }
            }
        }
    }
}

if ($config.Settings.Tasks.Export) {
    $zipName = ("{0}\outputfiles_{1}.zip" -f $archiveDir, $(Get-Date -f yyyyMMdd-HHmmss))
    Write-Host ("Archiving all output files to {0}" -f $zipName)
    foreach ($export in $config.Settings.Tasks.Export) {
        $export.ChildNodes | ForEach-Object {
            if ($_.LocalName -eq "TargetFile") {
                $Filename = $_.'#text'
                if ($_.Expand -eq "True") {
                    $Filename = $ExecutionContext.InvokeCommand.ExpandString($_.'#text')
                }
                if (Test-Path $Filename) {
                    Write-Verbose ("Adding {0} to archive" -f $Filename)
                    Compress-ZipFile -Path $Filename -DestinationPath $zipName -Update
                }
            }
        }
    }
}

# Im Archiv aufräumen. Alles älter als 33 Tage entfernen.
Remove-OldFiles -Limit 33 -Path $archiveDir
