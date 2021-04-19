/*
	disable trigger [TR_DDL_Event] on database;
	-- enable trigger [TR_DDL_Event] on database;
	drop trigger if exists [TR_DDL_Event] on database;
	drop function if exists [Tools].[FN_DDL_Test_Status_ID]
	drop proc if exists [Tools].[P_DDL_Update_Test_Expected_Results_to_Current_Results]
	drop proc if exists [Tools].[P_DDL_Output_Table]
	drop proc if exists [Tools].[P_DDL_Set_Test]
	drop proc if exists [Tools].[P_DDL_Test]
	drop view if exists [Tools].[VW_DDL_Test]
	drop view if exists [Tools].[VW_DDL_Event]
	drop table if exists [Tools].[DDL_Test];
	/*
		drop table if exists [Tools].[DDL_Event];        -- <== DANGER! Loss of data
		drop table if exists [Tools].[DDL_Event_Object]; -- <== DANGER! Loss of data
		drop table if exists [Tools].[DDL_Event_User];   -- <== DANGER! Loss of data
	*/
	drop schema if exists [Tools]
*/

-- drop the trigger so that it doesn't fire while running this script.
if exists (select * from sys.triggers where name = 'TR_DDL_Event' and parent_class_desc = 'DATABASE')
	drop trigger if exists [TR_DDL_Event] ON DATABASE;
go

if SCHEMA_ID('Tools') is null exec ('create schema [Tools] authorization [dbo]');
go

if OBJECT_ID('[Tools].[DDL_Test]') is not null begin
	if not exists (select * from [Tools].[DDL_Test]) begin
		drop table [Tools].DDL_Test;
	end
end
go

-- There's a FK from test to event. So only drop event if there's no test table.
if OBJECT_ID('[Tools].[DDL_Test]') is null
	and OBJECT_ID('[Tools].[DDL_Event]') is not null
begin
	if not exists (select * from [Tools].[DDL_Event]) begin
		drop table [Tools].[DDL_Event];
	end
end
go

-- Event has FKs to both object and user.
if OBJECT_ID('[Tools].[DDL_Event]') is null begin
	if OBJECT_ID('[Tools].[DDL_Event_Object]') is not null begin
		drop table [Tools].[DDL_Event_Object];
	end

	if OBJECT_ID('[Tools].[DDL_Event_User]') is not null begin
		drop table [Tools].[DDL_Event_User];
	end
end
go

if OBJECT_ID('[Tools].[DDL_Event_User]') is null
	create table [Tools].[DDL_Event_User] (
		DDL_Event_User_ID int not null identity
			constraint PK_Tools_DDL_Event_User primary key clustered,
		Login_Name sysname null,
		[User_Name] sysname null,
		constraint UX_Tools_DDL_Event_User
			unique (Login_Name, [User_Name])
	);
go

if OBJECT_ID('[Tools].[DDL_Event_Object]') is null
	create table [Tools].[DDL_Event_Object] (
		DDL_Event_Object_ID int not null identity
			constraint PK_Tools_DDL_Event_Object primary key clustered,
		[Schema_Name] sysname null,
		[Object_Name] sysname null,
		constraint UX_Tools_DDL_Event_Object
			unique ([Schema_Name], [Object_Name])
	);
go

if OBJECT_ID('[Tools].[DDL_Event]') is null
	create table [Tools].[DDL_Event] (
		DDL_Event_ID int not null identity
			constraint PK_Tools_DDL_Event primary key clustered,
		Trigger_Event_Type int null,
		Post_Time datetime null, -- local
		DDL_Event_User_ID int null
			constraint FK_Tools_DDL_Event_User_ID
			references [Tools].[DDL_Event_User] (DDL_Event_User_ID),
		DDL_Event_Object_ID int null
			constraint FK_Tools_DDL_Event_Object_ID
			references [Tools].[DDL_Event_Object] (DDL_Event_Object_ID),
		Alter_Table_Action_List xml null,
		Command_Text nvarchar(MAX) null,
		Event_Data XML null,
		Error_Msg nvarchar(MAX) null
	);
go

if COLUMNPROPERTY(OBJECT_ID('[Tools].[DDL_Event]'), 'Command_Text', 'Precision') <> -1
	alter table [Tools].[DDL_Event] alter column Command_Text nvarchar(MAX) null
go

if COLUMNPROPERTY(OBJECT_ID('[Tools].[DDL_Event]'), 'Error_Msg', 'AllowsNull') is null
	alter table [Tools].[DDL_Event] add Error_Msg nvarchar(MAX) null
go

