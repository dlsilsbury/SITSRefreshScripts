# SISB environment-specific configuration (static values only)
# Shared values are merged in the main script, not here.
@{
    # File renaming map for Rename-DatabaseFiles
    FileMap = @(
        @{ Source = 'D:\SQL_Data\sisb_data01.mdf'; Destination = 'D:\SQL_Data\sisbold_data01.mdf' },
        @{ Source = 'D:\SQL_Data\sisb_data02.ndf'; Destination = 'D:\SQL_Data\sisbold_data02.ndf' },
        @{ Source = 'D:\SQL_Data\sisb_data03.ndf'; Destination = 'D:\SQL_Data\sisbold_data03.ndf' },
        @{ Source = 'D:\SQL_Data\sisb_data04.ndf'; Destination = 'D:\SQL_Data\sisbold_data04.ndf' },
        @{ Source = 'D:\SQL_Data\sisb_data05.ndf'; Destination = 'D:\SQL_Data\sisbold_data05.ndf' },
        @{ Source = 'D:\SQL_Data\sisb_data06.ndf'; Destination = 'D:\SQL_Data\sisbold_data06.ndf' },
        @{ Source = 'D:\SQL_Data\sisb_data07.ndf'; Destination = 'D:\SQL_Data\sisbold_data07.ndf' },
        @{ Source = 'D:\SQL_Data\sisb_data08.ndf'; Destination = 'D:\SQL_Data\sisbold_data08.ndf' },
        @{ Source = 'L:\SQL_TLogs\sisb_log.ldf'; Destination = 'L:\SQL_TLogs\sisbold_log.ldf' }
    )
    # Old name for the database after bringing online
    OldDatabaseName = 'SISBOld'
    # Add more settings as needed, unique to SISB
}
