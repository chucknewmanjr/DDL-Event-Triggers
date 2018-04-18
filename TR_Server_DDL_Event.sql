use master
go
/*
===== change  tracking =====
All schema changes in all databases are collected into the tools database
by a server level DDL trigger.
*/
/*
-- rollback
drop trigger if exists TR_Server_DDL_Event on all server;
drop table if exists tools.DDL_Event_Staging
drop table if exists tools.DDL_Event;
drop table if exists tools.DDL_Event_Ref;
drop table if exists tools.DDL_Event_Database;
drop table if exists tools.DDL_Event_Schema;
drop table if exists tools.DDL_Event_Object;
drop table if exists tools.DDL_Event_Object_Type;
drop proc if exists tools.p_Insert_DDL_Event;
drop proc if exists tools.p_Process_DDL_Event_Staging;
drop proc if exists tools.p_Get_DDL_Event_List_for_Object;
drop proc if exists tools.p_Rerun_DDL_Events;
drop view if exists tools.VW_DDL_Event;
drop view if exists tools.VW_DDL_Event_Object_List;
drop table if exists dbo.t;
drop proc if exists dbo.p_t;
select * from tools.sys.objects where is_ms_shipped = 0 and parent_object_id = 0 
*/
-- this trigger is server level. so i can drop it right at the top.
drop trigger if exists TR_Server_DDL_Event on all server;
go
if db_id('tools') is null exec ('create database tools');
go
ALTER DATABASE [tools] SET ANSI_NULLS ON, ANSI_PADDING ON, QUOTED_IDENTIFIER ON, CONCAT_NULL_YIELDS_NULL ON;
go
use tools;
go
if SCHEMA_ID('tools') is null exec ('create schema tools');
go

/* 
-- By truncating, the table gets dropped.
-- Useful if table def changes.
truncate table tools.DDL_Event_staging
*/
if OBJECT_ID('tools.DDL_Event_Staging') is not null
	if not exists (select * from tools.DDL_Event_Staging)
		drop table tools.DDL_Event_Staging
go

if OBJECT_ID('tools.DDL_Event_Staging') is null
	create table tools.DDL_Event_Staging (
		DDL_Event_ID int not null identity primary key clustered,
		DDL_Event_XML xml not null,
		Is_Processed bit not null default 0
	)
go

/* 
-- truncate if OK and table def changes.
truncate table tools.DDL_Event
*/
if OBJECT_ID('tools.DDL_Event') is not null begin
	if not exists (select * from tools.DDL_Event) begin
		drop table tools.DDL_Event;
		drop table if exists tools.DDL_Event_Ref;
		drop table if exists tools.DDL_Event_Database;
		drop table if exists tools.DDL_Event_Schema;
		drop table if exists tools.DDL_Event_Object;
		drop table if exists tools.DDL_Event_Object_Type;
	end
end
go

if OBJECT_ID('tools.DDL_Event') is null
	create table tools.DDL_Event (
		DDL_Event_ID int not null primary key clustered,
		Trigger_Event_Type int not null, 
		PostTime datetime not null, 
		SPID smallint not null, 
		DDL_Event_Ref_ID int not null, 
		DDL_Event_Database_ID int not null,
		DDL_Event_Schema_ID int not null,
		DDL_Event_Object_ID int not null,
		DDL_Event_Object_Type_ID int not null,
		AlterTableActionList xml null, 
		CommandText nvarchar(max) not null
	);
go

if OBJECT_ID('tools.DDL_Event_Ref') is null
	create table tools.DDL_Event_Ref (
		DDL_Event_Ref_ID int not null identity primary key clustered,
		ServerName sysname not null,
		LoginName sysname not null,
		UserName sysname not null,
		SetOptions nvarchar(4000) not null
	);
go

if OBJECT_ID('tools.DDL_Event_Database') is null
	create table tools.DDL_Event_Database (
		DDL_Event_Database_ID int not null identity primary key clustered,
		DatabaseName sysname not null
	);
