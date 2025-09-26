<##
.SYNOPSIS
    Orchestrates the SITS refresh process for a given environment.
.DESCRIPTION
    Loads environment-specific config, imports the refresh module, and runs the backup copy step.
    Supports a test mode that uses a dummy backup source.
.PARAMETER Database
    The environment name (e.g., SISB, SIIT, SITR) to refresh.
.PARAMETER IsTest
    Optional switch. If specified, uses a dummy backup source for testing.
#>

param(
    [Parameter(Mandatory)]
    [string]$Database,
    [switch]$IsTest = $false
)

# Prevent running with a database name ending in 'Old'
if ($Database -match '(?i)Old$') {
    Write-Host "[ERROR] Do not run this script with a database name ending in 'Old'. Use the base name (e.g., SISB, SIIT, SITR)."
    exit 1
}

# Elevation check: Relaunch as admin if not already
if (-not ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host "Restarting script as administrator..."
    Read-Host "Press Enter to continue and elevate permissions"
    Start-Process powershell "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`" $($MyInvocation.UnboundArguments)" -Verb RunAs
    exit
}

function Invoke-EnvironmentDataCopy {
    param(
        [Parameter(Mandatory)]
        [string]$Database,
        [Parameter(Mandatory)]
        [string]$SqlFilePath,
        [string]$SqlServerInstance = "localhost",
        [string]$Username,
        [string]$Password
    )

    $sqlcmdArgs = @(
        "-S", $SqlServerInstance,
        "-i", $SqlFilePath,
        "-v", "Database=$Database"
    )

    if ($Username -and $Password) {
        $sqlcmdArgs += @("-U", $Username, "-P", $Password)
    }

    Write-Host "Running SQL data copy for environment: $Database"
    sqlcmd @sqlcmdArgs
}



# Set module and config file paths
$moduleDir = Join-Path -Path $PSScriptRoot -ChildPath 'modules'
$modulePath = Join-Path -Path $moduleDir -ChildPath 'Refresh-SITS.psm1'
$configDir = Join-Path -Path $PSScriptRoot -ChildPath 'config'
$configPath = Join-Path -Path $configDir -ChildPath ("$Database.psd1")

# Validate module and config existence
if (!(Test-Path $modulePath)) { throw "Module not found: $modulePath" }
if (!(Test-Path $configPath)) { throw "Config not found: $configPath" }


# Logging after each major step
Write-Host "[LOG] Script started."
Import-Module $modulePath -Global -Force
Write-Host "[LOG] Module imported."
Write-Log "Script started"
Write-Host "[LOG] Loading config..."
$commonConfig = Import-PowerShellDataFile (Join-Path -Path $configDir -ChildPath 'Common.psd1')
$envConfig = Import-PowerShellDataFile $configPath
$config = @{}
$commonConfig.Keys | ForEach-Object { $config[$_] = $commonConfig[$_] }
$envConfig.Keys | ForEach-Object { $config[$_] = $envConfig[$_] }
Write-Host "[LOG] Config loaded."
Write-Host "[LOG] Config keys: $($config.Keys -join ', ')"
if ($IsTest) {
    Write-Host "[LOG] BackupSource (TEST MODE): K:\SQL_Backups\BEAVERTON\SIPR\FULL"
} else {
    Write-Host "[LOG] BackupSource: $($config.BackupSource)"
}
Write-Host "[LOG] BackupDestination: $($config.BackupDestination)"
Write-Host "[LOG] LogFile: $($config.LogFile)"

# Determine environment type (test or prod)
$envType = if ($IsTest) { 'TEST' } else { 'PROD' }
Write-Host "Running in $envType environment."

# Use dummy backup source if in test mode
$backupSource = if ($IsTest) { 'K:\SQL_Backups\BEAVERTON\SIPR\FULL' } else { $config.BackupSource }
Write-Host "[LOG] Backup source set to $backupSource"

# Run the backup copy step (always pass LogFile if present)
Write-Host "[LOG] Starting backup copy step..."
Get-LatestLiveBackup -BackupSource $backupSource -BackupDestination $config.BackupDestination -LogFile $config.LogFile
Write-Host "[LOG] Backup copy step finished."

# Run file renaming if FileMap is present
if ($config.ContainsKey('FileMap')) {
    Write-Host "[LOG] Starting file renaming step..."
    Write-Host "Renaming database files for $($config.DatabaseName) ..."
    $dbName = $config.DatabaseName
    if (-not $dbName) { $dbName = $Database }
    $sqlInstance = if ($config.ContainsKey('SqlInstance')) { $config.SqlInstance } else { 'localhost' }
    Refresh-DatabaseFileNames -FileMap $config.FileMap -DatabaseName $dbName -SqlInstance $sqlInstance -LogFile $config.LogFile
    Write-Host "[LOG] File renaming step finished."
}

# Bring database online and rename if OldDatabaseName is present
if ($config.ContainsKey('OldDatabaseName')) {
    Write-Host "[LOG] Starting bring online/rename step..."
    $dbName = $Database
    $oldDbName = $config.OldDatabaseName
    $sqlInstance = if ($config.ContainsKey('SqlInstance')) { $config.SqlInstance } else { 'localhost' }
    Write-Host "Bringing database $dbName online and renaming to $oldDbName ..."
    Set-DatabaseOnlineAndRename -DatabaseName $dbName -NewDatabaseName $oldDbName -SqlInstance $sqlInstance
    Write-Host "[LOG] Bring online/rename step finished."
}

