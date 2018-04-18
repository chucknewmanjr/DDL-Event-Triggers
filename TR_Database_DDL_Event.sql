if DB_NAME() = 'master' begin
	select * from sys.objects where is_ms_shipped = 0 and parent_object_id = 0;
	select object_name(object_id), * from sys.triggers;
	raiserror ('dont run this in master', 18, 1);
	return;
end
go
/*
===== Test Sweet =====
===== automatic unit testing =====
You add a test with tools.P_Set_Test_Sweet and it gets tested every time you make a DDL change.
That, of course, assumes you made a job and scheduled it in your SQL Server Agent.
The job contains 1 step that calls tools.P_Run_Test_Sweet.
Schedule it to run every few minutes.
Oh, and make sure the scheduler is running by right-clicking SQL Server Agent.
That proc doesn't test everything. It tests what it can in a fraction of a second. (.1?)

This is only a proof of consept.
Here's a trivial example of how to add a test.
	declare @Results varchar(max), @Test_Instructions nvarchar(max)
	set @Test_Instructions = N'set @Results = (select * from tools.Test_Sweet_Status for xml path(''x''));'
	exec tools.P_Get_Test_Results @Test_Instructions, @Results out
	exec tools.P_Set_Test_Sweet 'Test #1', @Test_Instructions, @Results;
*/

drop trigger if exists TR_Database_DDL_Event on database;
go

if SCHEMA_ID('tools') is null exec ('create schema tools');
go

-- ------------------------------------------------------------------
drop table if exists tools.Test_Sweet
go
create table tools.Test_Sweet (
	Test_Sweet_ID int not null identity primary key clustered,
	Test_Sweet_Name varchar(50) not null unique, 
	Status_ID tinyint not null default 0, 
	Tested_On datetime not null default sysdatetime(), 
	Test_Instructions nvarchar(max) not null, -- SQL that must set @Results
	Expected_Results varchar(max) not null, -- typically, XML
	Test_Results varchar(max) null -- typically, XML
)
go

-- ------------------------------------------------------------------
drop table if exists tools.Test_Sweet_Status
go
create table tools.Test_Sweet_Status (
	Status_ID tinyint not null,
	Status_Value varchar(20) not null
)
go
insert tools.Test_Sweet_Status (Status_ID, Status_Value) values 
	(1, 'Test'),
	(2, 'Disabled'),
	(3, 'Success'),
	(4, 'Failure')
go

-- ------------------------------------------------------------------
create or alter function tools.FN_Test_Sweet_Status_ID(@Status_Value varchar(20)) returns int as begin
	/*
	select * from tools.Test_Sweet where Status_ID != tools.FN_Test_Sweet_Status_ID('Success')
	*/
	return (select Status_ID from tools.Test_Sweet_Status where Status_Value = @Status_Value)
end
go

-- ------------------------------------------------------------------
create or alter function tools.FN_Test_Sweet_Status_Value(@Status_ID int) returns varchar(20) as begin
	/*
	select tools.FN_Test_Sweet_Status_Value(Status_ID), * from tools.Test_Sweet
	*/
	return (select Status_Value from tools.Test_Sweet_Status where Status_ID = @Status_ID)
end
go

-- ------------------------------------------------------------------
create or alter proc tools.P_Get_Test_Results @Test_Instructions nvarchar(max), @Results varchar(max) out as 
	/*
	Outputs the results of a test. Useful for setting up a test.
	declare @Results varchar(max)
	exec tools.P_Get_Test_Results N'set @Results = (select * from tools.Test_Sweet_Status for xml path(''x''));', @Results out
	select @Results
	*/
	exec sp_executesql @Test_Instructions, N'@Results varchar(max) out', @Results=@Results out;
go

-- ------------------------------------------------------------------
create or alter proc tools.P_Set_Test_Sweet 
	@Test_Sweet_Name varchar(50), 
	@Test_Instructions nvarchar(max), 
	@Expected_Results varchar(max)
as 
	/*
	Inserts or updates a row in the Test_Sweet table.

	declare @Results varchar(max), @Test_Instructions nvarchar(max)
	set @Test_Instructions = N'set @Results = (select * from tools.Test_Sweet_Status for xml path(''x''));'
	exec tools.P_Get_Test_Results @Test_Instructions, @Results out
	exec tools.P_Set_Test_Sweet 'Test #1', @Test_Instructions, @Results;
	*/
	merge tools.Test_Sweet as targt
	using (
		values (@Test_Sweet_Name, @Test_Instructions, @Expected_Results)
	) as sourc (Test_Sweet_Name, Test_Instructions, Expected_Results)
	on targt.Test_Sweet_Name = sourc.Test_Sweet_Name
	when matched then 
		update set Test_Instructions=sourc.Test_Instructions, Expected_Results=sourc.Expected_Results, Status_ID = tools.FN_Test_Sweet_Status_ID('Test')
	when not matched then 
		insert (Test_Sweet_Name, Test_Instructions, Expected_Results) 
		values (sourc.Test_Sweet_Name, sourc.Test_Instructions, sourc.Expected_Results);