go

if OBJECT_ID('tools.DDL_Event_Schema') is null
	create table tools.DDL_Event_Schema (
		DDL_Event_Schema_ID int not null identity primary key clustered,
		SchemaName sysname not null
	);
go

if OBJECT_ID('tools.DDL_Event_Object') is null
	create table tools.DDL_Event_Object (
		DDL_Event_Object_ID int not null identity primary key clustered,
		ObjectName sysname not null
	);
go

if OBJECT_ID('tools.DDL_Event_Object_Type') is null
	create table tools.DDL_Event_Object_Type (
		DDL_Event_Object_Type_ID int not null identity primary key clustered,
		ObjectType nvarchar(60) not null
	);
go

create or alter proc tools.p_Insert_DDL_Event @DDL_Event_ID int, @DDL_Event_XML xml as
	/*
	Usually called by tools.p_Process_DDL_Event_Staging.
	The XML originally comes from the EVENTDATA() function in a DDL trigger.
	This proc parses the XML and inserts it all into a table structure.
	*/
	set nocount on;

	declare
		@EventType nvarchar(64),
		@PostTime datetime,
		@SPID smallint,
		@ServerName sysname,
		@LoginName sysname,
		@UserName sysname,
		@DatabaseName sysname,
		@SchemaName sysname,
		@ObjectName sysname,
		@ObjectType nvarchar(60),
		@AlterTableActionList xml,
		@SetOptions nvarchar(4000),
		@CommandText nvarchar(max);

	select 
		@EventType = c.value('EventType[1]', 'nvarchar(64)'), 
		@PostTime = c.value('PostTime[1]', 'datetime'), 
		@SPID = c.value('SPID[1]', 'smallint'), 
		@ServerName = c.value('ServerName[1]', 'sysname'), 
		@LoginName = c.value('LoginName[1]', 'sysname'), 
		@UserName = c.value('UserName[1]', 'sysname'), 
		@DatabaseName = c.value('DatabaseName[1]', 'sysname'), 
		@SchemaName = c.value('SchemaName[1]', 'sysname'), 
		@ObjectName = c.value('ObjectName[1]', 'sysname'), 
		@ObjectType = c.value('ObjectType[1]', 'nvarchar(60)'), 
		@AlterTableActionList = c.query('AlterTableActionList/*'), 
		@SetOptions = cast(c.query('TSQLCommand/SetOptions') as nvarchar(4000)), 
		@CommandText = c.value('(TSQLCommand/CommandText)[1]', 'nvarchar(max)')
	from @DDL_Event_XML.nodes('EVENT_INSTANCE') t(c);

	if not exists (
		select * from tools.DDL_Event_Ref 
		where ServerName = @ServerName 
			and LoginName = @LoginName 
			and UserName = ISNULL(@UserName, '')
			and SetOptions = @SetOptions
	)
		insert tools.DDL_Event_Ref (ServerName, LoginName, UserName, SetOptions)
		values (@ServerName, @LoginName, ISNULL(@UserName, ''), @SetOptions);

	if not exists (select * from tools.DDL_Event_Database where DatabaseName = ISNULL(@DatabaseName, ''))
		insert tools.DDL_Event_Database (DatabaseName) values (ISNULL(@DatabaseName, ''));

	if not exists (select * from tools.DDL_Event_Schema where SchemaName = ISNULL(@SchemaName, ''))
		insert tools.DDL_Event_Schema (SchemaName) values (ISNULL(@SchemaName, ''));

	if not exists (select * from tools.DDL_Event_Object where ObjectName = ISNULL(@ObjectName, ''))
		insert tools.DDL_Event_Object (ObjectName) values (ISNULL(@ObjectName, ''));

	if not exists (select * from tools.DDL_Event_Object_Type where ObjectType = ISNULL(@ObjectType, ''))
		insert tools.DDL_Event_Object_Type (ObjectType) values (ISNULL(@ObjectType, ''));

	declare
		@Type int, 
		@DDL_Event_Ref_ID int, 
		@DDL_Event_Database_ID int,
		@DDL_Event_Schema_ID int,
		@DDL_Event_Object_ID int,
		@DDL_Event_Object_Type_ID int;

	select @Type = [type] from sys.trigger_event_types where [type_name] = @EventType;

	select @DDL_Event_Ref_ID = DDL_Event_Ref_ID 
	from tools.DDL_Event_Ref
	where ServerName = @ServerName and LoginName = @LoginName and UserName = ISNULL(@UserName, '') and SetOptions = @SetOptions;

	select @DDL_Event_Database_ID = DDL_Event_Database_ID from tools.DDL_Event_Database where DatabaseName = ISNULL(@DatabaseName, '');

	select @DDL_Event_Schema_ID = DDL_Event_Schema_ID from tools.DDL_Event_Schema where SchemaName = ISNULL(@SchemaName, '');

	select @DDL_Event_Object_ID = DDL_Event_Object_ID from tools.DDL_Event_Object where ObjectName = ISNULL(@ObjectName, '');

	select @DDL_Event_Object_Type_ID = DDL_Event_Object_Type_ID from tools.DDL_Event_Object_Type where ObjectType = ISNULL(@ObjectType, '');

	insert tools.DDL_Event (
		DDL_Event_ID, Trigger_Event_Type, PostTime, SPID, DDL_Event_Ref_ID, 
		DDL_Event_Database_ID, DDL_Event_Schema_ID, DDL_Event_Object_ID, 
		DDL_Event_Object_Type_ID, AlterTableActionList, CommandText
	) values (
		@DDL_Event_ID, @Type, @PostTime, @SPID, @DDL_Event_Ref_ID, 
		@DDL_Event_Database_ID, @DDL_Event_Schema_ID, @DDL_Event_Object_ID, 
		@DDL_Event_Object_Type_ID, @AlterTableActionList, @CommandText
	);
