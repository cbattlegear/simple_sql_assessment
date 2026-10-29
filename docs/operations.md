# Permissions, capture, and recovery

## Source access

The collector uses read-only catalog/DMV queries and `DBCC TRACESTATUS`.
It does not enable trace flags, change server options, install services, create
monitoring objects, collect application query traffic, or execute stored source
definitions. It reads T-SQL Agent step text but does not execute job steps.

Have your DBA grant an appropriate read-only assessment identity. Exact
permissions vary by SQL version and enabled features; absence of visible rows
does not establish absence of a feature.

| Surface | Access/visibility needed |
| --- | --- |
| Database inventory | `VIEW ANY DATABASE`; connection access to each assessed user database |
| Definitions and dependency catalogs | `VIEW DEFINITION` on each database; server definition visibility for server objects |
| Server principal inventory | Visibility of all Windows logins/groups; the collector conservatively recognizes `ALTER ANY LOGIN` or sysadmin visibility |
| Database principals | Complete database metadata visibility |
| SQL performance observations | Generally `VIEW SERVER STATE` through SQL 2019; SQL 2022+ uses `VIEW SERVER PERFORMANCE STATE` for relevant DMVs |
| Inbound client inventory | `VIEW SERVER STATE` through SQL 2019; `VIEW SERVER PERFORMANCE STATE` on SQL 2022+, checked explicitly before collecting all user sessions |
| SQL Agent jobs | Read access to required msdb tables and complete job visibility; recognized roles include `SQLAgentReaderRole`, `SQLAgentOperatorRole`, or msdb `db_owner` |
| Mail/audits/providers/credentials/triggers | Read access and complete metadata visibility for the relevant feature |
| Windows observations | Performance-counter access on the SQL host and read access to localized Perflib registry names |

This is not a request to grant `sysadmin`, `db_owner`, or `ALTER ANY LOGIN`
automatically. Those are broad privileges. If your security policy disallows a
particular visibility grant, retain the partial assessment and review its gaps.
The module never grants permissions.

Some evidence queries can succeed while hiding rows. The collection records
`Collected`, `Unavailable`, or `Error`; known positive evidence is retained even
when visibility is incomplete. Offline/inaccessible databases remain unassessed.
System databases and database snapshots are not collected as migration-unit
databases; instance job/trigger metadata and system-file performance remain relevant.

## Inbound client observations

Static collection saves a `ClientSnapshot` in `inventory.json`. Each successful
performance observation saves another in the checksummed segment's `Raw` model.
Snapshots query `sys.dm_exec_sessions` and `sys.dm_exec_connections` with a
five-second command timeout for each query, including the permission check.
The query excludes internal sessions and its own session, retains sleeping and
pooled user sessions, and joins only primary physical connections to avoid MARS
duplication. It does not read SQL text, install an event session, query client
machines, or change SQL configuration.

Client inventory is optional evidence: denied visibility and failed queries
produce a warning and an explicit snapshot status, not a failed performance
interval. Offline analysis aggregates saved snapshots without reconnecting.
Restart/baseline snapshots remain valid point observations even when no
performance rate can be calculated. Resume reads committed snapshots once and
does not persist a separate, double-counted summary.

`ClientDependencies.Status` is `Collected` when all included snapshots succeeded,
`Partial` when some evidence is missing, `Unavailable` when only failed/denied
snapshots exist, or `NotCollected` for older bundles with no client evidence.
None of these states asserts complete application discovery. Counts of
successful, unavailable, and legacy snapshots and grouped query diagnostics
appear in HTML/JSON; the CSV contains client rows and is header-only when none
are available. Consult coverage before interpreting an empty CSV.
`-SkipPerformance` reports the static snapshot only.

First/last sightings are collector UTC observation times, not login/logout
times. No duration or traffic is attributed between observations. IP-based
local/remote classification is best effort (shared memory, loopback and an exact
server-address match are local); other unidentifiable connections remain
`Unknown`. Alternate local interfaces and network intermediaries can obscure
the actual machine. Host/application names and original login names are
sensitive; these reports must not be added to the public repository.

