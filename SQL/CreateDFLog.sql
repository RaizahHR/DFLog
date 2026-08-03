/*
    Creates the default table used by cLogger.

    The script is idempotent and targets Microsoft SQL Server. If cLogger's
    psLogTable is changed, adjust [dbo].[DFLog] here to match.
*/
SET NOCOUNT ON;
SET XACT_ABORT ON;

IF OBJECT_ID(N'[dbo].[DFLog]', N'U') IS NULL
BEGIN
    CREATE TABLE [dbo].[DFLog]
    (
        [ID] bigint IDENTITY(1,1) NOT NULL,
        [LoggedAt] datetime2(3) NOT NULL,
        [Application] nvarchar(128) NOT NULL,
        [Category] nvarchar(128) NOT NULL,
        [Message] nvarchar(max) NOT NULL,
        [EventCode] int NOT NULL,
        [LogLevel] nvarchar(16) NOT NULL,
        [TraceId] nvarchar(128) NULL,
        [AdditionalData] nvarchar(max) NULL,
        CONSTRAINT [CK_DFLog_AdditionalData_IsJson]
            CHECK ([AdditionalData] IS NULL OR ISJSON([AdditionalData]) = 1),
        CONSTRAINT [PK_DFLog] PRIMARY KEY CLUSTERED ([ID] ASC)
    );
END;

IF COL_LENGTH(N'dbo.DFLog', N'LogLevel') IS NULL
BEGIN
    ALTER TABLE [dbo].[DFLog]
        ADD [LogLevel] nvarchar(16) NOT NULL
            CONSTRAINT [DF_DFLog_LogLevel] DEFAULT N'info' WITH VALUES;
END;

IF COL_LENGTH(N'dbo.DFLog', N'TraceId') IS NULL
BEGIN
    ALTER TABLE [dbo].[DFLog]
        ADD [TraceId] nvarchar(128) NULL;
END;

IF COL_LENGTH(N'dbo.DFLog', N'AdditionalData') IS NULL
BEGIN
    ALTER TABLE [dbo].[DFLog]
        ADD [AdditionalData] nvarchar(max) NULL;
END;

IF NOT EXISTS
(
    SELECT 1
    FROM sys.check_constraints
    WHERE [parent_object_id] = OBJECT_ID(N'[dbo].[DFLog]')
      AND [name] = N'CK_DFLog_AdditionalData_IsJson'
)
BEGIN
    ALTER TABLE [dbo].[DFLog] WITH CHECK
        ADD CONSTRAINT [CK_DFLog_AdditionalData_IsJson]
            CHECK ([AdditionalData] IS NULL OR ISJSON([AdditionalData]) = 1);
END;

IF OBJECT_ID(N'[dbo].[DFLog]', N'U') IS NOT NULL
   AND NOT EXISTS
   (
       SELECT 1
       FROM sys.indexes
       WHERE [object_id] = OBJECT_ID(N'[dbo].[DFLog]')
         AND [name] = N'IX_DFLog_LoggedAt'
   )
BEGIN
    CREATE INDEX [IX_DFLog_LoggedAt]
        ON [dbo].[DFLog] ([LoggedAt] DESC, [ID] DESC)
        INCLUDE ([Application], [Category], [EventCode]);
END;
