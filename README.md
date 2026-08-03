# DFLog

`cLogger` writes the same log entry to any combination of:

- a SQL Server table;
- an ECS-compatible UTF-8 JSON Lines file;
- the Windows Application event log.

Logging errors are captured in `psLastError` and sent to `OnLogError`. They do
not replace the application's error handler or leave the global `Err` flag
changed.

Deterministic programming/configuration errors are additionally reported with
DataFlex's native `Error DFERR_PROGRAM` command. Set `pbDebugErrorsEnabled` to
`False` to keep those errors silent while still capturing them in
`psLastError` and `OnLogError`.

`cLogger` is only the public API and lifecycle owner. `InitLogger` dynamically
creates the enabled workers and stores them in `phoLoggerDatabase`,
`phoLoggerFile`, and `phoLoggerEventLog`. Calling `InitLogger` again copies
changed settings to existing workers and destroys workers that were disabled.

The implementation is split by responsibility:

- `cLogger.pkg` — public singleton API and dispatch;
- `cLoggerDatabase.pkg` — DDO/SQLExecutor persistence and table setup;
- `cLoggerFile.pkg` — folder, file naming, and sequential output;
- `cLoggerEventLog.pkg` — Windows Application event-log dispatch;
- `cLoggerWorker.pkg` — the small shared worker/error contract.

## Basic use

Add the DFLog `AppSrc` folder to the consuming workspace's AppSrcPath, then
create the logger after the application/connection objects:

```dataflex
Use cLogger.pkg

Object oLogger is a cLogger
    Set psApplicationName to "Package Manager Server"
    Set piLogLevel to DFLOG_INFO

    Set pbWriteToDatabase to True
    Set psConnectionId to "PkgMngrSrvr"
    Set psLogTable to "dbo.DFLog"

    Set pbWriteToFile to True
    Set psLogFolderPath to "Logs" // relative to the workspace root

    Set pbWriteToEventLog to True
End_Object

Send LogMessage of oLogger "Startup" "The application started." 100 DFLOG_INFO
Send WriteLog of oLogger (CurrentDateTime()) "package.push" "Package rejected." 200 DFLOG_ERRORS "optional-trace-id"
```

`piLogLevel` controls verbosity for every enabled sink: `DFLOG_NONE`,
`DFLOG_ERRORS`, `DFLOG_WARNINGS`, or `DFLOG_INFO`. The penultimate `WriteLog`
or `LogMessage` argument is the message level and the final optional argument
is the trace ID. A message is written only when `piLogLevel` is greater than or
equal to its level. Calls that omit both default to `DFLOG_INFO` with no trace
ID.

The same message level becomes the Windows event type and the ECS `log.level`:
errors are `error`, warnings are `warning`, and informational messages are
`info`.

Properties set inside the object declaration are applied before the automatic
`InitLogger` call. If configuration changes later at runtime, send
`InitLogger` once to resynchronize the workers.

When `pbLogToSingleFile` is false (the default), files are named
`DFLog-yyyy-mm-dd.jsonl`. Every physical line is one independent JSON object:

```json
{"@timestamp":"2026-08-03T10:45:36.659","message":"Validating archive","ecs":{"version":"9.4.0"},"log":{"level":"info"},"service":{"name":"Package Manager Server"},"event":{"action":"package.push","code":"100"},"trace":{"id":"czztwloaodiclxmuhxygpmtcypaxftlt"}}
```

This is a deliberately small ECS subset rather than an implementation of the
entire schema. `sCategory` maps to `event.action`, `iCode` to `event.code`, and
the optional final argument to `trace.id`. JSON serialization escapes quotes,
tabs, and line endings without changing the original message value.

`@timestamp` preserves the supplied DataFlex `DateTime` in ISO 8601 form with
milliseconds. DataFlex `DateTime` values carry no time-zone information, so no
offset is invented; configure the source time zone in the ingest pipeline if
UTC timestamps are required.

## Database setup

Run [`SQL/CreateDFLog.sql`](SQL/CreateDFLog.sql) against the target database.
The script is safe to run repeatedly and adds `LogLevel` and `TraceId` to an
existing DFLog table. Run it before deploying this version. `pbAutoCreateTable`
also lets the logger create a missing table at startup, but production
identities should normally receive only `INSERT` permission and use the script
during deployment.

The default table is `dbo.DFLog`. A custom `psLogTable` accepts only
`Table` or `Schema.Table` names made from letters, digits, and underscores.
Values are always sent as prepared SQL parameters.

As an alternative to SQLExecutor, set `phoLogDataDictionary` to a dedicated DDO
whose main table has these fields:

- `LoggedAt`
- `Application`
- `Category`
- `Message`
- `EventCode`

The optional DDO fields `LogLevel` and `TraceId` are populated when present.
The SQL table always contains them. These relational columns map to the JSON
fields as follows: `LoggedAt` to `@timestamp`, `Application` to `service.name`,
`Category` to `event.action`, `EventCode` to `event.code`, `LogLevel` to
`log.level`, and `TraceId` to `trace.id`. The fixed ECS version belongs to the
file contract and is not repeated in every database row.

The DDO path is useful when a consuming application already maintains a DF/INT
table definition. Override `GetDefaultLogDataDictionary` or
`OnGetLogDdoHandle` to supply it lazily.

## Windows Application event log

Set `pbWriteToEventLog` to `True` to write entries to **Windows Event Viewer >
Windows Logs > Application**. The logger application name is used as the event
source. Entries are written as native Information, Warning, or Error events
through the Windows Event Log API.

Register each application name once from an **elevated Windows PowerShell**
session before enabling this sink:

```powershell
& ".\Scripts\Register-DFLogEventSource.ps1" -SourceName `
    "Package Manager Server", "Package Manager Admin Panel"
```

The script registers each source in the Application log and associates it with
Windows' generic event-message resource. The caller's `iCode` becomes the Event
ID, its log level becomes the native Windows event type, and the description is
only the original message. Windows already stores the timestamp and application
source as event metadata, so the JSON envelope is used only for the file sink.

Source registration changes HKLM and therefore belongs in installation or
deployment, not application startup. Run the script again if
`psApplicationName` changes. The application process must have permission to
write to the Application log.

## Failure reporting

Override `OnLogError` if startup diagnostics should go to another safe sink:

```dataflex
Procedure OnLogError String sSink String sMessage
    Showln sSink ": " sMessage
End_Procedure
```

Programming errors currently include an empty `psConnectionId`, an invalid
`psLogTable`, an incompatible logging DDO, a missing table when automatic
creation is disabled, and an unavailable event-log target.

Do not call the same logger from `OnLogError`; recursive writes are ignored.
