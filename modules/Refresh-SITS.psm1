function Get-LatestLiveBackup {
    param (
        [string]$BackupSource,
        [string]$BackupDestination,
        [string]$LogFile = $null
    )

    $latest = Get-ChildItem -Path $BackupSource | Sort-Object LastWriteTime -Descending | Select-Object -First 1

    # Check if there are files in the source directory
    if (-not $latest) {
        Write-Log "ERROR: No files found in the source directory. Stopping script." $LogFile
        exit 1
    }

    $source = Join-Path $BackupSource $latest.Name
    $destFile = Join-Path $BackupDestination 'SITSRefresh.bak'

    Write-Log "[DEBUG] Source file path: $source" $LogFile
    Write-Log "[DEBUG] Destination file path: $destFile" $LogFile

    if (-not $LogFile) {
        $LogFile = Join-Path $BackupDestination 'ScriptLog.txt'
    }

    # Check if the source and destination files are identical before deleting
    if (Test-Path $destFile) {
        Write-Log "[DEBUG] Checking file age..." $LogFile
        $srcItem = Get-Item $source
        $dstItem = Get-Item $destFile
        if ($srcItem.Length -eq $dstItem.Length -and $srcItem.LastWriteTime -eq $dstItem.LastWriteTime) {
            Write-Log "Backup file $($latest.Name) already exists in destination and is likely identical (size and timestamp match). Skipping hash check and continuing workflow." $LogFile
            Write-Log "Continuing workflow." $LogFile
            return
        }
        Write-Log "[DEBUG] Size or timestamp differ, calculating hashes..." $LogFile
        $srcHash = (Get-FileHash $source).Hash
        Write-Log "[DEBUG] Source hash: $srcHash" $LogFile
        $dstHash = (Get-FileHash $destFile).Hash
        Write-Log "[DEBUG] Destination hash: $dstHash" $LogFile
        if ($srcHash -eq $dstHash) {
            Write-Log "Backup file $($latest.Name) already exists in destination and is identical. Skipping delete, disk space, and file size checks." $LogFile
            Write-Log "Continuing workflow." $LogFile
            return
        } else {
            Write-Log "Proceeding to delete files in destination directory..." $LogFile
        }
    }

    # Delete any existing files in the destination directory
    if (Test-Path $BackupDestination) {
        Remove-Item -Path (Join-Path $BackupDestination '*') -Recurse -Force
        Write-Log "Deleted all files in $BackupDestination" $LogFile
    } else {
        Write-Log "Destination folder $BackupDestination does not exist." $LogFile
    }

    # Check if the file is less than 20 hours old
    if (((Get-Date) - $latest.LastWriteTime).TotalHours -lt 20) {
        # Get the size of the source file
        $fileSize = (Get-Item $source).Length
        # Get the available free space on the destination drive
        $destinationDrive = ([System.IO.DriveInfo]::GetDrives() | Where-Object { $BackupDestination.StartsWith($_.Name) }).Name
        try {
            $freeSpace = (Get-CimInstance -ClassName Win32_LogicalDisk | Where-Object { $_.DeviceID -eq $destinationDrive.TrimEnd('\\') }).FreeSpace
        } catch {
            Write-Log "ERROR: Error retrieving free space for $destinationDrive. Stopping script." $LogFile
            exit 1
        }

        Write-Log "Free space on ${destinationDrive}: $freeSpace bytes" $LogFile
        Write-Log "Size of the source file: $fileSize bytes" $LogFile
        Write-Log ("Source file name: {0}" -f $latest.Name) $LogFile
        Write-Log ("Source file path: {0}" -f $source) $LogFile
        Write-Log ("Last modified date and time of the file: {0:yyyy-MM-dd HH:mm:ss}" -f $latest.LastWriteTime) $LogFile

        if ($freeSpace -gt $fileSize) {
            # Import the BITS module and start the transfer
            Import-Module BitsTransfer
            Start-BitsTransfer -Source $source -Destination $destFile -Description "SITS Latest Live Backup" -DisplayName "SITS Backup"
            Write-Log ("File transfer started successfully. Latest backup file date and time: {0:yyyy-MM-dd HH:mm:ss}" -f $latest.LastWriteTime) $LogFile
        } else {
            Write-Log "ERROR: Not enough space on the destination drive to copy the file. Stopping script." $LogFile
            exit 1
        }
    } else {
        Write-Log ("The latest file is older than 20 hours. No file will be copied. Latest file date and time: {0:yyyy-MM-dd HH:mm:ss}" -f $latest.LastWriteTime) $LogFile
        exit 1
    }
}