# Add more steps here (restore, etc.) using more functions from the module

# Build MoveMap for Restore-DatabaseFromBackup
$MoveMap = @()
for ($i = 1; $i -le 8; $i++) {
    $MoveMap += @{ LogicalName = "sipr_data0$i"; PhysicalPath = "D:\SQL_Data\SITSRefresh_data0$i.mdf" }
}
$MoveMap += @{ LogicalName = "sipr_log"; PhysicalPath = "L:\SQL_TLogs\SITSRefresh_log.ldf" }

# Call Restore-DatabaseFromBackup from the module
$BackupFile = "K:\SITSRefresh\SITSRefresh.bak"
$sqlInstance = if ($config.ContainsKey('SqlInstance')) { $config.SqlInstance } else { 'localhost' }
Write-Host "[LOG] Starting database restore using module function..."
Restore-DatabaseFromBackup -DatabaseName $Database -BackupFile $BackupFile -MoveMap $MoveMap -SqlInstance $sqlInstance -LogFile $config.LogFile
Write-Host "[LOG] Database restore step finished."


# Run user refresh step after restore using OldDatabaseName
Write-Host "[LOG] Starting user refresh step for $Database (source: $($config.OldDatabaseName))..."
Write-Log "Starting user refresh step for $Database using source $($config.OldDatabaseName)" $config.LogFile
Refresh-DatabaseUsers -SourceDatabase $config.OldDatabaseName -SqlInstance $sqlInstance -LogFile $config.LogFile
Write-Host "[LOG] User refresh step finished."
Write-Log "User refresh step finished for $Database" $config.LogFile

# After successful restore, run the data copy SQL script for the environment
$SqlCopyFile = Join-Path (Join-Path $PSScriptRoot 'SQL') 'CopyDataIntoSitsRefresh.sql'
Write-Host "[LOG] Starting data copy step for $Database..."
Write-Log "Starting data copy step for $Database using $SqlCopyFile" $config.LogFile

# Run the SQL data copy and capture output
$copyOutput = Invoke-EnvironmentDataCopy -Database $Database -SqlFilePath $SqlCopyFile -SqlServerInstance $sqlInstance

# Log the output from sqlcmd (table operations)
if ($copyOutput) {
    $copyOutputLines = $copyOutput -split "`r?`n"
    foreach ($line in $copyOutputLines) {
        if ($line.Trim()) {
            Write-Log $line $config.LogFile
        }
    }
}
Write-Host "[LOG] Data copy step finished."
Write-Log "Data copy step finished for $Database" $config.LogFile

# Run the sequence copy SQL script for the environment


$SqlSequenceFile = Join-Path (Join-Path $PSScriptRoot 'SQL') 'CopySequencesIntoSITSRefresh.sql'
# Use OldDatabaseName from config for sequence copy
$SourceDbOld = $config.OldDatabaseName
$debugSourceDbMsg = "[DEBUG] Value of SourceDbOld before sequence copy: $SourceDbOld"
Write-Host $debugSourceDbMsg
Write-Log $debugSourceDbMsg $config.LogFile
# Pre-check: does the source database exist?
$dbExistsQuery = "SELECT COUNT(*) FROM sys.databases WHERE name = '$SourceDbOld'"
$dbExists = Invoke-Sqlcmd -ServerInstance $sqlInstance -Database master -Query $dbExistsQuery | Select-Object -ExpandProperty 'Column1'
if ($dbExists -eq 0) {
    Write-Host "[WARNING] Source database $SourceDbOld does not exist. Sequence copy step will be skipped."
    Write-Log "[WARNING] Source database $SourceDbOld does not exist. Sequence copy step skipped." $config.LogFile
} else {
    Write-Host "[LOG] Starting sequence copy step for $Database (source: $SourceDbOld)..."
    Write-Log "Starting sequence copy step for $Database using $SqlSequenceFile and source $SourceDbOld" $config.LogFile

    # Debug: Log the actual SQLCMD variable value used for $(OldDatabaseName)
    Write-Host "[DEBUG] Passing SQLCMD variable: OldDatabaseName=$SourceDbOld to $SqlSequenceFile"
    Write-Log "[DEBUG] Passing SQLCMD variable: OldDatabaseName=$SourceDbOld to $SqlSequenceFile" $config.LogFile
    # Run the SQL sequence copy and capture output, passing OldDatabaseName as a SQLCMD variable
    $sequenceOutput = sqlcmd -S $sqlInstance -i $SqlSequenceFile -v OldDatabaseName=$SourceDbOld
    if ($LASTEXITCODE -ne 0) {
        Write-Host "[ERROR] sqlcmd failed to pass OldDatabaseName variable. Check that the value is set and the variable is referenced in the SQL script."
        Write-Log "[ERROR] sqlcmd failed to pass OldDatabaseName variable. Value: $SourceDbOld" $config.LogFile
    }

    # Log the output from sqlcmd (sequence operations)
    if ($sequenceOutput) {
        $sequenceOutputLines = $sequenceOutput -split "`r?`n"
        foreach ($line in $sequenceOutputLines) {
            if ($line.Trim()) {
                Write-Log $line $config.LogFile
            }
        }
    }
    Write-Host "[LOG] Sequence copy step finished."
    Write-Log "Sequence copy step finished for $Database" $config.LogFile
}
