exec [Tools].[P_DDL_Set_Test]
	'Default dates must be UTC',
	'select TABLE_SCHEMA, TABLE_NAME, COLUMN_NAME, COLUMN_DEFAULT from INFORMATION_SCHEMA.COLUMNS
	where DATA_TYPE = ''datetime'' and COLUMN_DEFAULT not like ''%utc%''';
go

exec [Tools].[P_DDL_Set_Test]
	'Defaults must be named',
	'select 
		SCHEMA_NAME([schema_id]) + ''.'' + OBJECT_NAME(parent_object_id) as Table_Name, 
		COL_NAME(parent_object_id, parent_column_id) Column_Name, 
		[name] as Constraint_Name
	from sys.default_constraints 
	where is_system_named = 1 and SCHEMA_NAME([schema_id]) not in (''dbo'', ''Tools'')';
go

exec [Tools].[P_DDL_Set_Test]
	'Use CREATE UNIQUE INDEX instead of adding a constraint to a table',
	'select * from INFORMATION_SCHEMA.TABLE_CONSTRAINTS 
	where CONSTRAINT_TYPE = ''UNIQUE'' and CONSTRAINT_SCHEMA not in (''dbo'', ''Tools'', ''sys'')';
go

exec [Tools].[P_DDL_Set_Test]
	'Table should have a primary key and a clustered index on the same column',
	'select 
		OBJECT_SCHEMA_NAME([object_id]) + ''.'' + OBJECT_NAME([object_id]) as Table_Name,
		type_desc,
		is_primary_key
	from sys.indexes
	where OBJECT_SCHEMA_NAME(object_id) not in (''sys'', ''Tools'')
		and OBJECT_SCHEMA_NAME(object_id) not like ''History%''
		and OBJECTPROPERTY(object_id, ''IsTable'') = 1
		and (type_desc <> ''NONCLUSTERED'' or is_primary_key = 1)
		and (type_desc = ''HEAP'' or is_primary_key = 0)';
go

exec [Tools].[P_DDL_Set_Test]
	'The primary key should be on 1 column thats an identity and named after the table, plus "Id"',
	'select SCHEMA_NAME(t.[schema_id]) + ''.'' + t.[name] as Table_Name
	from sys.tables t
	join sys.indexes i on t.[object_id] = i.[object_id]
	join sys.index_columns ic on i.[object_id] = ic.[object_id] and i.index_id = ic.index_id
	where SCHEMA_NAME(t.[schema_id]) not in (''sys'', ''Tools'', ''dbo'', ''Staging'')
		and i.[type_desc] = ''CLUSTERED''
		and i.is_primary_key = 1
		and COL_NAME(ic.[object_id], ic.column_id) not in (''PartitionKey'')
		and (
			ic.index_column_id > 1
			or COL_NAME(ic.[object_id], ic.column_id) <> t.[name] + ''Id''
			or COLUMNPROPERTY(ic.[object_id], COL_NAME(ic.[object_id], ic.column_id), ''IsIdentity'') = 0
		)
	order by 1';
go

exec [Tools].[P_DDL_Set_Test]
	'Foreign keys must be enforced',
	'select OBJECT_SCHEMA_NAME(c.[object_id]) + ''.'' + OBJECT_NAME(c.[object_id]) as Table_Name, c.[name] as Column_Name
	from sys.columns c
	left join sys.foreign_key_columns fkc on c.[object_id] = fkc.parent_object_id and c.column_id = fkc.parent_column_id
	where OBJECT_SCHEMA_NAME(c.[object_id]) not in (''dbo'', ''Staging'', ''sys'', ''Tools'')
		and OBJECT_SCHEMA_NAME(c.[object_id]) not like ''History%''
		and OBJECT_NAME(c.[object_id]) not like ''PocE%''
		and c.[name] not like ''Source%Id'' 
		and c.[name] like ''%Id'' 
		and TYPE_NAME(c.user_type_id) like ''%int''
		and c.is_identity = 0
		and fkc.parent_object_id is null
		and OBJECTPROPERTY(c.[object_id], ''ExecIsAnsiNullsOn'') is null';
go

exec [Tools].[P_DDL_Set_Test]
	'CreatedDt and UpdatedDt must have GETUTCDATE() as the default',
	'select 
		OBJECT_SCHEMA_NAME(c.[object_id]) + ''.'' + t.[name] as Table_Name, 
		c.[name], 
		ISNULL(dc.[definition], '''') as [definition]
	from sys.columns c
	join sys.tables t on c.[object_id] = t.[object_id]
	left join sys.default_constraints dc on c.default_object_id = dc.[object_id]
	where c.[name] in (''CreatedDt'', ''UpdatedDt'')
		and ISNULL(dc.[definition], '''') not like ''%getutcdate%''
		and t.temporal_type_desc <> ''HISTORY_TABLE''';
go

exec [Tools].[P_DDL_Set_Test]
	'The names of the base and history table should match',
	'select 
		OBJECT_SCHEMA_NAME([object_id]) + ''.'' + OBJECT_NAME([object_id]) as Base_Table, 
		OBJECT_SCHEMA_NAME(history_table_id) + ''.'' + OBJECT_NAME(history_table_id) as History_Table
	from sys.tables
	where temporal_type_desc = ''SYSTEM_VERSIONED_TEMPORAL_TABLE''
		and OBJECT_NAME([object_id]) <> OBJECT_NAME(history_table_id)
	order by 1';
go

exec [Tools].[P_DDL_Set_Test]
	'The schema of the history table should match the base with "History" as a prefix. The exception is "History" matches "Core"',
	'select 
		OBJECT_SCHEMA_NAME([object_id]) + ''.'' + OBJECT_NAME([object_id]) as Base_Table, 
		OBJECT_SCHEMA_NAME(history_table_id) + ''.'' + OBJECT_NAME(history_table_id) as History_Table
	from sys.tables
	where temporal_type_desc = ''SYSTEM_VERSIONED_TEMPORAL_TABLE''
		and ''History'' + ISNULL(NULLIF(OBJECT_SCHEMA_NAME([object_id]), ''Core''), '''') <> OBJECT_SCHEMA_NAME(history_table_id)
	order by 1';
go

exec [Tools].[P_DDL_Set_Test]
	'Foreign key columns should be indexed',
	'select OBJECT_SCHEMA_NAME(fkc.parent_object_id) + ''.'' + OBJECT_NAME(fkc.parent_object_id) as Table_Name,
		COL_NAME(fkc.parent_object_id, fkc.parent_column_id)
	from sys.foreign_key_columns fkc
	left join sys.index_columns ic on fkc.parent_object_id = ic.[object_id] and fkc.parent_column_id = ic.column_id
	where OBJECT_SCHEMA_NAME(fkc.parent_object_id) not in (''Tools'', ''dbo'')
		and ic.[object_id] is null';
go

exec [Tools].[P_DDL_Set_Test]
	'Table should be a system versioned temporal table',
	'select SCHEMA_NAME([schema_id]) + ''.'' + [name] as Table_Name
	from sys.tables
	where temporal_type_desc = ''NON_TEMPORAL_TABLE''
		and SCHEMA_NAME([schema_id]) not in (''Staging'', ''Tools'', ''dbo'')';
go

exec [Tools].[P_DDL_Set_Test]
	'Foreign keys should reference the primary key',
	'select 
		OBJECT_SCHEMA_NAME(fk.parent_object_id) + ''.'' + OBJECT_NAME(fk.parent_object_id) as From_Table, 
		fk.[name] as FK, fk.column_list, i.[name] as Index_Name
	from (
		select referenced_object_id, [name], parent_object_id, (
				select '','' + COL_NAME(referenced_object_id, referenced_column_id)
				from sys.foreign_key_columns
				where constraint_object_id = fk.[object_id] 
				order by 1 for xml path('''')
			) as column_list
		from sys.foreign_keys fk
	) fk
	join (
		select [object_id], [name], (
				select '','' + COL_NAME([object_id], column_id)
				from sys.index_columns
				where [object_id] = i.[object_id] and index_id = i.index_id and is_included_column = 0
				order by 1 for xml path('''')
			) as column_list
		from sys.indexes i where is_unique = 1 and is_primary_key = 0
	) i 
	on fk.referenced_object_id = i.[object_id] and fk.column_list = i.column_list';
go

exec [Tools].[P_DDL_Set_Test]
	'Duplicate foreign key',
	'select 
		OBJECT_SCHEMA_NAME(fk1.parent_object_id) + ''.'' + OBJECT_NAME(fk1.parent_object_id) as Table_Name,
		COL_NAME(fk1.parent_object_id, fk1.parent_column_id) as Column_Name,
		OBJECT_NAME(fk1.constraint_object_id) as FK1,
		OBJECT_NAME(fk2.constraint_object_id) as FK2
	from sys.foreign_key_columns fk1
	join sys.foreign_key_columns fk2 on fk1.parent_object_id = fk2.parent_object_id and fk1.parent_column_id = fk2.parent_column_id
	where fk1.constraint_object_id > fk2.constraint_object_id
		and COL_NAME(fk1.parent_object_id, fk1.parent_column_id) not in (''PartitionKey'')
	order by 1, 2';
go

exec [Tools].[P_DDL_Set_Test]
	'Duplicate index',
	'select 
		OBJECT_SCHEMA_NAME(t1.[object_id]) + ''.'' + OBJECT_NAME(t1.[object_id]) as Table_Name,
		t1.Column_List, t1.[name], t2.[name]
	from (
		select [object_id], [name], index_id,
			stuff((
				select '', '' + COL_NAME([object_id], column_id) from sys.index_columns
				where [object_id] = i.[object_id] and index_id = i.index_id and is_included_column = 0
				for xml path('''')
			), 1, 2, '''') as Column_List
		from sys.indexes i
	) t1
	join (
		select [object_id], [name], index_id,
			stuff((
				select '', '' + COL_NAME([object_id], column_id) from sys.index_columns
				where [object_id] = i.[object_id] and index_id = i.index_id and is_included_column = 0
				for xml path('''')
			), 1, 2, '''') as Column_List
		from sys.indexes i
	) t2 on t1.[object_id] = t2.[object_id] and t1.Column_List = t2.Column_List
	where t1.index_id < t2.index_id
	order by 1, 2';
go

exec [Tools].[P_DDL_Set_Test]
	'Select-star used in proc',
	'select distinct OBJECT_SCHEMA_NAME(object_id) + ''.'' + OBJECT_NAME(object_id) as Table_Name
	from sys.sql_dependencies
	where is_select_all = 1
	order by 1';
go

exec [Tools].[P_DDL_Set_Test]
	'SET LOCK_ESCALATION = AUTO for partitioned tables',
	'select OBJECT_SCHEMA_NAME(object_id) + ''.'' + name as Table_Name
	from sys.tables 
	where object_id in (select distinct object_id from sys.partitions where partition_number <> 1)
		and lock_escalation_desc <> ''AUTO''';
go

exec [Tools].[P_DDL_Set_Test]
	'Incorrect prefix on index name',
	'select 
		OBJECT_SCHEMA_NAME(i.object_id) + ''.'' + OBJECT_NAME(i.object_id) as Table_Name, 
		i.[name],
		i.[type_desc],
		i.is_unique
	from sys.indexes i
	left join (values 
		(''PK_'', ''CLUSTERED'', 1),
		(''UX_'', ''NONCLUSTERED'', 1),
		(''IX_'', ''NONCLUSTERED'', 0)
	) t (prefix, [type_desc], is_unique) 
		on t.prefix = LEFT(i.[name], 3) 
		and i.[type_desc] = t.[type_desc] 
		and i.is_unique = t.is_unique
	where t.prefix is null
		and OBJECT_SCHEMA_NAME(i.object_id) not in (''sys'', ''dbo'')
		and i.[type_desc] not in (''HEAP'')';
go

exec [Tools].[P_DDL_Set_Test]
	'Use Compound (XRef) or Composite in name of indexes with multiple columns',
	'select OBJECT_SCHEMA_NAME(object_id) + ''.'' + OBJECT_NAME(object_id) as Table_Name, name
	from sys.indexes i
	where exists (
			select * from sys.index_columns
			where COL_NAME(object_id, column_id) not in (''PartitionKey'')
				and is_included_column = 0
				and object_id = i.object_id
				and index_id = i.index_id
			group by object_id, index_id
			having count(*) > 1
		)
		and name not like ''%[_]Compo%''
		and OBJECT_SCHEMA_NAME(object_id) not in (''sys'', ''dbo'', ''Tools'')
		and index_id > 1';
go

exec [Tools].[P_DDL_Set_Test]
	'All indexes on foreign keys that point to a partitioned table should also be partitioned',
	'select 
		OBJECT_SCHEMA_NAME(ic.[object_id]) + ''.'' + OBJECT_NAME(ic.[object_id]) as Table_Name, 
		[name], 
		COL_NAME(ic.[object_id], ic.column_id) as Column_Name
	from sys.indexes i
	join sys.index_columns ic on i.[object_id] = ic.[object_id] and i.index_id = ic.index_id
	where COL_NAME(ic.[object_id], ic.column_id) in (''EntityId'', ''EntityVersionId'', ''OwnerEntityId'')
		and data_space_id = 1
	order by 1, 2';
go

exec [Tools].[P_DDL_Set_Test]
	'Joins on the primary key of a partitioned table must include PartitionKey',
	'select distinct OBJECT_SCHEMA_NAME(d.[object_id]) + ''.'' + OBJECT_NAME(d.[object_id]) as Table_Name
	from sys.sql_dependencies d
	join sys.index_columns ic on d.referenced_major_id = ic.[object_id] and d.referenced_minor_id = ic.column_id and ic.index_id = 1
	join sys.index_columns p on d.referenced_major_id = p.[object_id] and p.partition_ordinal = 1
	where d.[object_id] not in (SELECT [object_id] from sys.sql_dependencies where COL_NAME(referenced_major_id, referenced_minor_id) = ''PartitionKey'')
	order by 1';
go

exec [Tools].[P_DDL_Set_Test]
	'All tables below Entity should be partitioned',
	'select distinct OBJECT_SCHEMA_NAME(parent_object_id) + ''.'' + OBJECT_NAME(parent_object_id) as Table_Name
	from sys.foreign_keys fk
	join sys.indexes i on fk.parent_object_id = i.[object_id] and i.index_id = 1 and i.data_space_id = 1
	where referenced_object_id in (OBJECT_ID(''[Core].[Entity]''), OBJECT_ID(''[Core].[EntityVersion]''))
	order by 1';
go

exec [Tools].[P_DDL_Set_Test]
	'Indexes that have PKs to partitioned tables must also have PartitionKey',
	'select 
		OBJECT_SCHEMA_NAME(i.[object_id]) + ''.'' + OBJECT_NAME(i.[object_id]) as table_name, 
		i.[name]
	from sys.indexes i
	join sys.index_columns ic 
		on i.[object_id] = ic.[object_id] 
		and i.index_id = ic.index_id
		and COL_NAME(ic.[object_id], ic.column_id) in (''EntityId'', ''OwnerEntityId'', ''EntityversionId'')
		and ic.is_included_column = 0
	left join sys.index_columns icpk
		on ic.[object_id] = icpk.[object_id] 
		and ic.index_id = icpk.index_id
		and COL_NAME(icpk.[object_id], icpk.column_id) = ''PartitionKey''
		and icpk.is_included_column = 0
	where icpk.index_id is null
	order by 1, 2';
go