function Set-DatabaseFileName {
    <#
    .SYNOPSIS
        Sets the database to single_user with rollback, takes it offline, then renames database files according to a mapping.
    .PARAMETER FileMap
        Hashtable or array of hashtables with keys 'Source' and 'Destination'.
    .PARAMETER DatabaseName
        The name of the database to set offline.
    .PARAMETER SqlInstance
        The SQL Server instance to connect to (default: localhost).
    .PARAMETER LogFile
        Optional path to a log file for status and error messages.
    #>
    param (
        [Parameter(Mandatory)]
        [array]$FileMap,
        [Parameter(Mandatory)]
        [string]$DatabaseName,
        [string]$SqlInstance = 'localhost',
        [string]$LogFile = $null,
        [string]$LogicalRenameScript = $null
    )

    # Drop all connections to the database
    $dropConnQuery = @"
DECLARE @kill varchar(8000) = '';
SELECT @kill = @kill + 'KILL ' + CONVERT(varchar(5), session_id) + ';'
FROM sys.dm_exec_sessions
WHERE database_id = db_id('$DatabaseName') AND session_id <> @@SPID;
EXEC(@kill);
"@
    Write-Log "Dropping all connections to $DatabaseName..." $LogFile
    try {
        Invoke-Sqlcmd -ServerInstance $SqlInstance -Query $dropConnQuery -Database master -ErrorAction Stop
        Write-Log "All connections to $DatabaseName dropped." $LogFile
    } catch {
        Write-Log ("ERROR: Failed to drop all connections to {0}: {1}" -f $DatabaseName, $_.Exception.Message) $LogFile
        exit 1
    }

    # Set database to single_user with rollback immediate and offline
    $setSingleUser = "ALTER DATABASE [$DatabaseName] SET SINGLE_USER WITH ROLLBACK IMMEDIATE"
    $setOffline = "ALTER DATABASE [$DatabaseName] SET OFFLINE"
    Write-Log "Setting database $DatabaseName to SINGLE_USER with rollback immediate..." $LogFile
    try {
        Invoke-Sqlcmd -ServerInstance $SqlInstance -Query $setSingleUser -ErrorAction Stop
    } catch {
        $errMsg = $_.Exception.Message
        Write-Log "ERROR: Failed to set $DatabaseName to SINGLE_USER with rollback immediate: $errMsg" $LogFile
        Write-Log "ERROR: Critical failure. Stopping script." $LogFile
        exit 1
    }

    Write-Log "Setting database $DatabaseName OFFLINE..." $LogFile
    try {
        Invoke-Sqlcmd -ServerInstance $SqlInstance -Query $setOffline -ErrorAction Stop
    } catch {
        Write-Log "ERROR: Failed to set $DatabaseName OFFLINE: $($_.Exception.Message)" $LogFile
        exit 1
    }

    # Change logical file names while DB is offline
    if ($LogicalRenameScript) {
        Write-Log "Starting logical file renaming step (while DB offline)..." $LogFile
        Write-Log "Executing SQL script: $LogicalRenameScript" $LogFile
        if (!(Test-Path $LogicalRenameScript)) {
            Write-Log "ERROR: SQL file not found: $LogicalRenameScript. Stopping script." $LogFile
            exit 1
        }
        # Log each SQL statement in the script
        $sqlLines = Get-Content $LogicalRenameScript | Where-Object { $_.Trim() -ne '' }
        foreach ($line in $sqlLines) {
            Write-Log "[LOGICAL RENAME SQL] $line" $LogFile
        }
            Invoke-SqlcmdWithLogging -SqlFilePath $LogicalRenameScript -ServerInstance $SqlInstance -LogFile $LogFile
            # Query and log logical file names after renaming
            $query = "SELECT name, physical_name FROM sys.master_files WHERE database_id = DB_ID('$DatabaseName')"
            try {
                $result = Invoke-Sqlcmd -ServerInstance $SqlInstance -Query $query -ErrorAction Stop
                foreach ($row in $result) {
                    Write-Log ("Logical file: {0}, Physical file: {1}" -f $row.name, $row.physical_name) $LogFile
                }
                Write-Log "All logical file names have been changed and confirmed." $LogFile
            } catch {
                Write-Log ("ERROR: Failed to confirm logical file names: {0}" -f $_.Exception.Message) $LogFile
                exit 1
            }
    }

    # Rename files
    foreach ($item in $FileMap) {
        $src = $item.Source
        $dst = $item.Destination
        Write-Log ("[PHYSICAL RENAME CMD] Rename-Item -Path '{0}' -NewName '{1}'" -f $src, $dst) $LogFile
        Write-Log "Renaming $($src) to $($dst)" $LogFile
        try {
            Rename-Item -Path $src -NewName $dst -ErrorAction Stop
        } catch {
            Write-Log ("ERROR: Failed to rename {0} to {1}: {2}" -f $src, $dst, $_.Exception.Message) $LogFile
            exit 1
        }
    }
    Write-Log "All physical file names have been changed." $LogFile
    # Validate that all destination files exist
    $missingFiles = @()
    $foundFiles = @()
    foreach ($item in $FileMap) {
        $dst = $item.Destination
        if (Test-Path $dst) {
            $foundFiles += $dst
        } else {
            $missingFiles += $dst
        }
    }
    if ($missingFiles.Count -gt 0) {
        Write-Log ("ERROR: The following expected database files are missing after renaming: {0}" -f ($missingFiles -join ', ')) $LogFile
        exit 1
    } else {
        Write-Log "All expected database files are present after renaming." $LogFile
        Write-Log ("Files found: {0}" -f ($foundFiles -join ', ')) $LogFile
    }
}

