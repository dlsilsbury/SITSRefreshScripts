/************************************************
-- Delete all non-system users from SITSRefresh
************************************************/
USE SITSRefresh;
GO

-- Step 1: Transfer schema ownership to dbo for all non-system users
DECLARE @schemaSql NVARCHAR(MAX) = '';
SELECT @schemaSql = @schemaSql + 'ALTER AUTHORIZATION ON SCHEMA::[' + s.name + '] TO dbo;' + CHAR(13)
FROM sys.schemas s
WHERE s.principal_id IN (
    SELECT principal_id FROM sys.database_principals
    WHERE type IN ('S','U','G')
      AND name NOT IN ('dbo','guest','INFORMATION_SCHEMA','sys','MS_DataCollectorInternalUser')
);
IF LEN(@schemaSql) > 0 EXEC sp_executesql @schemaSql;

-- Step 2: Drop all non-system users
DECLARE @userSql NVARCHAR(MAX) = '';
SELECT @userSql = @userSql + 'DROP USER [' + dp.name + '];' + CHAR(13)
FROM sys.database_principals dp
WHERE dp.type IN ('S','U','G')
  AND dp.name NOT IN ('dbo','guest','INFORMATION_SCHEMA','sys','MS_DataCollectorInternalUser');
IF LEN(@userSql) > 0 EXEC sp_executesql @userSql;
GO

/************************************************
-- Generate CREATE USER statements from source database
************************************************/

-- Step 3: Generate CREATE USER statements from source database using dynamic SQL

-- Step 3: Generate CREATE USER statements from source database using dynamic SQL
DECLARE @SourceDb NVARCHAR(128) = 'SISB'; -- Change to SIIT or SITR as needed
DECLARE @createSql NVARCHAR(MAX) = '';
DECLARE @sql NVARCHAR(MAX);
SET @sql =
'SELECT @createSql = @createSql + ''CREATE USER ['' + name + ''] FOR LOGIN ['' + name + ''];'' + CHAR(13)
FROM ' + QUOTENAME(@SourceDb) + '.sys.database_principals
WHERE type IN (''S'',''U'',''G'')
  AND name NOT IN (''dbo'',''guest'',''INFORMATION_SCHEMA'',''sys'',''MS_DataCollectorInternalUser'');';
EXEC sp_executesql @sql, N'@createSql NVARCHAR(MAX) OUTPUT', @createSql OUTPUT;
PRINT @createSql;
-- To execute, copy output and run in SITSRefresh, or use dynamic SQL if permissions allow
-- EXEC sp_executesql @createSql;
GO