if OBJECT_ID('[Tools].[DDL_Test]') is null begin
	create table [Tools].[DDL_Test] (
		DDL_Test_ID int not null identity
			constraint PK_Tools_DDL_Test primary key clustered,
		Failure_Message varchar(450) not null
			constraint UX_Tools_DDL_Test_Failure_Message unique,
		Instructions varchar(MAX) not null, -- SQL that must set @Results
		Is_XML_Results bit not null constraint DF_Tools_DDL_Test_Is_XML_Results default 1,
		Expected_Results varchar(MAX) null, -- typically, XML
		Status_ID tinyint not null constraint DF_Tools_DDL_Test_Status_ID default 0, -- 0 means To-Do
		Tested_On datetime null,
		Elapsed_Milliseconds int null,
		DDL_Event_ID int null
			constraint FK_Tools_DDL_Test_DDL_Event_ID
			references [Tools].[DDL_Event] (DDL_Event_ID),
		Last_Successful_DDL_Event_ID int null
			constraint FK_Tools_DDL_Test_Last_Successful_DDL_Event_ID
			references [Tools].[DDL_Event] (DDL_Event_ID),
		Results varchar(MAX) null -- typically, XML
	);
end
go

if COLUMNPROPERTY(OBJECT_ID('[Tools].[DDL_Test]'), 'Is_XML_Results', 'AllowsNull') is null
	alter table [Tools].[DDL_Test] 
	add Is_XML_Results bit not null default 1;
go

if COLUMNPROPERTY(OBJECT_ID('[Tools].[DDL_Test]'), 'Last_Successful_DDL_Event_ID', 'AllowsNull') is null
	alter table [Tools].[DDL_Test] 
	add Last_Successful_DDL_Event_ID int null
	constraint FK_Tools_DDL_Test_Last_Successful_DDL_Event_ID
	references [Tools].[DDL_Event] (DDL_Event_ID);
go

-- ----------------------------------------------------------------
drop proc if exists  [Tools].[P_Update_Test_Expected_Results_to_Current_Results]
go

-- Rather than getting the XML results yourself,
-- this proc gets the results for you.
-- Plus, this proc is used in [Tools].[P_DDL_Set_Test].
--     EXEC [Tools].[P_DDL_Update_Test_Expected_Results_to_Current_Results] @Failure_Message='Incorrect filegroup'
create or alter proc [Tools].[P_DDL_Update_Test_Expected_Results_to_Current_Results]
	@DDL_Test_ID int = null,
	@Failure_Message varchar(450) = null
as
	declare
		@Test_Instructions nvarchar(MAX),
		@Is_XML_Results bit,
		@Test_Results_Outside varchar(MAX);

	set nocount on;

	if @Failure_Message is not null
		select @DDL_Test_ID=DDL_Test_ID
		from [Tools].[DDL_Test]
		where Failure_Message = @Failure_Message

	select 
		@Test_Instructions = Instructions,
		@Is_XML_Results = Is_XML_Results
	from [Tools].[DDL_Test]
	where DDL_Test_ID = @DDL_Test_ID;

	if @Is_XML_Results = 1
		set @Test_Instructions = 'set @Results = (' + @Test_Instructions + ' for xml path)';;

	exec sp_executesql
		@Test_Instructions,
		N'@Results varchar(MAX) out',
		@Results=@Test_Results_Outside out;

	update [Tools].[DDL_Test]
	set Expected_Results = @Test_Results_Outside
	where DDL_Test_ID = @DDL_Test_ID;
go

-- ----------------------------------------------------------------
drop proc if exists [Tools].[P_Set_Test]
go

-- Inserts or updates [Tools].[DDL_Test].
-- By default, it will update the test if it exists.
-- If you want it to fail if the test already exists, set @Is_Insert_or_Update = to 0.
-- If you leave @Expected_Results = to NULL, it gets the current results and uses that.
create or alter proc [Tools].[P_DDL_Set_Test]
	@Failure_Message varchar(450),
	@Instructions varchar(MAX),
	@Is_XML_Results bit = 1,
	@Expected_Results varchar(MAX) = NULL,
	@Is_Insert_or_Update bit = 1
as
	declare @Row_Count int = 0;

	set nocount on;

	if @Is_Insert_or_Update = 1 begin
		update [Tools].[DDL_Test]
		set Instructions = @Instructions, Expected_Results = @Expected_Results
		where Failure_Message = @Failure_Message;

		set @Row_Count = @@ROWCOUNT;
	end

	if @Row_Count = 0 begin
		insert [Tools].[DDL_Test] (Failure_Message, Instructions, Expected_Results)
		values (@Failure_Message, @Instructions, @Expected_Results);

		if @@ROWCOUNT = 0 begin;
			THROW 50000, 'P_DDL_Set_Test failed', 1;
		end
	end

	if @Expected_Results is null
		exec [Tools].[P_DDL_Update_Test_Expected_Results_to_Current_Results] @Failure_Message=@Failure_Message