go

create or alter proc tools.p_Process_DDL_Event_Staging as
	/*
	Usually called by a DDL trigger.
	This proc spends just a fraction of a second to process 
	a few rows waiting in tools.DDL_Event_Staging. 
	*/
	set nocount on

	-- 100ms=1/10sec; 250ms=1/4sec; 10ms is too small
	declare 
		@Stop datetime2(7) = dateadd(millisecond, 50, sysdatetime()),
		@DDL_Event_ID int,
		@DDL_Event_XML xml

	while sysdatetime() < @Stop begin
		select top 1 
			@DDL_Event_ID = DDL_Event_ID, 
			@DDL_Event_XML = DDL_Event_XML 
		from tools.DDL_Event_Staging 
		where Is_Processed = 0 
		order by DDL_Event_ID

		if @@ROWCOUNT = 0 break

		exec tools.p_Insert_DDL_Event @DDL_Event_ID, @DDL_Event_XML

		update tools.DDL_Event_Staging set Is_Processed = 1 where DDL_Event_ID = @DDL_Event_ID
	end
go

-- This trigger got dropped at the very top of the script.
create or alter trigger TR_Server_DDL_Event on all server after DDL_EVENTS as
	/*
	This is a DDL trigger.
	"on all server after DDL_EVENTS" means it captures all DDL changes in the entire server.
	EVENTDATA() returns XML about.
	All this proc does is queue up the XML in DDL_Event_Staging.
	Fopefully, p_Process_DDL_Event_Staging processes it.
	If it fails, it doesn't cause the DDL instruction to fail.
	That's what xact_abort and the try-catch is for.
	*/
	set nocount on;

	set xact_abort off;

	begin try
		insert tools.tools.DDL_Event_Staging (DDL_Event_XML) values (EVENTDATA())

		exec tools.tools.p_Process_DDL_Event_Staging
	end try
	begin catch
	end catch
