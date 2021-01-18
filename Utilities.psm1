<#
.SYNOPSIS
    Lege ein Verzeichnis an, falls es nicht schon existiert.

.DESCRIPTION
    Prüft ob das angegebene Verzeichnis existiert und legt es an falls nicht.

.PARAMETER Path
    Der Pfad des Verzeichnisses.
#>
function Assert-Directory() {
    [CmdletBinding()]
    Param(
        [Parameter(Mandatory=$True, Position=1)]
        [string]$Path
    )

    if (!(Test-Path -PathType Container $Path)) {
        New-Item -ItemType Directory -Force -Path $Path | Out-Null
    }
}

<#
.SYNOPSIS
    Lege eine Datei an, falls diese nicht schon existiert.

.DESCRIPTION
    Prüft ob die angegebene Datei existiert und legt diese leer an falls nicht.

.PARAMETER Path
    Der Pfad der Datei.
#>
function Assert-File() {
    [CmdletBinding()]
    Param(
        [Parameter(Mandatory=$True, Position=1)]
        [string]$Path
    )

    if (!(Test-Path -PathType Leaf $Path)) {
        New-Item -ItemType File -Force -Path $Path | Out-Null
    }
}

<#
.SYNOPSIS
    Prüfe ob eine Datei gesperrt ist.

.DESCRIPTION
    Prüft ob die angegebene Datei gesperrt ist.

.PARAMETER Path
    Der Pfad der Datei.
#>
function Test-FileLock() {
    [CmdletBinding()]
    Param(
        [Parameter(Mandatory=$True, Position=1)]
        [string]$Path
    )

    $isFileLocked = $True
    $File = $null
    try {
        $File = [IO.File]::Open(
            $(Get-Item $Path).FullName,
            [IO.FileMode]::Open,
            [IO.FileAccess]::Read,
            [IO.FileShare]::None)
        $isFileLocked = $false
    } catch [IO.IOException] {
        if (!($_.Exception.Message.EndsWith("it is being used by another process.") -or
                $_.Exception.Message.EndsWith("da sie von einem anderen Prozess verwendet wird."))) {
            throw $_.Exception
        }
    } finally {
        if ($File -ne $null) {
            $File.Close()
        }
    }
    return $isFileLocked
}

<#
.SYNOPSIS
    Füge Dateien und Verzeichnisse einem Zip-Archiv hinzu.

.DESCRIPTION
    Fügt einem Zip-Archiv die angegebenen Dateien und Verzeichnisse hinzu. Das Archiv wird neu
    angelegt, falls es nicht bereits existiert.

.PARAMETER Path
    Die Dateien und Verzeichnisse, die in das Zip-Archiv kopiert werden sollen.

.PARAMETER DestinationPath
    Das zu bearbeitende Zip-Archiv.

.PARAMETER Update
    Gibt an ob das Zip-Archiv aktualisiert werden soll.
    Ansonsten wird ein ggf. bereits existierendes Archiv überschrieben.
#>
function Compress-ZipFile() {
    [CmdletBinding()]
    Param(
        [Parameter(Mandatory=$True, Position=1)]
        [string[]]$Path,

        [Parameter(Mandatory=$True, Position=2)]
        [string]$DestinationPath,

        [switch]$Update = $False
    )
    if (!($Update.IsPresent) -or !(Test-Path -PathType Leaf $DestinationPath) ) {
        Set-Content $DestinationPath ("PK" + [char]5 + [char]6 + ("$([char]0)" * 18))
    }
    $shellApp = New-Object -ComObject Shell.Application
    $zipFile = $shellApp.NameSpace($(Get-Item $DestinationPath).FullName)
    $Path | Where-Object {$_} | ForEach-Object {
        Get-Item $_ | ForEach-Object {
            $zipFile.CopyHere($_.FullName, 0x14)
            Start-Sleep 5
            while (Test-FileLock $DestinationPath) {
                Start-Sleep 1
            }
        }
    }
}

<#
.SYNOPSIS
    Lösche alte Dateien unterhalb eines Pfades.

.DESCRIPTION
    Durchsucht einen Pfad nach alten Dateien und löscht diese. Verzeichnisse bleiben erhalten.

.PARAMETER Path
    Der Pfad unterhalb dem gelöscht werden soll.

.PARAMETER Limit
    Das maximale Alter für Dateien in Tagen. Dateien die älter sind werden gelöscht.

.PARAMETER Recurse
    Gibt an ob Unterverzeichnisse ebenfalls verarbeitet werden.
#>
function Remove-OldFiles() {
    [CmdletBinding()]
    Param(
        [Parameter(Mandatory=$True, Position=1)]
        [string[]]$Path,

        [Parameter(Mandatory=$True, Position=2)]
        [int]$Limit,

        [switch]$Recurse
    )
    $MaxDate = $(Get-Date).AddDays($Limit * -1)
    Get-ChildItem -Path $Path -Recurse:($Recurse -eq $True) -Force |
        Where-Object { !$_.PSIsContainer -and $_.CreationTime -lt $MaxDate } |
        Remove-Item -Force
}

<#
.SYNOPSIS
    Ermittle die Dauer zwischen zwei Zeitpunkten.

.DESCRIPTION
    Berechnet die Dauer zwischen zwei Zeitpunkten und gibt diese als String in Tagen, Stunden,
    Minuten, Sekunden und Millisekunden an. Der Startzeitpunkt muss vor dem Endzeitpunkt liegen.

.PARAMETER Start
    Der Startzeitpunkt.

.PARAMETER End
    Der Entzeitpunkt. Als Default wird die aktuelle Systemzeit verwendet.
#>
function Measure-Duration() {
    [CmdletBinding()]
    Param(
        [Parameter(Mandatory=$True, Position=1)]
        [datetime]$Start,

        [Parameter(Position=2)]
        [datetime]$End = $(Get-Date)
    )

    if ($Start -gt $End) {
        Write-Error("Startzeitpunkt darf nicht nach dem Endzeitpunkt oder in der Zukunft liegen.")
        return $Null
    }
    $Duration = $End - $Start
    if ($Duration.TotalDays -ge 1) {
        return ("{0} days, {1} hours, {2} minutes and {3} seconds" -f $Duration.Days, $Duration.Hours, $Duration.Minutes, $Duration.Seconds)
    } elseif ($Duration.TotalHours -ge 1) {
        return ("{0} hours, {1} minutes and {2} seconds" -f $Duration.Hours, $Duration.Minutes, $Duration.Seconds)
    } elseif ($Duration.TotalMinutes -ge 1) {
        return ("{0} minutes and {1} seconds" -f $Duration.Minutes, $Duration.Seconds)
    } elseif ($Duration.TotalSeconds -ge 1) {
        return ("{0} seconds" -f $Duration.Seconds)
    } else {
        return ("{0} milliseconds" -f $Duration.Milliseconds)
    }
}

Export-ModuleMember *-*