## Windows counters

Performance sizing **requires** Windows and SQL observations. The Windows
identity of the collector is separate from an optional SQL-authentication
credential. Supplying `-Credential` does not grant remote Windows access.

Remote use needs permitted performance-counter RPC access and readable remote
registry metadata. The collector maps English counter IDs to the host's
localized names and finds SQL's process instance by PID, including duplicate
process names. Counter paths are matched case-insensitively, including disk
totals, queues, and free space; lowercase paths returned by `Get-Counter` are
valid. It does not start Remote Registry, open firewalls, change group
membership, or elevate privileges. Run locally on the SQL host if remote
read-only access cannot be provided.

`Test-SsaPrerequisite -SqlInstance ...` checks source/counter connectivity.
Use `-SkipPerformance` for a static-only check or assessment.

## Durable capture

Capture runs in the PowerShell process; it does not create a scheduled task or
background service. Keep that process running for collection. Default sampling
is every 30 seconds for seven days of **usable paired observations**.
Collection work is deducted from the requested sampling cadence.

Each committed observation is an atomically published, sequential JSON segment
with a SHA-256 checksum. The checkpoint is also atomic; a single-writer file
lock prevents concurrent collectors for one bundle. Checksums detect accidental
corruption; they are not a signature or protection against a malicious editor.

First baselines, long gaps, SQL restarts, PID changes, changed files, and
decreasing cumulative counters do not count as usable rate intervals.
Transient failures retry twice after the initial attempt. A continuing failure
is visible and leaves a resumable checkpoint.

```powershell
Resume-SsaPerformanceCapture `
    -CollectionPath 'C:\Assessments\Server01\collection'

# Then update the report from committed evidence and the existing cache.
Invoke-SsaAssessment `
    -CollectionPath 'C:\Assessments\Server01\collection' `
    -OutputPath 'C:\Assessments\Server01' -Region eastus -Offline
```

Resume validates committed sequence/checksums, collection identity, and original
configuration, then starts a new baseline. It extends wall-clock collection
until the requested usable duration is reached. Never edit `capture.json` to
shorten or restart a run. Changed hosts/failover identity, database membership,
or database names require a fresh static collection. Corrupted or missing
committed observations are errors, not silently discarded data.

Ctrl+C/interruption retains committed evidence. After a process crash, the OS
releases the lock; the lock file may remain harmlessly on disk. A staging `.tmp`
file is not a committed observation. Do not delete valid segments to repair
sequence gaps.

Use local storage with free space appropriate to database/file count. Seven days
at 30 seconds produces roughly 20,161 observations before additional baselines
or gaps. Segment size scales with source file count and concurrent client sessions.
Offline analysis loads rate
observations in memory; large instances and extended captures need memory and
disk-capacity planning. No automatic retention or source-data deletion is performed.

## Security and artifact handling

Connections encrypt traffic and validate certificates by default. Only use
`-TrustServerCertificate` after evaluating the resulting loss of certificate
validation. Credentials are not persisted; SQL passwords use `SqlCredential`
and `SecureString`, not connection-string password text.

New collection directories must be empty. Their ACL is restricted to the
collecting Windows identity; existing directory permissions are not rewritten.
When moving a bundle to another operator, arrange approved secure transfer and
destination ACLs yourself.

Definitions and job text can contain embedded credentials. The local evidence
bundle is **not redacted**. Presentation exports omit those texts and escape
HTML/JSON and CSV formula prefixes, but they still expose infrastructure and
business metadata. Do not treat an HTML or JSON report as public by default.

Only the explicit online pricing stage calls Azure's public pricing service,
with public SKU/region/currency filters. `-Offline` requires `-CollectionPath`
and prevents both SQL access and pricing HTTP. The HTML viewer makes no
automatic remote requests. Its documentation links are user-initiated.