go

-- ------------------------------------------------------
create or alter view tools.VW_DDL_Event as
	select 
		e.DDL_Event_ID, 
		et.[type_name] as EventType, 
		e.PostTime, 
		e.SPID, 
		r.ServerName, 
		r.LoginName, 
		r.UserName, 
		d.DatabaseName, 
		s.SchemaName, 
		o.ObjectName, 
		ot.ObjectType, 
		e.AlterTableActionList, 
		r.SetOptions, 
		e.CommandText
	from tools.DDL_Event e
	join tools.DDL_Event_Ref r on e.DDL_Event_Ref_ID = r.DDL_Event_Ref_ID
	join sys.trigger_event_types et on e.Trigger_Event_Type = et.type
	join tools.DDL_Event_Database d on e.DDL_Event_Database_ID = d.DDL_Event_Database_ID
	join tools.DDL_Event_Schema s on e.DDL_Event_Schema_ID = s.DDL_Event_Schema_ID
	join tools.DDL_Event_Object o on e.DDL_Event_Object_ID = o.DDL_Event_Object_ID
	join tools.DDL_Event_Object_Type ot on e.DDL_Event_Object_Type_ID = ot.DDL_Event_Object_Type_ID;
go

-- ------------------------------------------------------
create or alter view tools.VW_DDL_Event_Object_List as
	/*
	select * from tools.VW_DDL_Event_Object_List
	*/
	SELECT 
		ObjectType,
		DatabaseName,
		SchemaName,
		case
			when ObjectName = '' then DatabaseName
			when OBJECT_ID('[' + SchemaName + '].[' + ObjectName + ']') is null then ObjectName
			else '[' + SchemaName + '].[' + ObjectName + ']'
		end as ObjectName,
		count(*) as EventCount,
		min(PostTime) as MinPostTime,
		max(PostTime) as MaxPostTime
	FROM tools.VW_DDL_Event
	group by ServerName, DatabaseName, SchemaName, ObjectName, ObjectType;
go

-- ------------------------------------------------------
create or alter proc tools.p_Get_DDL_Event_List_for_Object @DatabaseName sysname, @ObjectName sysname as
	/*
	Primarilly for an SSMS custom report developed in SSRS named "DDL Events.rdl".
	It expects 2 parameters (@DatabaseName & @ObjectName)
	and 5 columns in the results (DDL_Event_ID, PostTime, EventType, CommandText, LoginName)
	EXEC tools.p_Get_DDL_Event_List_for_Object 'Demos', 'Demos' -- database
	EXEC tools.p_Get_DDL_Event_List_for_Object 'tools', 'ix_t_id' -- index (no schema)
	EXEC tools.p_Get_DDL_Event_List_for_Object 'tools', '[dbo].[p_t]' -- proc
	EXEC tools.p_Get_DDL_Event_List_for_Object 'tools', '[dbo].[t]' -- table
	*/
	SELECT DDL_Event_ID, 
		PostTime, 
		EventType, 
		CommandText
		, LoginName
	FROM tools.VW_DDL_Event
	where DatabaseName = @DatabaseName
		and (
			'[' + SchemaName + '].[' + ObjectName + ']' = @ObjectName
			or ObjectName = @ObjectName
			or (ObjectName = '' and DatabaseName = @ObjectName)
		)
	order by DDL_Event_ID
go

-- ------------------------------------------------------
create or alter proc tools.p_Rerun_DDL_Events 
	@DatabaseName sysname, 
	@ObjectName sysname,
	@From_DDL_Event_ID int,
	@To_DDL_Event_ID int,
	@Is_Rollback bit = 1