function Set-DatabaseOnlineAndRename {
    <#
    .SYNOPSIS
        Brings a database online, sets it to multi_user, and renames it.
    .PARAMETER DatabaseName
        The current name of the database.
    .PARAMETER NewDatabaseName
        The new name for the database.
    .PARAMETER SqlInstance
        The SQL Server instance to connect to (default: localhost).
    .PARAMETER LogFile
        Optional path to a log file for status and error messages.
    #>
    param (
        [Parameter(Mandatory)]
        [string]$DatabaseName,
        [Parameter(Mandatory)]
        [string]$NewDatabaseName,
        [string]$SqlInstance = 'localhost',
        [string]$LogFile = $null
    )

    Write-Log "Bringing database $DatabaseName online..." $LogFile
    try {
        Invoke-Sqlcmd -ServerInstance $SqlInstance -Query "ALTER DATABASE [$DatabaseName] SET ONLINE" -Database master -ErrorAction Stop
        Write-Log "$DatabaseName is now online." $LogFile
    } catch {
        Write-Log ("ERROR: Failed to bring {0} online: {1}" -f $DatabaseName, $_.Exception.Message) $LogFile
        exit 1
    }

    Write-Log "Setting $DatabaseName to MULTI_USER..." $LogFile
    try {
        Invoke-Sqlcmd -ServerInstance $SqlInstance -Query "ALTER DATABASE [$DatabaseName] SET MULTI_USER WITH ROLLBACK IMMEDIATE" -Database master -ErrorAction Stop
        Write-Log "$DatabaseName is now in MULTI_USER mode." $LogFile
    } catch {
        Write-Log ("ERROR: Failed to set {0} to MULTI_USER: {1}" -f $DatabaseName, $_.Exception.Message) $LogFile
        exit 1
    }

    Write-Log "Renaming $DatabaseName to $NewDatabaseName..." $LogFile
    try {
        Invoke-Sqlcmd -ServerInstance $SqlInstance -Query "ALTER DATABASE [$DatabaseName] MODIFY NAME = [$NewDatabaseName]" -Database master -ErrorAction Stop
        Write-Log "$DatabaseName renamed to $NewDatabaseName." $LogFile
    } catch {
        Write-Log ("ERROR: Failed to rename {0} to {1}: {2}" -f $DatabaseName, $NewDatabaseName, $_.Exception.Message) $LogFile
        exit 1
    }
}

function Set-LogicalDatabaseFileName {
    <#
    .SYNOPSIS
        Executes a SQL script to rename logical database files after the database is offline.
    .PARAMETER SqlFilePath
        Path to the SQL file containing ALTER DATABASE ... MODIFY FILE statements.
    .PARAMETER LogFile
        Optional path to a log file for status and error messages.
    #>
    param (
        [Parameter(Mandatory)]
        [string]$SqlFilePath,
        [string]$LogFile = $null
    )

    Write-Log "Starting logical database file renaming step." $LogFile
    Write-Log "Executing SQL script: $SqlFilePath" $LogFile
    if (!(Test-Path $SqlFilePath)) {
        Write-Log "ERROR: SQL file not found: $SqlFilePath. Stopping script." $LogFile
        exit 1
    }
    Invoke-SqlcmdWithLogging -SqlFilePath $SqlFilePath -LogFile $LogFile
}

