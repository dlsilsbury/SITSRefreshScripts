/************************************************
    SITS Data Copy Script (Environment-Agnostic)
    Purpose: Copy data from <Database>Old to SITSRefresh for selected tables
    Features:
      - Environment-specific logic (WALTHAM only tables)
      - Transactional integrity
      - Dynamic SQL for maintainability
      - Error handling and progress messages
      - Environment name variable for SISB, SIIT, SITR, etc.
    Usage: Set @Database at the top before running
************************************************/

-- Enable NOCOUNT to avoid extra result sets
SET NOCOUNT ON;

-- Set environment name here (SISB, SIIT, SITR)
:SETVAR Database SISB
DECLARE @Database NVARCHAR(10) = '$(Database)';
DECLARE @OldDb NVARCHAR(50) = '$(OldDatabaseName)';
DECLARE @RefreshDb NVARCHAR(50) = 'SITSRefresh';

DECLARE @HousekeepingTables TABLE (TableName NVARCHAR(128))
INSERT INTO @HousekeepingTables VALUES 
('MEN_AUD'),
('MEN_AUH'),
('MEN_APH'),
('MEN_BPL'),
('MEN_DMS'),
('MEN_GSL'),
('MEN_GSLN'),
('MEN_ISS'),
('MEN_LCD'),
('MEN_MAL'),
('MEN_MOV'),
('MEN_MUS'),
('MEN_PAL'),
('MEN_TAR'),
('MEN_UAL'),
('MEN_UMO'),
('MEN_UPA'),
('MEN_WTL'),
('MEN_MML'),
('MEN_UTL'),
('MEN_CSL'),
('MEN_DCE'),
('MEN_DMR'),
('MEN_DOT'),
('MEN_DTO'),
('MEN_EOT'),
('MEN_SMD'),
('MEN_SSO'),
('MEN_TOT'),
('MEN_HAT'),
('SRS_FLY');

-- WALTHAM-only tables to copy
DECLARE @DevTables TABLE (TableName NVARCHAR(128))
INSERT INTO @DevTables VALUES 
('MEN_WRF'), 
('MEN_WFL'), 
('MEN_XWRF'), 
('MEN_XWFL');

-- All environments tables to copy
DECLARE @AllTables TABLE (TableName NVARCHAR(128))
INSERT INTO @AllTables VALUES 
('MEN_CUS'),
('MEN_FTS'),
('MEN_FTY'),
('MEN_LDP'),
('MEN_URI'),
('MEN_PBI'),
('MEN_PGM'),
('MEN_PGR'),
('MEN_PRB'),
('MEN_PRI'),
('MEN_PRJ'),
('MEN_PRT'),
('SRS_CNT'),
('SRS_OPM'),
('MEN_OTA'),
('MEN_UGH'),
('MEN_UIL'),
('MEN_XIP'),
('SRS_DDM'),
('MEN_HTM'),
('SRS_OPT'),
('SRS_AEC');

BEGIN TRY
    BEGIN TRANSACTION

    -- WALTHAM-only tables: MEN_WRF, MEN_WFL, MEN_XWRF, MEN_XWFL
        IF @@ServerName = 'WALTHAM'
        BEGIN
            DECLARE @tbl NVARCHAR(128), @sql NVARCHAR(MAX)
            DECLARE dev_cursor CURSOR FOR SELECT TableName FROM @DevTables
            OPEN dev_cursor
            FETCH NEXT FROM dev_cursor INTO @tbl
            WHILE @@FETCH_STATUS = 0
            BEGIN
                IF OBJECT_ID(@RefreshDb + '.dbo.' + @tbl, 'U') IS NOT NULL
                BEGIN
                    SET @sql = 'TRUNCATE TABLE ' + @RefreshDb + '.dbo.' + @tbl + '; INSERT INTO ' + @RefreshDb + '.dbo.' + @tbl + ' SELECT * FROM ' + @OldDb + '.dbo.' + @tbl
                    EXEC sp_executesql @sql
                    PRINT 'Populated ' + @RefreshDb + '.dbo.' + @tbl
                END
                ELSE
                    PRINT 'Failed to populate ' + @RefreshDb + '.dbo.' + @tbl
                FETCH NEXT FROM dev_cursor INTO @tbl
            END
            CLOSE dev_cursor
            DEALLOCATE dev_cursor
        END

    -- All environments tables: 
        DECLARE @tbl2 NVARCHAR(128), @sql2 NVARCHAR(MAX)
        DECLARE all_cursor CURSOR FOR SELECT TableName FROM @AllTables
        OPEN all_cursor
        FETCH NEXT FROM all_cursor INTO @tbl2
        WHILE @@FETCH_STATUS = 0
        BEGIN
            IF OBJECT_ID(@RefreshDb + '.dbo.' + @tbl2, 'U') IS NOT NULL
            BEGIN
                SET @sql2 = 'TRUNCATE TABLE ' + @RefreshDb + '.dbo.' + @tbl2 + '; INSERT INTO ' + @RefreshDb + '.dbo.' + @tbl2 + ' SELECT * FROM ' + @OldDb + '.dbo.' + @tbl2
                EXEC sp_executesql @sql2
                PRINT 'Populated ' + @RefreshDb + '.dbo.' + @tbl2
            END
            ELSE
                PRINT 'Failed to populate ' + @RefreshDb + '.dbo.' + @tbl2
            FETCH NEXT FROM all_cursor INTO @tbl2
        END
        CLOSE all_cursor
        DEALLOCATE all_cursor

    COMMIT TRANSACTION
    PRINT 'All data copy operations completed successfully.'
END TRY
BEGIN CATCH
    IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION
    PRINT 'Error occurred: ' + ERROR_MESSAGE()
END CATCH


    -- Housekeeping truncation logic (outside transaction for safety)
    DECLARE @hk_tbl NVARCHAR(128), @hk_sql NVARCHAR(MAX)
    DECLARE hk_cursor CURSOR FOR SELECT TableName FROM @HousekeepingTables
    OPEN hk_cursor
    FETCH NEXT FROM hk_cursor INTO @hk_tbl
    WHILE @@FETCH_STATUS = 0
    BEGIN
        IF OBJECT_ID(@RefreshDb + '.dbo.' + @hk_tbl, 'U') IS NOT NULL
        BEGIN
            SET @hk_sql = 'TRUNCATE TABLE ' + @RefreshDb + '.dbo.' + @hk_tbl
            EXEC sp_executesql @hk_sql
            PRINT 'Truncated ' + @RefreshDb + '.dbo.' + @hk_tbl
        END
        ELSE
            PRINT 'Failed to truncate ' + @RefreshDb + '.dbo.' + @hk_tbl
        FETCH NEXT FROM hk_cursor INTO @hk_tbl
    END
    CLOSE hk_cursor
    DEALLOCATE hk_cursor