go

-- ----------------------------------------------------------------
-- select * from [Tools].[DDL_Test] where Status_ID != [Tools].[FN_DDL_Test_Status_ID]('Success')
create or alter function [Tools].[FN_DDL_Test_Status_ID](@Status_Value varchar(20)) returns tinyint as begin
	return (
		select Status_ID
		from (values 
			(0, 'To-Do'),
			(1, 'Disabled'),
			(2, 'Success'),
			(3, 'Failure')
		) t (Status_ID, Status_Value)
		where Status_Value = @Status_Value
	);
end
go

-- ----------------------------------------------------------------
-- select * from [Tools].[VW_DDL_Event]
create or alter view [Tools].[VW_DDL_Event] as
	SELECT 
		e.DDL_Event_ID,
		tet.[type_name],
		e.Post_Time,
		u.Login_Name,
		u.[User_Name],
		o.[Schema_Name] + '.' + o.[Object_Name] as [Object_Name],
		isnull(e.Command_Text, e.Error_Msg) as Command_Text,
		isnull(e.Alter_Table_Action_List, e.Event_Data) as Alter_Table_Action_List
	FROM [Tools].[DDL_Event] e
	left join sys.trigger_event_types tet on e.Trigger_Event_Type = tet.[type]
	left join [Tools].[DDL_Event_User] u on e.DDL_Event_User_ID = u.DDL_Event_User_ID
	left join [Tools].[DDL_Event_Object] o on e.DDL_Event_Object_ID = o.DDL_Event_Object_ID
	where tet.type_name not in ('GRANT_DATABASE', 'REVOKE_DATABASE')
go

-- ----------------------------------------------------------------
-- select * from [Tools].[VW_DDL_Test]
create or alter view [Tools].[VW_DDL_Test] as
	select
		DDL_Test_ID
		,t.Failure_Message
		,t.Instructions
		,t.Is_XML_Results
		,t.Expected_Results
		,tsv.Status_Value
		,t.Tested_On
		,t.Elapsed_Milliseconds
		,t.DDL_Event_ID
		,t.Results
		,e.[type_name]
		,e.Post_Time
		,e.Login_Name
		,e.[User_Name]
		,e.[Object_Name]
		,e.Command_Text
		,e.Alter_Table_Action_List
	from [Tools].[DDL_Test] t
	join (
		values (0, 'To-Do'), (1, 'Disabled'), (2, 'Success'), (3, 'Failure')
	) tsv (Status_ID, Status_Value) on t.Status_ID = tsv.Status_ID
	left join [Tools].[VW_DDL_Event] e on t.Last_Successful_DDL_Event_ID + 1 = e.DDL_Event_ID
go

-- ----------------------------------------------------------------
drop proc if exists [Tools].[P_Output_Table] 
go

-- exec [Tools].[P_DDL_Output_Table] 1, '<row><a>1</a><b>2</b></row><row><a>3</a><b>4</b></row>', 'test';
create or alter proc [Tools].[P_DDL_Output_Table] 
	@Is_XML_Results bit,
	@XML xml,
	@Source sysname