function Write-Log {
    param(
        [string]$Message,
        [string]$LogFile = $null
    )
    $timestamp = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
    $logDir = "K:\SITSRefresh"
    if (-not $LogFile) {
        $dateTag = (Get-Date -Format 'yyyyMMdd_HHmmss')
        $LogFile = Join-Path $logDir "ScriptLog_$dateTag.txt"
        $global:CurrentLogFile = $LogFile
    } else {
        if (-not $global:CurrentLogFile) {
            $global:CurrentLogFile = $LogFile
        }
        $LogFile = $global:CurrentLogFile
    }
    if (!(Test-Path $logDir)) {
        New-Item -Path $logDir -ItemType Directory -Force | Out-Null
    }
    $logEntry = "$timestamp $Message"
    Write-Host $logEntry
    $logEntry | Out-File -FilePath $LogFile -Append -Encoding utf8
}


function Refresh-DatabaseUsers {
    param(
        [Parameter(Mandatory)]
        [string]$SourceDatabase, # SISB, SIIT, or SITR
        [string]$SqlInstance = 'localhost',
        [string]$LogFile = $null
    )
    $scriptPath = 'd:\Scripts\Refresh Scripts\SQL\RefreshUsers.sql'
    if (!(Test-Path $scriptPath)) {
        Write-Log "ERROR: SQL script not found: $scriptPath" $LogFile
        return
    }
    # Replace the @SourceDb variable in the script with the selected source database
    $scriptContent = Get-Content $scriptPath -Raw
    $scriptContent = $scriptContent -replace "DECLARE @SourceDb NVARCHAR\(128\) = '[^']+';", "DECLARE @SourceDb NVARCHAR(128) = '$SourceDatabase';"
    $tempScript = Join-Path $env:TEMP "RefreshUsers_$SourceDatabase.sql"
    $scriptContent | Set-Content $tempScript
    Write-Log "Running user refresh for environment: $SourceDatabase using $tempScript" $LogFile
    Invoke-SqlcmdWithLogging -SqlFilePath $tempScript -ServerInstance $SqlInstance -LogFile $LogFile
    Remove-Item $tempScript -ErrorAction SilentlyContinue
}

Export-ModuleMember -Function Write-Log, Get-LatestLiveBackup, Set-DatabaseFileName, Set-DatabaseOnlineAndRename, Set-LogicalDatabaseFileName, Rename-DatabaseFilesAndLogicalNames, Refresh-DatabaseUsers

function Rename-DatabaseFilesAndLogicalNames {
    param (
        [Parameter(Mandatory)]
        [array]$FileMap, # @{ Source = ..., Destination = ... }
        [Parameter(Mandatory)]
        [string]$DatabaseName,
        [string]$SqlInstance = 'localhost',
        [string]$LogFile = $null
    )
    # Build logical rename map from file map
    $logicalRenameMap = $FileMap | ForEach-Object {
        @{ LogicalName = [System.IO.Path]::GetFileNameWithoutExtension($_.Source); NewLogicalName = [System.IO.Path]::GetFileNameWithoutExtension($_.Destination) }
    }
    # Step 1: Rename logical file names
    Set-LogicalDatabaseFileName -LogicalRenameMap $logicalRenameMap -DatabaseName $DatabaseName -SqlInstance $SqlInstance -LogFile $LogFile
    # Step 2: Rename physical files
    foreach ($item in $FileMap) {
        $src = $item.Source
        $dst = $item.Destination
        Write-Log ("[PHYSICAL RENAME CMD] Rename-Item -Path '{0}' -NewName '{1}'" -f $src, $dst) $LogFile
        Write-Log "Renaming $($src) to $($dst)" $LogFile
        try {
            Rename-Item -Path $src -NewName $dst -ErrorAction Stop
        } catch {
            Write-Log ("ERROR: Failed to rename {0} to {1}: {2}" -f $src, $dst, $_.Exception.Message) $LogFile
            exit 1
        }
    }
    Write-Log "All physical file names have been changed." $LogFile
    # Validate that all destination files exist
    $missingFiles = @()
    $foundFiles = @()
    foreach ($item in $FileMap) {
        $dst = $item.Destination
        if (Test-Path $dst) {
            $foundFiles += $dst
        } else {
            $missingFiles += $dst
        }
    }
    if ($missingFiles.Count -gt 0) {
        Write-Log ("ERROR: The following expected database files are missing after renaming: {0}" -f ($missingFiles -join ', ')) $LogFile
        exit 1
    } else {
        Write-Log "All expected database files are present after renaming." $LogFile
        Write-Log ("Files found: {0}" -f ($foundFiles -join ', ')) $LogFile
    }
}