as
	/*
	exec tools.p_Rerun_DDL_Events 'tools', '[dbo].[t]', 471, 474
	exec tools.p_Rerun_DDL_Events 'tools', 'ix_t_id', 475, 475
	exec tools.p_Rerun_DDL_Events 'tools', '[dbo].[t]', 471, 474, 0
	exec tools.p_Rerun_DDL_Events 'tools', 'ix_t_id', 475, 475, 0
	*/
	declare 
		@object_id int, 
		@SchemaName sysname = '', 
		@EventObjectName sysname = '', 
		@Object_Count int;

	set @object_id = OBJECT_ID('[' + @DatabaseName + '].' + @ObjectName);

	if @object_id is not null begin
		set @SchemaName = OBJECT_SCHEMA_NAME(@object_id);
		set @EventObjectName = OBJECT_NAME(@object_id);
	end else if @DatabaseName != @ObjectName begin
		set @EventObjectName = @ObjectName;
	end

	-- validation
	select @Object_Count = count(*)
	from (
		select distinct DatabaseName, SchemaName, ObjectName, ObjectType
		FROM tools.VW_DDL_Event
		where DatabaseName = @DatabaseName
			and SchemaName = iif(@SchemaName = '', SchemaName, @SchemaName)
			and ObjectName = @EventObjectName
	) t;

	if @Object_Count = 0
		throw 50000, 'Zero objects found. Check @ObjectName format. It is required. For objects in sys.objects, format is [schema].[object_name]. For all else, leave out schema and brackets.', 1;

	if @Object_Count = 0
		throw 50000, 'More than one object found. Check @ObjectName format. It is required. For objects in sys.objects, format is [schema].[object_name]. For all else, leave out schema and brackets.', 1;

	declare 
		@CommandText nvarchar(max),
		@ErrorNumber int,
		@ErrorMessage nvarchar(4000),
		@ErrorState int;

	declare EventCommand cursor for 
		select CommandText
		FROM tools.VW_DDL_Event
		where DatabaseName = @DatabaseName
			and SchemaName = iif(@SchemaName = '', SchemaName, @SchemaName)
			and ObjectName = @EventObjectName
			and DDL_Event_ID between @From_DDL_Event_ID and @To_DDL_Event_ID
		order by DDL_Event_ID;

	open EventCommand;

	fetch next from EventCommand into @CommandText;

	begin try
		begin tran
		while @@FETCH_STATUS = 0 begin
			print @CommandText;

			exec (@CommandText);

			fetch next from EventCommand into @CommandText;
		end

		if @Is_Rollback = 0 begin
			print '*** Done';
			commit;
		end else if @@TRANCOUNT > 0 begin
			print '*** All of these commands succeeded but were rolled back. See Is_Rollback parameter.';

			rollback;
		end

		close EventCommand;

		deallocate EventCommand;
	end try
	begin catch
		set @ErrorNumber = 50000 + ERROR_NUMBER();
		set @ErrorMessage = ERROR_MESSAGE();
		set @ErrorState = ERROR_STATE();

		rollback;

		close EventCommand;

		deallocate EventCommand;

		throw @ErrorNumber, @ErrorMessage, @ErrorState;
	end catch
go

-- ========================================================
-- ========================================================
-- this part is just to make some DDL changes

drop table if exists dbo.t;
go

create table dbo.t (
	id int
);
go

alter table dbo.t 
	alter column id varchar(10) not null;
go

alter table dbo.t 
	add constraint PKC_t primary key clustered (id);
go

create index ix_t_id 
	on dbo.t (id);
go

drop proc if exists dbo.p_t;
go

create proc dbo.p_t @id varchar(10) as
	select id 
	from dbo.t 
	where id = @id;
go

GRANT EXECUTE 
	ON dbo.p_t TO [guest];
GO

alter database Demos 
	set AUTO_CREATE_STATISTICS off;
go

alter database Demos 
	set AUTO_CREATE_STATISTICS on;
go

--drop table if exists dbo.t;
--go

--drop proc if exists dbo.p_t;
--go