as
	set nocount on;

	if @Is_XML_Results = 0 or @XML is null begin
		select @Source as [Source], @XML as Results;

		return
	end

	declare @Row table (Row_Num int identity, Row_XML xml);

	insert @Row (Row_XML)
	select c.query('.')
	from @XML.nodes('row') t(c);

	select r.Row_Num, c.value('local-name(.)', 'sysname') as Column_Name, c.value('.', 'sysname') as Val
	into #unpivot
	from @Row r
	cross apply r.Row_XML.nodes('row/*') t(c);

	declare @sql nvarchar(MAX) = '';

	select @sql = @sql + ', MIN(IIF(Column_Name=''' + Column_Name + ''', Val, NULL)) as ' + Column_Name
	from #unpivot
	group by Column_Name;

	set @sql = 'select ''' + @Source + ''' as Source' + @sql + ' from #unpivot group by Row_Num;';

	set ansi_warnings off;

	exec (@sql);
go

-- ----------------------------------------------------------------
-- EXEC @Status_ID = [Tools].[P_DDL_Run_Test] @DDL_Test_ID=1, @DDL_Event_ID=NULL
create or alter proc [Tools].[P_DDL_Run_Test] 
	@DDL_Test_ID int,
	@DDL_Event_ID int = NULL
as
	set nocount on;

	declare 
		@Is_XML_Results bit,
		@Test_Instructions nvarchar(MAX),
		@Expected_Results varchar(MAX),
		@Test_Started datetime = SYSDATETIME(),
		@Test_Results_Outside varchar(MAX),
		@Existing_Status_ID tinyint,
		@New_Status_ID tinyint,
		@Success_Status_ID tinyint = [Tools].[FN_DDL_Test_Status_ID]('Success'),
		@Failure_Status_ID tinyint = [Tools].[FN_DDL_Test_Status_ID]('Failure');

	select
		@Is_XML_Results = Is_XML_Results,
		@Test_Instructions = Instructions,
		@Expected_Results = Expected_Results,
		@Existing_Status_ID = Status_ID
	from [Tools].[DDL_Test]
	where DDL_Test_ID = @DDL_Test_ID;

	if @Is_XML_Results = 1
		set @Test_Instructions = 'set @Results = (' + @Test_Instructions + ' for xml path)';

	exec sp_executesql
		@Test_Instructions,
		N'@Results varchar(MAX) out',
		@Results=@Test_Results_Outside out;

	set @New_Status_ID = IIF(
		exists (SELECT @Test_Results_Outside INTERSECT SELECT @Expected_Results), 
		@Success_Status_ID, 
		@Failure_Status_ID
	);

	if @Existing_Status_ID <> [Tools].[FN_DDL_Test_Status_ID]('Disabled')
		update [Tools].[DDL_Test]
		set Status_ID = @New_Status_ID,
			Tested_On = @Test_Started,
			Elapsed_Milliseconds = DATEDIFF(millisecond, @Test_Started, SYSDATETIME()),
			DDL_Event_ID = ISNULL(@DDL_Event_ID, DDL_Event_ID),
			Results = @Test_Results_Outside,
			Last_Successful_DDL_Event_ID = IIF(
				@New_Status_ID = @Success_Status_ID,
				ISNULL(@DDL_Event_ID, Last_Successful_DDL_Event_ID),
				Last_Successful_DDL_Event_ID
			)
		where DDL_Test_ID = @DDL_Test_ID;

	return @New_Status_ID;
go

-- ----------------------------------------------------------------
-- EXEC [Tools].[P_DDL_Test] 1
create or alter proc [Tools].[P_DDL_Test] @DDL_Test_ID int as
	set nocount on;

	EXEC [Tools].[P_DDL_Run_Test] @DDL_Test_ID

	select
		DDL_Test_ID,
		Failure_Message,
		Status_Value,
		[type_name],
		Login_Name,
		[Object_Name],
		Command_Text,
		Alter_Table_Action_List,
		Instructions as Test_Instructions
	from [Tools].[VW_DDL_Test]
	WHERE DDL_Test_ID = @DDL_Test_ID;

	declare 
		@Is_XML_Results bit,
		@Results varchar(MAX),
		@Expected_Results varchar(MAX);

	select
		@Is_XML_Results=Is_XML_Results,
		@Expected_Results=Expected_Results,
		@Results=Results
	from [Tools].[VW_DDL_Test]
	WHERE DDL_Test_ID = @DDL_Test_ID;

	exec [Tools].[P_DDL_Output_Table] @Is_XML_Results, @Results, 'Current Results'

	exec [Tools].[P_DDL_Output_Table] @Is_XML_Results, @Expected_Results, 'Expected Results'

	select CONCAT('If the current results are correct, EXEC [Tools].[P_DDL_Update_Test_Expected_Results_to_Current_Results] @DDL_Test_ID=', @DDL_Test_ID) as TIP
go

-- ----------------------------------------------------------------
-- This trigger fires for any change to the schema in this database.
-- It does 2 things:
-- 1 - Records the schema change in [Tools].[DDL_Event]
-- 2 - Runs all the tests (test suite) in [Tools].[DDL_Test]
create or alter trigger [TR_DDL_Event] on database after DDL_DATABASE_LEVEL_EVENTS as
	set nocount on;

	set xact_abort off;

	declare 
		@Event_Data XML = EVENTDATA(),
		@Event_Type_Name nvarchar(64),
		@Post_Time datetime,
		@Login_Name sysname,
		@User_Name sysname,
		@Schema_Name sysname,
		@Object_Name sysname,
		@Alter_Table_Action_List xml,
		@Command_Text nvarchar(2000);

	--select @Event_Data

	begin try
		select
			@Event_Type_Name = c.value('EventType[1]', 'nvarchar(64)'),
			@Post_Time = c.value('PostTime[1]', 'datetime'),
			@Login_Name = c.value('LoginName[1]', 'sysname'),
			@User_Name = c.value('UserName[1]', 'sysname'),
			@Schema_Name = c.value('SchemaName[1]', 'sysname'),
			@Object_Name = c.value('ObjectName[1]', 'sysname'),
			@Alter_Table_Action_List = c.query('AlterTableActionList/*'),
			@Command_Text = LEFT(c.value('(TSQLCommand/CommandText)[1]', 'nvarchar(MAX)'), 2000)
		from @Event_Data.nodes('EVENT_INSTANCE') t(c);

		insert [Tools].[DDL_Event_User] (Login_Name, [User_Name])
		select @Login_Name, @User_Name
		except
		select Login_Name, [User_Name] from [Tools].[DDL_Event_User];

		insert [Tools].[DDL_Event_Object] ([Schema_Name], [Object_Name])
		select @Schema_Name, @Object_Name
		except
		select [Schema_Name], [Object_Name] from [Tools].[DDL_Event_Object];

		insert [Tools].[DDL_Event] (
			Trigger_Event_Type,
			Post_Time,
			DDL_Event_User_ID,
			DDL_Event_Object_ID,
			Alter_Table_Action_List,
			Command_Text
		)
		select 
			t.[type],
			@Post_Time,
			u.DDL_Event_User_ID,
			o.DDL_Event_Object_ID,
			@Alter_Table_Action_List,
			@Command_Text
		from sys.trigger_event_types t
		cross join [Tools].[DDL_Event_User] u
		cross join [Tools].[DDL_Event_Object] o
		where t.[type_name] = @Event_Type_Name
			and u.Login_Name = @Login_Name and u.[User_Name] = @User_Name
			and o.[Schema_Name] = @Schema_Name and o.[Object_Name] = @Object_Name;

		declare @DDL_Event_ID int = SCOPE_IDENTITY();

		-- =======================
		-- ===== test suite! =====
		declare
			@DDL_Test_ID int,
			@Failure_Message nvarchar(450),
			@Loop_Started datetime = SYSDATETIME(),
			@Status_ID tinyint;

		declare @Test table (Enum int identity, DDL_Test_ID int);

		insert @Test (DDL_Test_ID)
		select DDL_Test_ID from [Tools].[DDL_Test]
		where Status_ID <> [Tools].[FN_DDL_Test_Status_ID]('Disabled')
		order by Tested_On desc;

		declare @This int = (select MAX(Enum) from @Test);

		while @This > 0 begin
			begin try
				select @DDL_Test_ID = DDL_Test_ID from @Test where Enum = @This;

				select
					@Failure_Message = Failure_Message,
					@Event_Type_Name = [type_name],
					@Post_Time = Post_Time,
					@Login_Name = Login_Name,
					@Object_Name = [Object_Name]
				from [Tools].[VW_DDL_Test]
				where DDL_Test_ID = @DDL_Test_ID;

				EXEC @Status_ID = [Tools].[P_DDL_Run_Test] @DDL_Test_ID=@DDL_Test_ID, @DDL_Event_ID=@DDL_Event_ID

				if @Status_ID = [Tools].[FN_DDL_Test_Status_ID]('Failure') begin
					print CONCAT(
						'WARNING: ', @Failure_Message, 
						IIF(@Login_Name is null, '', 
							'. ' + @Login_Name + 
							' ' + FORMAT(@Post_Time, 'M/d/yy h:mmtt') + 
							' ' + @Event_Type_Name + 
							' ' + @Object_Name
						), 
						'; For more, EXEC [Tools].[P_DDL_Test] ', @DDL_Test_ID, ';'
					);
				end
			end try
			begin catch
				print CONCAT(ERROR_PROCEDURE(), ' #', ERROR_NUMBER(), ' line:', ERROR_LINE(), ' -- ', ERROR_MESSAGE());
			end catch

			if DATEDIFF(millisecond, @Loop_Started, SYSDATETIME()) > 1000 break;

			set @This -= 1;
		end
	end try
	begin catch
		declare @Error_Msg nvarchar(MAX) = CONCAT(ERROR_PROCEDURE(), ' line ', ERROR_LINE(), ': ', ERROR_MESSAGE());

		insert [Tools].[DDL_Event] (Event_Data, Error_Msg) values (@Event_Data, @Error_Msg);
	end catch
go