function Refresh-DatabaseFileNames {
    param (
        [Parameter(Mandatory)]
        [array]$FileMap, # @{ Source = ..., Destination = ... }
        [Parameter(Mandatory)]
        [string]$DatabaseName,
        [string]$SqlInstance = 'localhost',
        [string]$LogFile = $null
    )
    # Step 1: Update SQL metadata FILENAME for each file while DB is online
    foreach ($item in $FileMap) {
        $logicalName = [System.IO.Path]::GetFileNameWithoutExtension($item.Source)
        $newPhysicalPath = $item.Destination
        $sql = "ALTER DATABASE [$DatabaseName] MODIFY FILE (NAME = N'$logicalName', FILENAME = N'$newPhysicalPath')"
        Write-Log "[METADATA FILENAME UPDATE CMD] $sql" $LogFile
        $retry = $false
        do {
            try {
                Invoke-Sqlcmd -ServerInstance $SqlInstance -Query $sql -ErrorAction Stop
                Write-Log "Metadata FILENAME updated for logical file: $logicalName -> $newPhysicalPath" $LogFile
                $retry = $false
            } catch {
                $errMsg = $_.Exception.Message
                Write-Log ("ERROR: Failed to update metadata FILENAME for logical file {0}: {1}" -f $logicalName, $errMsg) $LogFile
                if ($errMsg -like "*is already used by another database file*") {
                    # Find the database that owns the conflicting file
                    $conflictQuery = "SELECT DB_NAME(database_id) AS DatabaseName FROM sys.master_files WHERE physical_name = '$newPhysicalPath'"
                    $conflictDb = Invoke-Sqlcmd -ServerInstance $SqlInstance -Query $conflictQuery -ErrorAction Stop | Select-Object -ExpandProperty DatabaseName
                    Write-Host "The path name '$newPhysicalPath' is already used by another database file."
                    Write-Host "Database: $conflictDb owns the file that caused the issue."
                    $response = Read-Host "Do you want to delete the database '$conflictDb'? (Y/N)"
                    if ($response -eq 'Y' -or $response -eq 'y') {
                        Write-Log "User chose to delete database $conflictDb due to file path conflict." $LogFile
                        try {
                            Invoke-Sqlcmd -ServerInstance $SqlInstance -Query "DROP DATABASE [$conflictDb]" -ErrorAction Stop
                            Write-Log "Database $conflictDb deleted successfully." $LogFile
                            $retry = $true
                        } catch {
                            Write-Log ("ERROR: Failed to delete database {0}: {1}" -f $conflictDb, $_.Exception.Message) $LogFile
                            exit 1
                        }
                    } else {
                        Write-Log "User chose not to delete database $conflictDb. Stopping script." $LogFile
                        exit 1
                    }
                } else {
                    exit 1
                }
            }
        } while ($retry)
    }
    # Confirm metadata after update
    $query = "SELECT name, physical_name FROM sys.master_files WHERE database_id = DB_ID('$DatabaseName')"
    $result = Invoke-Sqlcmd -ServerInstance $SqlInstance -Query $query -ErrorAction Stop
    foreach ($row in $result) {
        Write-Log ("Logical file: {0}, Physical file: {1}" -f $row.name, $row.physical_name) $LogFile
    }
    Write-Log "All metadata FILENAME values have been updated and confirmed." $LogFile

    # Step 2: Drop connections, set single user, set offline
    $dropConnQuery = @"
DECLARE @kill varchar(8000) = '';
SELECT @kill = @kill + 'KILL ' + CONVERT(varchar(5), session_id) + ';'
FROM sys.dm_exec_sessions
WHERE database_id = db_id('$DatabaseName') AND session_id <> @@SPID;
EXEC(@kill);
"@
    Write-Log "Dropping all connections to $DatabaseName..." $LogFile
    try {
        Invoke-Sqlcmd -ServerInstance $SqlInstance -Query $dropConnQuery -Database master -ErrorAction Stop
        Write-Log "All connections to $DatabaseName dropped." $LogFile
    } catch {
        Write-Log ("ERROR: Failed to drop all connections to {0}: {1}" -f $DatabaseName, $_.Exception.Message) $LogFile
        exit 1
    }
    $setSingleUser = "ALTER DATABASE [$DatabaseName] SET SINGLE_USER WITH ROLLBACK IMMEDIATE"
    $setOffline = "ALTER DATABASE [$DatabaseName] SET OFFLINE"
    Write-Log "Setting database $DatabaseName to SINGLE_USER with rollback immediate..." $LogFile
    try {
        Invoke-Sqlcmd -ServerInstance $SqlInstance -Query $setSingleUser -ErrorAction Stop
    } catch {
        Write-Log "ERROR: Failed to set $DatabaseName to SINGLE_USER with rollback immediate: $($_.Exception.Message)" $LogFile
        exit 1
    }
    Write-Log "Setting database $DatabaseName OFFLINE..." $LogFile
    try {
        Invoke-Sqlcmd -ServerInstance $SqlInstance -Query $setOffline -ErrorAction Stop
    } catch {
        Write-Log "ERROR: Failed to set $DatabaseName OFFLINE: $($_.Exception.Message)" $LogFile
        exit 1
    }

    # Step 3: Rename physical files
    foreach ($item in $FileMap) {
        $src = $item.Source
        $dst = $item.Destination
        Write-Log ("[PHYSICAL RENAME CMD] Rename-Item -Path '{0}' -NewName '{1}'" -f $src, $dst) $LogFile
        Write-Log "Renaming $($src) to $($dst)" $LogFile
        try {
            Rename-Item -Path $src -NewName $dst -ErrorAction Stop
        } catch {
            Write-Log ("ERROR: Failed to rename {0} to {1}: {2}" -f $src, $dst, $_.Exception.Message) $LogFile
            exit 1
        }
    }
    Write-Log "All physical file names have been changed." $LogFile
    # Validate that all destination files exist
    $missingFiles = @()
    $foundFiles = @()
    foreach ($item in $FileMap) {
        $dst = $item.Destination
        if (Test-Path $dst) {
            $foundFiles += $dst
        } else {
            $missingFiles += $dst
        }
    }
    if ($missingFiles.Count -gt 0) {
        Write-Log ("ERROR: The following expected database files are missing after renaming: {0}" -f ($missingFiles -join ', ')) $LogFile
        exit 1
    } else {
        Write-Log "All expected database files are present after renaming." $LogFile
        Write-Log ("Files found: {0}" -f ($foundFiles -join ', ')) $LogFile
    }

    # Step 4: Bring database online and multi_user
    $setOnline = "ALTER DATABASE [$DatabaseName] SET ONLINE"
    $setMultiUser = "ALTER DATABASE [$DatabaseName] SET MULTI_USER WITH ROLLBACK IMMEDIATE"
    Write-Log "Bringing database $DatabaseName online..." $LogFile
    try {
        Invoke-Sqlcmd -ServerInstance $SqlInstance -Query $setOnline -Database master -ErrorAction Stop
        Write-Log "$DatabaseName is now online." $LogFile
    } catch {
        Write-Log ("ERROR: Failed to bring {0} online: {1}" -f $DatabaseName, $_.Exception.Message) $LogFile
        exit 1
    }
    Write-Log "Setting $DatabaseName to MULTI_USER..." $LogFile
    try {
        Invoke-Sqlcmd -ServerInstance $SqlInstance -Query $setMultiUser -Database master -ErrorAction Stop
        Write-Log "$DatabaseName is now in MULTI_USER mode." $LogFile
    } catch {
        Write-Log ("ERROR: Failed to set {0} to MULTI_USER: {1}" -f $DatabaseName, $_.Exception.Message) $LogFile
        exit 1
    }
}

