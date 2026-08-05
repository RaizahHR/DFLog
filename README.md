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

`cLogger` is only the public API and lifecycle owner. Logging destinations are
child objects derived from `cLoggerWorker`. During `InitLogger`, the logger
discovers those children, stores their handles in `phoaLoggerWorkers`, assigns
itself as their logger, and initializes every enabled worker. `WriteLog` then
dispatches the entry to that list without knowing which sink types it contains.

The implementation is split by responsibility:

- `cLogger.pkg` — public singleton API and dispatch;
- `cLoggerDatabase.pkg` — DDO/SQLExecutor persistence and table setup;
- `cLoggerFile.pkg` — folder, file naming, and sequential output;
- `cLoggerEventLog.pkg` — Windows Application event-log dispatch;
- `cLoggerWorker.pkg` — the small shared worker/error contract.

## Basic use

Adding `cLogger` from the Studio Class Palette's **Logging** group creates the
logger with commented database, file, and event-log worker blocks. Uncomment
only the sinks the application needs, and set `psConnectionId` before enabling
the database worker.

Add the DFLog `AppSrc` folder to the consuming workspace's AppSrcPath, then
create the logger after the application/connection objects:

```dataflex
Use cLogger.pkg

Object oLogger is a cLogger
    Set psApplicationName to "Package Manager Server"
    Set piLogLevel to DFLOG_INFO

    Object oDatabaseLogWorker is a cLoggerDatabase
        Set psConnectionId to "PkgMngrSrvr"
        Set psLogTable to "dbo.DFLog"
    End_Object

    Object oFileLogWorker is a cLoggerFile
        Set psLogFolderPath to "Logs" // relative to the workspace root
    End_Object

    Object oEventLogWorker is a cLoggerEventLog
    End_Object
End_Object

Send LogMessage of oLogger "Startup" "The application started." 100 DFLOG_INFO
Send WriteLog of oLogger (CurrentDateTime()) "package.push" "Package rejected." 200 DFLOG_ERRORS "optional-trace-id"
```

`piLogLevel` controls verbosity for every enabled sink: `DFLOG_NONE`,
`DFLOG_ERRORS`, `DFLOG_WARNINGS`, or `DFLOG_INFO`. The final optional arguments
to `WriteLog` and `LogMessage` are the trace ID and a `cJsonObject` containing
additional fields. A message is written only when `piLogLevel` is greater than
or equal to its level. Calls that omit these arguments default to `DFLOG_INFO`
with no trace ID or additional fields.

The same message level becomes the Windows event type and the ECS `log.level`:
errors are `error`, warnings are `warning`, and informational messages are
`info`.

Properties set inside the object declaration are applied before the automatic
`InitLogger` call. Worker properties live on their respective worker objects.
All workers default to `pbEnabled=True`; set it to `False` to keep a declared
worker in the list without initializing or writing through it. If workers are
added or removed dynamically, send `InitLogger` once to rebuild the list. Send
it after other runtime configuration changes when immediate reinitialization is
required.

To add another sink, derive a class from `cLoggerWorker`, implement
`InitWorker` and `WriteLog`, and declare it as another child of `oLogger`.
Override `DeinitWorker` as well if the sink owns resources that must be closed
when it is disabled. The base class supplies list discovery, `pbEnabled`,
`pbReady`, `phoLogger`, and the shared error-reporting helpers; no change to
`cLogger` is required.

## Additional structured data

Pass a `cJsonObject` as the final argument to add call-specific structured
data. The caller owns the object and may destroy it as soon as the synchronous
logging call returns:

```dataflex
Boolean bParsed
Handle hoFields

Get Create (RefClass(cJsonObject)) to hoFields
Get ParseString of hoFields ;
    '{"http":{"request":{"method":"POST"},"response":{"status_code":201}}}' ;
    to bParsed

If (bParsed) ;
    Send LogMessage of oLogger "api.package.push" "Package accepted." ;
        100 DFLOG_INFO sTraceId hoFields

Send Destroy of hoFields
```

The file worker merges this object into the ECS document root, preserving
types and nested field sets. Logger-owned values override the corresponding
supplied values: `@timestamp`, `message`, `ecs.version`, `log.level`,
`service.name`, `event.action`, `event.code`, and `trace.id`. Other members in
those objects, such as `event.outcome`, are retained.

Use native ECS fields where available, such as
`http.response.status_code`. Place application-specific nested data under a
stable custom namespace. Because the logger is normally a singleton, keep
additional data on the individual call rather than in logger properties.

When `pbLogToSingleFile` is false (the default), files are named
`DFLog-yyyy-mm-dd.jsonl`. Every physical line is one independent JSON object:

```json
{"@timestamp":"2026-08-03T08:45:36.659Z","message":"Validating archive","ecs":{"version":"9.4.0"},"log":{"level":"info"},"service":{"name":"Package Manager Server"},"event":{"action":"package.push","code":"100"},"trace":{"id":"4bf92f3577b34da6a3ce929d0e0e4736"}}
```

This is a deliberately small ECS subset rather than an implementation of the
entire schema. `sCategory` maps to `event.action`, `iCode` to `event.code`, and
the optional final argument to `trace.id`. JSON serialization escapes quotes,
tabs, and line endings without changing the original message value.

`@timestamp` treats the supplied DataFlex `DateTime` as local time, converts it
with DataFlex's current UTC offset, and writes ISO 8601 with milliseconds and a
`Z` suffix. Calls normally pass `CurrentDateTime()`.

## Database setup

Run [`SQL/CreateDFLog.sql`](SQL/CreateDFLog.sql) against the target database.
The script is safe to run repeatedly and adds `LogLevel`, `TraceId`, and the
JSON-validated `AdditionalData` column to an existing DFLog table. Run it
before deploying this version. `pbAutoCreateTable` also lets the logger create
a missing table at startup, but production
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

The optional DDO fields `LogLevel`, `TraceId`, and `AdditionalData` are
populated when present. The SQL table always contains them. `AdditionalData`
stores the same compact JSON object supplied to the logger. These relational columns map to the JSON
fields as follows: `LoggedAt` to `@timestamp`, `Application` to `service.name`,
`Category` to `event.action`, `EventCode` to `event.code`, `LogLevel` to
`log.level`, and `TraceId` to `trace.id`. The fixed ECS version belongs to the
file contract and is not repeated in every database row.

The DDO path is useful when a consuming application already maintains a DF/INT
table definition. Override `GetDefaultLogDataDictionary` or
`OnGetLogDdoHandle` on the `cLoggerDatabase` worker to supply it lazily.

## Windows Application event log

Declare an enabled `cLoggerEventLog` child to write entries to **Windows Event
Viewer > Windows Logs > Application**. The logger application name is used as
the event source. Entries are written as native Information, Warning, or Error
events through the Windows Event Log API.

Register each application name once from an **elevated Windows PowerShell**
session before enabling this sink:

```powershell
& ".\Scripts\Register-DFLogEventSource.ps1" -SourceName `
    "Package Manager Server", "Package Manager Admin Panel"
```

The script registers each source in the Application log and associates it with
Windows' generic event-message resource. The caller's `iCode` becomes the Event
ID, its log level becomes the native Windows event type, and the description
starts with the original message. Windows already stores the timestamp and
application source as event metadata. The worker appends the event action and
trace ID as readable lines, followed by compact JSON under an `Additional
data:` label when structured data is supplied.

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
