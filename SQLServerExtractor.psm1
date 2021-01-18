# Wenn mindestens Microsoft SQL Server 2012 installiert ist, das Powershell-Modul laden.
# Für ältere Versionen steht nur ein Snapin zur Verfügung, dass dann versucht wird zu laden.
Push-Location
if (Get-Module -ListAvailable -Name sqlps) {
    Import-Module sqlps -DisableNameChecking
} else {
    Remove-PSSnapin SqlServerProviderSnapin100 -ErrorAction SilentlyContinue
    if (!(Get-PSSnapin | ?{$_.Name -eq 'SqlServerProviderSnapin100'})) {
        if (Get-PSSnapin -Registered | ?{$_.Name -eq 'SqlServerProviderSnapin100'}) {
            Add-PSSnapin SqlServerProviderSnapin100
        } else {
            throw "SqlServerProviderSnapin100 is not registered with the system."
        }
    }
    Remove-PSSnapin SqlServerCmdletSnapin100 -ErrorAction SilentlyContinue
    if (!(Get-PSSnapin | ?{$_.Name -eq 'SqlServerCmdletSnapin100'})) {
        if (Get-PSSnapin -Registered | ?{$_.Name -eq 'SqlServerCmdletSnapin100'}) {
            Add-PSSnapin SqlServerCmdletSnapin100
        } else {
            throw "SqlServerCmdletSnapin100 is not registered with the system."
        }
    }
}
Pop-Location