function Restore-DatabaseFromBackup {
    param (
        [Parameter(Mandatory)]
        [string]$DatabaseName,
        [Parameter(Mandatory)]
        [string]$BackupFile,
        [Parameter(Mandatory)]
        [array]$MoveMap, # Array of @{ LogicalName = ..., PhysicalPath = ... }
        [string]$SqlInstance = 'localhost',
        [string]$LogFile = $null
    )

    # Build MOVE clauses using the -Database parameter for file names
    $envName = $DatabaseName
    $moveClauses = @()
    for ($i = 1; $i -le 8; $i++) {
        $moveClauses += "MOVE N'sipr_data0$i' TO N'D:\SQL_Data\${envName}_data0$i.mdf'"
    }
    $moveClauses += "MOVE N'sipr_log' TO N'L:\SQL_TLogs\${envName}_log.ldf'"
    # Join MOVE clauses with comma and newline, but no trailing comma
    # Join MOVE clauses with comma and newline, but ensure no trailing comma before REPLACE
    if ($moveClauses.Count -gt 0) {
        $moveSql = ($moveClauses -join ",`n    ")
    } else {
        $moveSql = ""
    }

    # Always restore as SITSRefresh
    $restoreDbName = 'SITSRefresh'
    $restoreSql = "RESTORE DATABASE [$restoreDbName] FROM DISK = N'$BackupFile' WITH FILE = 1"
    if ($moveSql) {
        $restoreSql += ",`n    $moveSql"
    }
    $restoreSql += ", REPLACE, STATS = 5`nGO"

    Write-Log "[RESTORE SQL] $restoreSql" $LogFile
    try {
        Write-Host "Restore in progress... this may take a while."
        Write-Log "Restore in progress... this may take a while." $LogFile
        Invoke-Sqlcmd -ServerInstance $SqlInstance -Query $restoreSql -ErrorAction Stop -QueryTimeout 0
        Write-Host "Restore completed."
        Write-Log "Restore completed." $LogFile
        Write-Log "Database $restoreDbName restored successfully from $BackupFile." $LogFile
    } catch {
        Write-Log ("ERROR: Failed to restore database {0} from backup {1}: {2}" -f $restoreDbName, $BackupFile, $_.Exception.Message) $LogFile
        exit 1
    }
}
Export-ModuleMember -Function Write-Log, Get-LatestLiveBackup, Set-DatabaseFileName, Set-DatabaseOnlineAndRename, Set-LogicalDatabaseFileName, Rename-DatabaseFilesAndLogicalNames, Refresh-DatabaseFileNames, Restore-DatabaseFromBackup