go

exec tools.P_Set_Test_Sweet 'Test Sweet Happy Path Test', 'set @Results = ''1''', '1';
go

exec tools.P_Set_Test_Sweet 'Test Sweet Failure Test', 'set @Results = ''1''', '2';
go

declare @Results varchar(max), @The_Test nvarchar(max)

set @The_Test = N'set @Results = (select name, type_desc from sys.objects where name like ''%Test_Sweet%'' for xml path(''x''));';

-- run the test to get the results
exec tools.P_Get_Test_Results @The_Test, @Results out

-- use the test and the results to make a test in the test sweet
exec tools.P_Set_Test_Sweet 'Test Sweet Test 3', @The_Test, @Results;
go

declare @Results varchar(max), @The_Test nvarchar(max)
set @The_Test = N'set @Results = (select tools.FN_Test_Sweet_Status_ID(Status_Value), tools.FN_Test_Sweet_Status_Value(Status_ID) from tools.Test_Sweet_Status for xml path(''x''));'
exec tools.P_Get_Test_Results @The_Test, @Results out
exec tools.P_Set_Test_Sweet 'Test Sweet Test 4', @The_Test, @Results;
go

-- ------------------------------------------------------------------
create or alter trigger TR_Database_DDL_Event on database after DDL_DATABASE_LEVEL_EVENTS as
	/*
	This trigger is dropped way up at the top.
	This trigger fires for all database level DDL events.
	It sets all the tests in the test sweet to get tested again.
	*/
	set nocount on;

	set xact_abort off;

	begin try
		update tools.Test_Sweet 
		set Status_ID = tools.FN_Test_Sweet_Status_ID('Test') 
		where Status_ID != tools.FN_Test_Sweet_Status_ID('Disabled')
	end try
	begin catch
	end catch
go

-- ------------------------------------------------------------------
create or alter proc tools.P_Run_Test_Sweet as
	/*
	This proc runs the tests.
	It's intended to be called by a scheduled job.
	It's limited to a fraction of a second.
	1000 = 1 second; 100 = 1/10 of a second.
	exec tools.P_Run_Test_Sweet
	*/
	declare 
		@Stop datetime = dateadd(millisecond, 1000, sysdatetime()),
		@Test_Sweet_ID varchar(max),
		@Test_Instructions nvarchar(max),
		@Results varchar(max);

	while sysdatetime() < @Stop begin
		select top 1
			@Test_Sweet_ID = Test_Sweet_ID,
			@Test_Instructions = Test_Instructions
		from tools.Test_Sweet 
		where Status_ID in (
				select Status_ID 
				from tools.Test_Sweet_Status 
				where Status_Value not in ('Disabled', 'Success', 'Failure')
			)

		if @@ROWCOUNT < 1 break; -- nothing left to do

		exec tools.P_Get_Test_Results @Test_Instructions, @Results out

		update tools.Test_Sweet 
		set Test_Results = @Results,
			Status_ID = 
				case
					when @Results = Expected_Results
					then tools.FN_Test_Sweet_Status_ID('Success')
					else tools.FN_Test_Sweet_Status_ID('Failure')
				end,
			Tested_On = sysdatetime()
		where Test_Sweet_ID = @Test_Sweet_ID;
	end
go

-- ------------------------------------------------------------------
create or alter view tools.VW_Test_Sweet_Dashboard as
	/*
	select * from tools.VW_Test_Sweet_Dashboard
	*/
	select 
		tools.FN_Test_Sweet_Status_Value(Status_ID) as [Status],
		count(*) as Tests,
		min(Tested_On) as Oldest_Test,
		min(Tested_On) as Latest_Test
	from tools.Test_Sweet
	group by Status_ID
go

-- ------------------------------------------------------------------
create or alter view tools.VW_Test_Sweet as
	/*
	select * from tools.VW_Test_Sweet
	*/
	SELECT 
		Test_Sweet_ID,
		Test_Sweet_Name,
		tools.FN_Test_Sweet_Status_Value(Status_ID) as Status_Value,
		Tested_On,
		Test_Instructions,
		Expected_Results,
		Test_Results
	FROM tools.Test_Sweet
go