function MeasureDuration() {
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

# Aus diversen statischen Informationen des Computers einen eindeutigen Fingerabdruck erzeugen.
function GetMachineFingerprint() {
    [CmdletBinding()]

    $machineguid = (Get-Item HKLM:\SOFTWARE\Microsoft\Cryptography | Get-ItemProperty).MachineGuid
    $hostname = [System.Net.Dns]::GetHostByName(($env:computerName)).HostName
    $fingerprint = "{0}_{1}" -f $hostname, $machineguid
    $hashprovider = New-Object -TypeName System.Security.Cryptography.SHA256CryptoServiceProvider
    $encoding = New-Object -TypeName System.Text.UTF8Encoding
    return $hashprovider.ComputeHash($encoding.GetBytes($fingerprint.ToLower()))
}


<#
.SYNOPSIS
    Importiere Daten aus einer Datei in eine Datenbanktabelle.

.DESCRIPTION
    Importiert Daten aus einer Quelldatei in eine Zieltabelle in eine SQL Server Datenbank.
    Vor und nach dem Import können dabei beliebige SQL-Statements oder -Scripte ausgeführt werden.
    Der Import wird über das externe BCP-Utility durchgeführt.

.PARAMETER SourceFile
    Die Quelldatei aus der die Daten gelesen werden.

.PARAMETER TargetTable
    Die Zieltabelle für den Datenimport.

.PARAMETER Format
    Eine BCP-Formatdatei für Quelldatei.
    Wenn angegeben, werden die Parameter -RecordSeparator und -FieldSeparator nicht beachtet.

.PARAMETER RecordSeparator
    Das in der Quelldatei verwendete Zeilentrennzeichen (Default ist "\n").
    Wird nur genutzt wenn keine Formatdatei spezifiziert ist.

.PARAMETER FieldSeparator
    Das in der Quelldatei verwendete Feldtrennzeichen (Default ist ";").
    Wird nur genutzt wenn keine Formatdatei spezifiziert ist.

.PARAMETER CodePage
    Der in der Importdatei verwendete Zeichensatz (Default ist "Windows-1252").
    Wird nur genutzt wenn keine Formatdatei spezifiziert ist.

.PARAMETER Initialize
    Eine Folge von SQL-Statements oder -Scripten, die vor dem Datenimport ausgeführt werden.
    Dateien müssen dabei mit Prefix "@" kenntlich gemacht werden.

.PARAMETER Finalize
    Eine Folge von SQL-Statements oder -Scripten, die nach dem Datenimport ausgeführt werden.
    Dateien müssen dabei mit Prefix "@" kenntlich gemacht werden.

.PARAMETER Database
    Die Datenbank gegen die alle Aktionen ausgeführt werden.

.PARAMETER ServerInstance
    Die SQL Server Instanz gegen die der Import ausgeführt werden soll.

.PARAMETER Timeout
    Timeout in Sekunden für das Ausführen von SQL-Statements oder -Scripten.

.PARAMETER Credential
    Ein PSCredential mit den Zugangsdaten für den SQL Server.

.PARAMETER User
    Der User für den Zugriff auf den SQL Server.

.PARAMETER Password
    Das Passwort für den angegebenen User als String.

.PARAMETER SecurePassword
    Das Passwort für den angegebenen User als SecureString.

.EXAMPLE
    C:\PS> Invoke-DatabaseImport -SourceFile C:\mydata.dsv -TargetTable mydb..Imported -FieldSeparator "|"

.EXAMPLE
    C:\PS> Invoke-DatabaseImport -SourceFile C:\import.dat -TargetTable Imported -Format C:\temp\mydata.fmt -Database mydb -Initialize "DELETE FROM Imported"

.EXAMPLE
    C:\PS> Invoke-DatabaseImport -SourceFile C:\import.csv -TargetTable mydb..Imported -Finalize "@C:\FancyStuff.sql","INSERT INTO Log (message, ts) VALUES ('Import finished', getdate())" -Server my.server.org\MYDB -User scott -Password Tiger123

.NOTES
    Author: Florian Klein
#>
function Invoke-DatabaseImport() {
    [CmdletBinding()]
    Param(
        [Parameter(Mandatory=$True)]
        [ValidateScript({Test-Path $_ -PathType Leaf})]
        [string]$SourceFile,

        [Parameter(Mandatory=$True)]
        [string]$TargetTable,

        [ValidateScript({Test-Path $_ -PathType Leaf})]
        [string]$Format,
        [string]$RecordSeparator = "\n",
        [string]$FieldSeparator = ";",
        [string]$CodePage = "ACP",

        [string[]]$Initialize,
        [string[]]$Finalize,

        [string]$Database,
        [string]$ServerInstance,
        [int]$Timeout,

        [PSCredential]$Credential,
        [string]$User,
        [string]$Password,
        [SecureString]$SecurePassword
    )

    # Workaround für relative Pfadangaben. Das Commandlet Invoke-Sqlcmd nutzt das Arbeitsverzeichnis
    # aus dem Environment, statt die Powershell "Location".
    # Siehe http://stackoverflow.com/questions/12604902/how-to-convert-this-sqlcmd-script-to-an-invoke-sqlcmd-script
    $restoreDirectory = [Environment]::CurrentDirectory
    [Environment]::CurrentDirectory = Get-Location

    $dbParams = @{}
    $bcpParams = @()

    if ($Format) {
        $bcpParams += @("-f", $Format)
    } else {
        $bcpParams += @(
            "-c",
            "-C", $CodePage,
            "-r", $RecordSeparator,
            "-t", $FieldSeparator
        )
    }
    if ($Database) {
        $dbParams.Add("Database", $Database)
        $bcpParams += @("-d", $Database)
    }
    if ($ServerInstance) {
        $dbParams.Add("ServerInstance", $ServerInstance)
        $bcpParams += @("-S", $ServerInstance)
    }
    if ($Timeout) {
        $dbParams.Add("QueryTimeout", $Timeout)
    }

    if ($Credential) {
        $dbParams.Add("Username", $Credential.GetNetworkCredential().Username)
        $dbParams.Add("Password", $Credential.GetNetworkCredential().Password)
        $bcpParams += @("-U", $Credential.GetNetworkCredential().Username)
        $bcpParams += @("-P", $Credential.GetNetworkCredential().Password)
    } else {
        if ($User) {
            $dbParams.Add("Username", $User)
            $bcpParams += @("-U", $User)
        }
        if ($SecurePassword) {
            $Credential = New-Object -TypeName System.Management.Automation.PSCredential -ArgumentList $User, $SecurePassword
            $DecryptedPassword = $Credential.GetNetworkCredential().Password
            $dbParams.Add("Password", $DecryptedPassword)
            $bcpParams += @("-P", $DecryptedPassword)
        } elseif ($Password) {
            $dbParams.Add("Password", $Password)
            $bcpParams += @("-P", $Password)
        } else {
            $bcpParams += @("-T")
        }
    }

    if ($Initialize.Count -gt 0) {
        Write-Verbose "Initializing ..."
        foreach ($init in $Initialize) {
            $startTime = Get-Date
            if ($init.TrimStart().StartsWith("@")) {
                $initFile = $init.Trim("@ ")
                Write-Verbose ("Executing file {0}" -f $initFile)
                Invoke-Sqlcmd @dbParams -InputFile $initFile
            } else {
                Write-Verbose ("Executing statement `"{0}`"" -f $init)
                Invoke-Sqlcmd @dbParams -Query $init
            }
            Write-Verbose ("Operation took {0}" -f $(MeasureDuration $startTime))
        }
    }

    Write-Verbose "Importing ..."
    Write-Verbose ("Source file is {0}" -f $SourceFile)
    $startTime = Get-Date
    & bcp $TargetTable in $SourceFile $bcpParams |
            Where-Object {$_ -and $_ -notmatch "[0-9]* rows sent to SQL Server\."} |
            Write-Verbose
    if ($LastExitCode -ne 0) {
        Write-Error ("Execution of the bcp utility failed. The return code was {0}." -f $LastExitCode)
    }
    Write-Verbose ("Operation took {0}" -f $(MeasureDuration $startTime))

    if ($Finalize.Count -gt 0) {
        Write-Verbose "Finalizing ..."
        foreach ($final in $Finalize) {
            $startTime = Get-Date
            if ($final.TrimStart().StartsWith("@")) {
                $finalFile = $final.Trim("@ ")
                Write-Verbose ("Executing file {0}" -f $finalFile)
                Invoke-Sqlcmd @dbParams -InputFile $finalFile
            } else {
                Write-Verbose ("Executing statement `"{0}`"" -f $final)
                Invoke-Sqlcmd @dbParams -Query $final
            }
            Write-Verbose ("Operation took {0}" -f $(MeasureDuration $startTime))
        }
    }

    # Workaround für relative Pfadangaben zurücksetzen.
    [Environment]::CurrentDirectory = $restoreDirectory
}


<#
.SYNOPSIS
    Exportiere Daten aus einer Datenbank-Tabelle -View oder -Query in eine Datei.

.DESCRIPTION
    Exportiert Daten aus einer Tabelle, View oder Query in einer SQL Server Datenbank in eine Datei.
    Vor und nach dem Export können dabei beliebige SQL-Statements oder -Scripte ausgeführt werden.
    Der Export wird über das externe BCP-Utility durchgeführt.

.PARAMETER SourceTable
    Die Tabelle oder View die exportiert wird.

.PARAMETER SourceQuery
    Die Query deren Ergebnis exportiert wird.

.PARAMETER TargetFile
    Die Ausgabedatei für den Datenexport.

.PARAMETER Format
    Eine BCP-Formatdatei für Zieldatei.
    Wenn angegeben, werden die Parameter -RecordSeparator und -FieldSeparator nicht beachtet.

.PARAMETER RecordSeparator
    Das für die Zieldatei verwendete Zeilentrennzeichen (Default ist "\n").
    Wird nur genutzt wenn keine Formatdatei spezifiziert ist.

.PARAMETER FieldSeparator
    Das für die Zieldatei verwendete Feldtrennzeichen (Default ist ";").
    Wird nur genutzt wenn keine Formatdatei spezifiziert ist.

.PARAMETER CodePage
    Der für die Exportdatei verwendete Zeichensatz (Default ist "Windows-1252").
    Wird nur genutzt wenn keine Formatdatei spezifiziert ist.

.PARAMETER Initialize
    Eine Folge von SQL-Statements oder -Scripten, die vor dem Datenexport ausgeführt werden.
    Dateien müssen dabei mit Prefix "@" kenntlich gemacht werden.

.PARAMETER Finalize
    Eine Folge von SQL-Statements oder -Scripten, die nach dem Datenexport ausgeführt werden.
    Dateien müssen dabei mit Prefix "@" kenntlich gemacht werden.

.PARAMETER Database
    Die Datenbank gegen die alle Aktionen ausgeführt werden.

.PARAMETER ServerInstance
    Die SQL Server Instanz gegen die der Export ausgeführt werden soll.

.PARAMETER Timeout
    Timeout in Sekunden für das Ausführen von SQL-Statements oder -Scripten.

.PARAMETER Credential
    Ein PSCredential mit den Zugangsdaten für den SQL Server.

.PARAMETER User
    Der User für den Zugriff auf den SQL Server.

.PARAMETER Password
    Das Passwort für den angegebenen User als String.

.PARAMETER SecurePassword
    Das Passwort für den angegebenen User als SecureString.

.EXAMPLE
    C:\PS> Invoke-DatabaseImport -SourceFile C:\mydata.dsv -TargetTable mydb..Imported -FieldSeparator "|"

.EXAMPLE
    C:\PS> Invoke-DatabaseImport -SourceFile C:\import.dat -TargetTable Imported -Format C:\temp\mydata.fmt -Database mydb -Initialize "DELETE FROM Imported"

.EXAMPLE
    C:\PS> Invoke-DatabaseImport -SourceFile C:\import.csv -TargetTable mydb..Imported -Finalize "@C:\FancyStuff.sql","INSERT INTO Log (message, ts) VALUES ('Import finished', getdate())" -Server my.server.org\MYDB -User scott -Password Tiger123

.NOTES
#>
function Invoke-DatabaseExport() {
    [CmdletBinding()]
    Param(
        [Parameter(Mandatory=$True, ParameterSetName='Table')]
        [string]$SourceTable,

        [Parameter(Mandatory=$True, ParameterSetName='Query')]
        [string]$SourceQuery,

        [Parameter(Mandatory=$True)]
        [string]$TargetFile,

        [ValidateScript({Test-Path $_ -PathType Leaf})]
        [string]$Format,
        [string]$RecordSeparator = "\n",
        [string]$FieldSeparator = ";",
        [string]$CodePage = "ACP",

        [string[]]$Initialize,
        [string[]]$Finalize,

        [string]$Database,
        [string]$ServerInstance,
        [int]$Timeout,

        [PSCredential]$Credential,
        [string]$User,
        [string]$Password,
        [SecureString]$SecurePassword
    )

    # Workaround für relative Pfadangaben. Das Commandlet Invoke-Sqlcmd nutzt das Arbeitsverzeichnis
    # aus dem Environment, statt die Powershell "Location".
    # Siehe http://stackoverflow.com/questions/12604902/how-to-convert-this-sqlcmd-script-to-an-invoke-sqlcmd-script
    $restoreDirectory = [Environment]::CurrentDirectory
    [Environment]::CurrentDirectory = Get-Location

    $dbParams = @{}
    $bcpParams = @()

    if ($Format) {
        $bcpParams += @("-f", $Format)
    } else {
        $bcpParams += @(
            "-c",
            "-C", $CodePage,
            "-r", $RecordSeparator,
            "-t", $FieldSeparator
        )
    }
    if ($Database) {
        $dbParams.Add("Database", $Database)
        $bcpParams += @("-d", $Database)
    }
    if ($ServerInstance) {
        $dbParams.Add("ServerInstance", $ServerInstance)
        $bcpParams += @("-S", $ServerInstance)
    }
    if ($Timeout) {
        $dbParams.Add("QueryTimeout", $Timeout)
    }

    if ($Credential) {
        $dbParams.Add("Username", $Credential.GetNetworkCredential().Username)
        $dbParams.Add("Password", $Credential.GetNetworkCredential().Password)
        $bcpParams += @("-U", $Credential.GetNetworkCredential().Username)
        $bcpParams += @("-P", $Credential.GetNetworkCredential().Password)
    } else {
        if ($User) {
            $dbParams.Add("Username", $User)
            $bcpParams += @("-U", $User)
        }
        if ($SecurePassword) {
            $Credential = New-Object -TypeName System.Management.Automation.PSCredential -ArgumentList $User, $SecurePassword
            $DecryptedPassword = $Credential.GetNetworkCredential().Password
            $dbParams.Add("Password", $DecryptedPassword)
            $bcpParams += @("-P", $DecryptedPassword)
        } elseif ($Password) {
            $dbParams.Add("Password", $Password)
            $bcpParams += @("-P", $Password)
        } else {
            $bcpParams += @("-T")
        }
    }

    if ($Initialize.Count -gt 0) {
        Write-Verbose "Initializing ..."
        foreach ($init in $Initialize) {
            $startTime = Get-Date
            if ($init.TrimStart().StartsWith("@")) {
                $initFile = $init.Trim("@ ")
                Write-Verbose ("Executing file {0}" -f $initFile)
                Invoke-Sqlcmd @dbParams -InputFile $initFile
            } else {
                Write-Verbose ("Executing statement `"{0}`"" -f $init)
                Invoke-Sqlcmd @dbParams -Query $init
            }
            Write-Verbose ("Operation took {0}" -f $(MeasureDuration $startTime))
        }
    }

    Write-Verbose "Exporting ..."
    Write-Verbose ("Target file is {0}" -f $TargetFile)
    $startTime = Get-Date
    New-Item -ItemType File -Force -Path $TargetFile | Out-Null
    if ($SourceQuery) {
        & bcp $SourceQuery queryout $TargetFile $bcpParams |
            Where-Object {$_ -and $_ -notmatch "[0-9]* rows successfully bulk-copied to host-file\."} |
            Write-Verbose
    } else {
        & bcp $SourceTable out $TargetFile $bcpParams |
            Where-Object {$_ -and $_ -notmatch "[0-9]* rows successfully bulk-copied to host-file\."} |
            Write-Verbose
    }
    if ($LastExitCode -ne 0) {
        Write-Error ("Execution of the bcp utility failed. The return code was {0}." -f $LastExitCode)
    }
    Write-Verbose ("Operation took {0}" -f $(MeasureDuration $startTime))

    if ($Finalize.Count -gt 0) {
        Write-Verbose "Finalizing ..."
        foreach ($final in $Finalize) {
            $startTime = Get-Date
            if ($final.TrimStart().StartsWith("@")) {
                $finalFile = $final.Trim("@ ")
                Write-Verbose ("Executing file {0}" -f $finalFile)
                Invoke-Sqlcmd @dbParams -InputFile $finalFile
            } else {
                Write-Verbose ("Executing statement `"{0}`"" -f $final)
                Invoke-Sqlcmd @dbParams -Query $final
            }
            Write-Verbose ("Operation took {0}" -f $(MeasureDuration $startTime))
        }
    }

    # Workaround für relative Pfadangaben zurücksetzen.
    [Environment]::CurrentDirectory = $restoreDirectory
}


<#
.SYNOPSIS
    Führe eine Reihe von definierten Import- und Export-Tasks durch.

.DESCRIPTION
    Der Extraktor liest in einer Konfigurationsdatei definierte Import- und Export-Tasks aus und
    führt diese gegen eine Datenbank aus. Der Ablauf kann über Script-Tasks frei erweitert werden.
    Dabei werden immer nur die zu den angegebenen Actions gehörenden Tasks ausgeführt.

.PARAMETER ConfigFile
    Die Konfigurationsdatei mit den Task-Definitionen und Datenbankeinstellungen.

.PARAMETER Action
    Die "Actions" die der Extraktor durchführen soll. Es werden nur die Tasks ausgeführt und die
    Einstellungen verwendet, die einer der angegeben Actions zugeordnet sind. Tasks und Einstellung
    die *keiner* Action zugeordnet sind gelten als universell und werden unabhängig von den
    gewählten Actions *immer* ausgeführt bzw. verwendet.

    Wird keine Action explizit angegeben, wird der Standardwert "Default" verwendet.

.PARAMETER Secure
    Unverschlüsselte Passwörter in der Konfigurationsdatei werden mit einem machinenspezifischen
    Schlüssel verschlüsselt und ersetzt.

.EXAMPLE
    C:\PS> Invoke-Extractor -Action Export,Initial -ConfigFile config.xml -Secure

.NOTES
    Author: Florian Klein
#>
function Invoke-Extractor() {
    [CmdletBinding()]
    Param(
        [Parameter(Mandatory=$True)]
        [ValidateScript({Test-Path $_ -PathType Leaf})]
        [string]$ConfigFile,

        [string[]]$Action = @("Default"),

        [switch]$Secure = $False
    )

    $restoreLocation = Get-Location
    $extractorStart = Get-Date
    Write-Verbose ("Current location is {0}" -f (Get-Location))

    # Die Konfigurationsdatei lesen.
    Write-Verbose ("Reading configuration file {0}" -f $ConfigFile)
    [xml]$config = Get-Content $ConfigFile

    # Falls gewünscht ein ggf. vorhandenes unverschlüsselte Datenbank-Passwort durch eine
    # verschlüsselte Version ersetzen und die Konfiguration abspeichern.
    if ($Secure.IsPresent -and $config.Settings.Database.Password) {
        Write-Verbose ("Encoding plain text password ...")
        $passwordNode = $config.Settings.Database.Item("Password")
        $password = ConvertTo-SecureString -Force -AsPlainText $passwordNode.'#text'
        $encryptedPassword = ConvertFrom-SecureString -Key (GetMachineFingerprint) $password
        $securePasswordNode = $config.CreateElement("SecurePassword")
        $securePasswordNode.AppendChild($config.CreateTextNode($encryptedPassword)) | Out-Null
        $config.Settings.Database.ReplaceChild($securePasswordNode, $passwordNode) | Out-Null
        $config.Save($ConfigFile)
    }

    # Falls in der Konfiguration ein Basisverzeichnis angegeben ist, dorthin wechseln.
    # Relative Pfadangaben werden dabei auf die Location der Konfigurationsdatei bezogen.
    if ($config.Settings.BaseDirectory) {
        $BaseDirectory = $config.Settings.BaseDirectory
        if ((-not (Split-Path -IsAbsolute $BaseDirectory)) -and (Split-Path -Parent $ConfigFile)) {
            $BaseDirectory = Join-Path (Split-Path -Parent $ConfigFile) $BaseDirectory
        }
        $BaseDirectory = (Get-Item $BaseDirectory).FullName
        Write-Verbose ("Changing location to {0}" -f $BaseDirectory)
        Set-Location $BaseDirectory
    }

    # Die allgemeinen Datenbank-Einstellungen aus der Konfiguration auslesen.
    # Jedes XML-Element unterhalb vom "/Settings/Database" wird einfach direkt mit Name und Inhalt
    # als Parameter für den Aufruf der Export/Import-Funktionen (siehe oben) übernommen.
    $dbSettings = @{}
    $config.Settings.Database.ChildNodes | Where-Object {$_} | ForEach-Object {
        if ($_.LocalName.StartsWith("#")) { return }
        # Den Inhalt des Elements auslesen, ggf. "expanden" und in den richtigen Datentyp konvertieren.
        $nodeContent = $_.'#text'
        if ($_.Expand -eq "True") {
            $nodeContent = $ExecutionContext.InvokeCommand.ExpandString($_.'#text')
        }
        if ($_.LocalName -eq "SecurePassword") {
            $nodeContent = ConvertTo-SecureString -Key (GetMachineFingerprint) $nodeContent
        }
        $dbSettings[$_.LocalName] = $nodeContent
    }

    # Die in der Konfiguration angegebenen Tasks ausführen.
    # Alle Element unterhalb vom "/Settings/Tasks" wird hierfür nacheinander abgearbeitet.
    foreach ($task in $config.Settings.Tasks.ChildNodes) {
        # Kommentare etc. überspringen.
        if ($task.LocalName.StartsWith("#")) { continue }

        $taskStart = Get-Date
        Write-Host -Separator "" "Processing " $task.LocalName.ToLower() " task `"" $task.Name "`""

        # Die Task überspringen, falls diese nicht für die aktuellen Actions zugelassen ist.
        if ($task.Actions -and !($task.Actions.Split(", ") | Where-Object {$Action -contains $_})) {
            Write-Verbose ("Task is not applicable for actions {0}" -f ($Action -join ", "))
            Write-Host "Skipping task"
            Write-Host ""
            continue
        }

        # Bei Script-Tasks einfach den Inhalt als Script ausführen.
        if ($task.LocalName -eq "Script")  {
            [scriptblock]$script = [scriptblock]::Create($task.'#text')
            Invoke-Command -ScriptBlock $script
        }

        # Bei Import- und Export-Tasks die untergeordneten Elemente als Parameter interpretieren.
        if ($task.LocalName -eq "Import" -or $task.LocalName -eq "Export") {
            # Die Einstellungen für die Task ermitteln.
            # Jedes XML-Element das unterhalb der Task definiert ist wird einfach direkt mit Name und
            # Inhalt als Parameter für den Aufruf der Export/Import-Funktionen (siehe oben) übernommen.
            $taskSettings = @{}
            $task.ChildNodes | Where-Object {$_} | ForEach-Object {
                # Kommentare etc. überspringen.
                if ($_.LocalName.StartsWith("#")) { return }

                # Die Einstellung überspringen, falls diese nicht für die aktuellen Actions zugelassen ist.
                if ($_.Actions -and !($_.Actions.Split(", ") | Where-Object {$Action -contains $_})) {
                    return
                }

                # Den Inhalt des Elements auslesen und ggf. "expanden".
                $nodeContent = $_.'#text'
                if ($_.Expand -eq "True") {
                    $nodeContent = $ExecutionContext.InvokeCommand.ExpandString($_.'#text')
                }
                # Elemente "Initialize" und "Finalize" können beliebig oft vorkommen und müssen
                # als Array-Parameter übergeben werden. Daher alle Einträge in einem Array sammeln.
                if ($_.LocalName -eq "Initialize" -or $_.LocalName -eq "Finalize") {
                    if ($taskSettings[$_.LocalName]) {
                        $taskSettings[$_.LocalName] += @($nodeContent)
                    } else {
                        $taskSettings[$_.LocalName] = @($nodeContent)
                    }
                } else {
                    # Die restlichen "normalen" Elemente einfach direkt als Parameter übernehmen.
                    $taskSettings[$_.LocalName] = $nodeContent
                }
            }

            # Die Task mit den ermittelten Einstellungen/Parametern ausführen.
            if ($task.LocalName -eq "Import") {
                Invoke-DatabaseImport @dbSettings @taskSettings
            }
            if ($task.LocalName -eq "Export")  {
                Invoke-DatabaseExport @dbSettings @taskSettings
            }
        }

        Write-Host ("Task finished in {0}" -f $(MeasureDuration $taskStart))
        Write-Host ""
    }

    Write-Host ("Extraction finished in {0}" -f $(MeasureDuration $extractorStart))
    Set-Location $restoreLocation
}

Export-ModuleMember *-*