# Runs an external SQL script using sqlcmd.exe and logs all output and errors
function Invoke-SqlcmdWithLogging {
    param(
        [Parameter(Mandatory)]
        [string]$SqlFilePath,
        [string]$ServerInstance = 'localhost',
        [string]$Database = $null,
        [string]$LogFile = $null
    )
    $sqlcmdPath = (Get-Command sqlcmd.exe -ErrorAction SilentlyContinue).Source
    if (-not $sqlcmdPath) {
        Write-Log "ERROR: sqlcmd.exe not found in PATH." $LogFile
        return
    }
    $args = @('-S', $ServerInstance)
    if ($Database) { $args += @('-d', $Database) }
    $args += @('-i', $SqlFilePath)
    Write-Log "[SQLCMD EXEC] $sqlcmdPath $($args -join ' ')" $LogFile
    try {
        $process = Start-Process -FilePath $sqlcmdPath -ArgumentList $args -NoNewWindow -RedirectStandardOutput "$env:TEMP\sqlcmd_stdout.txt" -RedirectStandardError "$env:TEMP\sqlcmd_stderr.txt" -Wait -PassThru
        $stdout = Get-Content "$env:TEMP\sqlcmd_stdout.txt" -Raw
        $stderr = Get-Content "$env:TEMP\sqlcmd_stderr.txt" -Raw
        if ($stdout) { Write-Log "[SQLCMD OUTPUT] $stdout" $LogFile }
        if ($stderr) { Write-Log "[SQLCMD ERROR] $stderr" $LogFile }
        if ($process.ExitCode -ne 0) {
            Write-Log "ERROR: sqlcmd.exe exited with code $($process.ExitCode)" $LogFile
        }
    } catch {
        Write-Log "ERROR: Exception running sqlcmd.exe: $($_.Exception.Message)" $LogFile
    } finally {
        Remove-Item "$env:TEMP\sqlcmd_stdout.txt","$env:TEMP\sqlcmd_stderr.txt" -ErrorAction SilentlyContinue
    }
}
