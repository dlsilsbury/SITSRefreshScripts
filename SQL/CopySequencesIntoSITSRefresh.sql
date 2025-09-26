/* Copy sequences into SITSRefresh  */
USE SITSRefresh
go

declare @sql nvarchar(max)
set @sql = ''

SELECT @sql = @sql+
	' print ''[LOG] Altering sequence: '+name+'''\n'
	+ ' print ''[LOG] Restarting sequence [' + name + '] with value ' + convert(varchar, current_value) + '''\n'
	+ ' alter sequence [' + name + '] restart with ' + convert(varchar, current_value) + '\n'
FROM $(Database)Old.sys.sequences
WHERE name in
	('SRS_DCN_CODE', 'SRS_DDM_CODE', 'SRS_DDR_CODE' , 'SRS_GPI_SEQN',          
	 'SRS_GTI_SEQN', 'SRS_GTH_SEQN', 'SRS_KDX_CODE', 'SRS_LEB_ALCB', 'SRS_LEB_EBAT', 
	 'SRS_LEB_LBAT', 'SRS_LEB_TBAT', 'SRS_LEH_CODE', 'SRS_LGH_CODE',  
	 'SRS_LGT_CODE', 'SRS_LPT_CODE', 'SRS_LTE_CODE')



--print @sql
execute (@sql)