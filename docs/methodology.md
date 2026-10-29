# Rule coverage and sizing methodology

## Rule accounting

The versioned manifest at `src\SimpleSqlAssessment\Rules\rules.json` retains the
30 SQL Database and 34 Managed Instance mappings in the published assessment
catalogs: **64 mappings, 46 distinct IDs**. `Get-SsaAssessmentRule` exposes them.
Each mapping has positive, clean-evidence, and missing-evidence fixtures.
Mapping coverage is not a claim of exhaustive T-SQL or application-path coverage.

Sources:

- [SQL Server migration overview](https://learn.microsoft.com/en-us/data-migration/sql-server/overview)
- [SQL Database assessment rules](https://learn.microsoft.com/en-us/data-migration/sql-server/database/assessment-rules)
- [Managed Instance assessment rules](https://learn.microsoft.com/en-us/data-migration/sql-server/managed-instance/assessment-rules)
- [SQL Server on Azure VM guidance](https://learn.microsoft.com/en-us/data-migration/sql-server/virtual-machines/guide)

The engine combines feature catalogs, file/database inventories, dependency
metadata, and ScriptDom analysis of persisted modules, server triggers, and
T-SQL Agent steps. Legacy token detectors supplement current parsers for
discontinued syntax. Constant executable SQL strings are analyzed recursively
to a bounded depth. Runtime-built SQL, variable procedure names, `sp_executesql`
context, parse errors, encrypted text, and hidden metadata remain visible gaps.
No application-only traffic is collected.

Evaluations are `Pass`, `Finding`, `NotApplicable`, `NeedsReview`, or `Error`.
`Pass` means no incompatible use was found in the available scoped evidence,
not that the application is migration-ready. A positive finding and an
incomplete-evidence review can coexist. Target summaries show `NotReady` for
issues, `Unknown` for outstanding reviews, or readiness/warning states when
those boundaries allow it. Runtime application coverage requires review even
when all observable checks are clean.

Published category is retained separately from effective finding category.
Configured linked servers/providers without proven per-database usage are
dependency reviews, not invented database blockers. A direct incompatible
reference still creates its relevant finding.

Windows authentication and SQL Agent jobs are non-blocking migration warnings,
with guidance for identity mapping, scheduling, or job-step changes. T-SQL job
text is assessed through the warning-level job checks, not as database module
code that can create migration blockers. Incompatible SQL in persisted database
modules or server triggers still produces its normal issue. Missing identity/job
evidence or unresolved job SQL remains an explicit coverage review.

## Documentation reconciliations

- Historical MI size/count rule IDs remain intact, but checks use the current
  curated tier/hardware limits instead of contradictory headline values.
- A distributed-transaction statement cannot prove homogeneous versus
  heterogeneous participants or working DTC networking. MI checks explain
  that uncertainty rather than declaring supported homogeneous DTC incompatible.
- MI global flags use the versioned allowlist in `rules.json`, sourced from
  [DBCC TRACEON](https://learn.microsoft.com/en-us/sql/t-sql/database-console-commands/dbcc-traceon-trace-flags-transact-sql#remarks).
  Session flags are unsupported; unresolved scope is a review.
- Bulk paths can be accepted as Blob-backed when the direct URI or a single
  unambiguous external source establishes that. Multi-statement source
  ambiguity still requires review; access credentials/network reachability
  are not verified.
- CLR signing/trust, multiple-log-file migration methods, external dependencies,
  and identity conversion are not established by metadata presence alone.

The VM pack has **six separately scoped checks**: engine version/upgrade,
compatibility level, edition features, instance objects, external dependencies,
and migration prerequisites. It does not apply PaaS restrictions to VMs or
claim historical Upgrade Advisor parity. Upgrades, downgrade risks, restore
paths, OS/image support, and application behavior need operator validation.

## Observed inbound client dependencies

This report is separate from persisted SQL object/linked-server references and
does not affect compatibility, capacity percentiles, or SKU selection. It uses
[session metadata](https://learn.microsoft.com/en-us/sql/relational-databases/system-dynamic-management-objects/sys-dm-exec-sessions-transact-sql)
and [connection metadata](https://learn.microsoft.com/en-us/sql/relational-databases/system-dynamic-management-objects/sys-dm-exec-connections-transact-sql)
to observe inbound user sessions, including idle pooled sessions. SQL's original
login identifies the connection identity, not a potentially impersonated
execution context.

Rows group IP/reported hostname, application, driver, original login, and
best-effort local/remote/unknown classification. Each group records distinct
observed current database contexts, transports, authentication schemes, and
encryption states. `SamplesSeen` increments once per group in a successful
snapshot; `PeakSessions` is the maximum distinct session count for that group
in any one snapshot. Neither is a total login count. MARS child connections
are excluded by the query and duplicate session IDs do not inflate concurrency.
Case-insensitive host/IP identity preserves stable groupings; applications and
logins are not collapsed across case-sensitive values.

Successful static and capture snapshots contribute, including rate baselines.
First/last observations are UTC collector timestamps. Failed/missing snapshots
do not contribute clients or fabricated sightings, and no observations are
interpolated over gaps. Successful empty snapshots are distinguished from
missing/denied evidence. Legacy captures cannot recover client history.
Default sampling is the existing 30-second cadence; snapshots alone cannot
guarantee discovery of short-lived clients, weekly/monthly tasks, true peak
connections, all databases accessed, or machines hidden behind gateways.
Client-reported names are unverified, and a current database is only session
context, not proof of a database dependency.

## Performance and demand

Usable observations pair Windows host/process CPU and memory with SQL committed
memory and cumulative per-file I/O. SQL file counters provide elapsed-time
IOPS, throughput, log-write rate, and allocated data/log/tempdb sizes.
The process working set provides a floor for SQL memory; host used memory is
also considered for VM sizing when available.

Sizing defaults:

| Input | Default |
| --- | --- |
| Capture duration | Seven usable days |
| Sample interval | 30 seconds |
| Aggregation | Independent ten-minute metric maxima |
| Demand percentile | Nearest-rank 95th percentile of those maxima |
| Resource headroom | 20% |
| Allocated storage growth | 20% |
| Monthly compute normalization | 730 hours |

CPU, memory, I/O, and log percentiles are independent envelope values, not a
single simultaneous synthetic workload. **Instance I/O is summed across
databases at each observation before percentile calculation**, not by summing
unrelated per-database percentiles. Charts are downsampled ten-minute envelopes
with explicit gaps. Source peaks and short/partial capture duration remain visible.
Seven usable days is the capture default, not an eligibility gate: interrupted
or short captures can produce provisional recommendations, with their observed
duration and gaps retained. The collector cannot establish that the captured
period represents seasonal peaks.

For each source database, SQL Database sizing uses database I/O/storage but
conservatively bounds CPU, memory, and tempdb with the **whole SQL instance**.
It does not pretend to have measured per-database CPU attribution. MI/VM sizing
uses the source instance. No hardware-generation CPU uplift is invented.

| Target | Scope and selection decisions |
| --- | --- |
| SQL Database | One independent recommendation scope per source database. Database file I/O, log-write rate, and storage are scoped to that database; whole-instance SQL CPU, memory, and tempdb remain conservative upper bounds. GP, BC, and Hyperscale are separate tier alternatives. |
| Managed Instance | One source-instance scope. SQL CPU/memory and simultaneously aggregated file I/O size the instance. User/system data/log allocations, database/file counts, tempdb, per-file capacity, regional hardware/storage limits, and log rates constrain GP, next-gen GP, and BC alternatives. All standalone core sizes and exact premium flexible-memory allocations compete within each tier. Next-gen provisioned IOPS also satisfy required throughput; GP/next-gen remote I/O excludes local tempdb. Classic GP per-file performance and per-database log rates still require layout-specific verification. |
| SQL VM | One source-instance/host scope. Use the larger SQL/host CPU envelope, and the larger of SQL memory plus OS reserve or observed host-used memory, with headroom. SQL/host aggregate I/O, managed-disk roles, VM remote I/O caps, attachment counts, target SQL version/edition, and local-tempdb policy constrain the VM. No HA/DR replicas are added. |

Known CPU, memory, storage, IOPS, throughput, log, database-count, tempdb,
version/edition, and disk constraints reject unsuitable configurations.
Unpublished optional limits stay null and explicitly unverified; they are not
validated as unlimited. A missing mandatory observation produces an unavailable
recommendation, never a zero-demand fit. All useful options remain
**Provisional** and need target workload testing.

## Storage, VM layout, and catalog boundaries

Capture throughput is MiB/s; catalog/disk throughput is decimal MB/s. Sizing
converts with **1.048576** before comparing limits. Capacity fields use GiB.

SQL Database GP/BC reserve sufficient data capacity for the proportional log
limit as well as required data. `ReservedStorageGB` can therefore exceed
`DataGB`. Pricing bills that configured data reservation plus the automatic
30% log allowance; the billable allowance does not enlarge the configured
data cap. Hyperscale instead bills allocated data with a ten-GiB minimum and
no log surcharge. Managed Instance storage
includes data/log and, for BC, tempdb, rounded to supported 32-GiB reservations.
Target tempdb limits are checked using the conservative observed envelope.
GP/next-gen MI also enforce the separate 120-GiB tempdb-log limit with growth.
Next-gen IOPS are explicitly allocated: storage includes three IOPS/GiB, at
least 300 and no more than the core-size cap. Throughput above the guaranteed
75 MB/s floor requires at least `ceil(required MB/s * 30)` provisioned IOPS,
subject to the published throughput/core cap. Additional IOPS and flexible
memory are retained in recommendations and billed separately. Storage and IOPS
are not interchangeable hidden assumptions.

A VM has a four-GiB OS memory reserve and a 128-GiB OS disk, plus separate data
and log disks. Tempdb uses the selected VM's included local temporary drive when
its required capacity (including storage growth) fits. If local capacity is
insufficient, absent, or unknown, managed tempdb disks are allocated instead;
selection does not favor a larger VM merely for a larger temporary drive.
CPU, memory, I/O, and attachment constraints can still require a larger VM.
`TempdbPlacement` records `LocalTemporary` or `ManagedDisk`, and `DiskLayout`
contains only billable managed disks. The tempdb capacity constraint reflects
the selected storage, and local tempdb adds no managed-disk charge.

Local temporary capacity is **device count times per-device GiB**, not the
capacity of one device. For example, E32ads_v7 has four 440-GiB NVMe devices,
1,760 GiB total. Using that aggregate requires a striped temporary volume or
appropriate multi-file placement, not an assumed preformatted D: drive.
Raw NVMe must be initialized/formatted, with tempdb recreated before SQL
startup after host changes. Do not allocate an ephemeral OS on this capacity.
Pagefile defaults to the persistent OS disk on these NVMe families; account
for it if moved locally. Verify free capacity and steady-state write performance;
published local read/peak-write values are not a mixed-workload guarantee.
Ebdsv5 instead exposes one logical temporary SSD volume with its published
per-VM capacity (75-3,800 GiB); it is not raw local NVMe. Reserve pagefile/other
use and recreate tempdb after host changes. Its modeled **remote** managed-disk
controller is NVMe, independently of local temporary storage. The NVMe
Premium SSD table requires a compatible Generation 2 deployment; SCSI has lower
limits and is not interchangeable. E112ibds_v5 is NVMe-only. No ephemeral OS
uses the modeled local tempdb allocation.
When tempdb is local, SQL tempdb file I/O is excluded from remote aggregate and
data/log disk demand. When managed, it remains in remote aggregate demand.
Total host I/O remains a conservative floor in either case: the captured host
counters cannot distinguish local/remote OS or other application I/O.
Observed system database storage is included.
Each role must satisfy disk capacity, IOPS, and throughput, and the complete
layout must satisfy VM attachment and uncached aggregate limits. No burst/cache
uplift is assumed. Disk alternatives are evaluated across the complete layout;
the least provisioned capacity that fits the attachment limit wins, then the
fewest disks. This avoids rejecting a feasible VM merely because each role's
individually smallest-capacity layout uses too many disks. It is not a disk
price optimizer. Individual OS I/O attribution is unverified. FILESTREAM
external capacity is not measured, so it prevents a complete VM storage sizing
recommendation until separately assessed.

### Three VM disk alternatives and latency suggestions

The module returns one independently sized VM/layout per disk type, even if
two or three alternatives select the same compute SKU. An infeasible or
region-excluded type remains an explicit `Unavailable` alternative, never a
zero price. Each profile still selects the smallest feasible active-core VM,
then memory, generation and ID. Comparing their prices happens afterward.
The source-specific VM envelopes are not interchangeable: for example,
E112ibds_v5 allows 260,000 IOPS / 8,000 MB/s on Premium SSD but 400,000 IOPS /
10,000 MB/s on v2/Ultra. Constrained sizes inherit their parent's envelopes.
These limits are shared ceilings, not extra additive bandwidth for the OS.

V2 supports every integer size from 1 through 65,536 GiB. Its per-disk
provisioned IOPS are 3,000-80,000, bounded by `max(3000, 500 * SizeGB)`;
throughput is 125-2,000 decimal MB/s, at most `IOPS / 4`.
Ultra supports every integer size from 4 through 65,536 GiB, 100-400,000 IOPS
bounded by `1000 * SizeGB`, and 1-10,000 MB/s bounded by `IOPS / 4`.
The allocator provisions integer IOPS and MB/s sufficient for each role,
including any IOPS increase needed for throughput. It searches **every
permitted attachment count**, not a handful of sampled disk sizes, applying
the equations to calculate the minimum feasible per-disk capacity. Each role
uses homogeneous disks; appropriate striping/file placement is required.
OS disks remain fixed Premium SSD. No host caching, shared disks, bursting or
Performance Plus uplift is assumed. The local-tempdb/no-tempdb-only-upsize
policy applies independently to all three alternatives.

New captures record interval read/write stall per operation for each SQL file,
plus localized LogicalDisk `Avg. Disk Queue Length` for each volume. The
volume mount point comes from `sys.dm_os_volume_stats`; only queues mapped to
active SQL files inform the suggestion. Tempdb is excluded for local-tempdb
alternatives and included when that alternative requires managed tempdb disks.
No `_Total` queue sum,
unrelated-volume queue, or cumulative-since-startup SQL latency is used.
Older captures can recover file latency from their saved raw DMV deltas;
absent queue/mount-point evidence remains unknown and is not synthesized.
No-I/O file directions have null latency rather than a misleading zero.

The latency policy uses the requested nearest-rank percentile of each
sample's worst active file read/write latency, **separately from** the
ten-minute capacity envelope. Prefer the submillisecond class (v2 or Ultra)
if at least 5% of active sampled interval weight has SQL file latency >=10ms,
or a same-volume average queue >=2 **with** SQL file latency >=5ms; also
preserve source service already <=1ms. Otherwise all three SSD classes remain
eligible. Queue depth alone does not prove a bottleneck on parallel SSDs.
These are explicit assessment heuristics, not manufacturer queue limits.
Windows counters average the one-second counter observation, not the entire
30-second SQL interval; sampled interval weights approximate pressure and
do not establish continuous queueing. SQL latency includes the full I/O
path and can reflect issues other than disk service.

For each eligible PAYG/AHB scenario, the suggestion is the least expensive
**complete** quote within that latency class. Both v2 and Ultra advertise
submillisecond service; queueing does not automatically justify Ultra.
Missing file-latency evidence yields no suggestion. Partial costs cannot win,
and no unavailable lower-latency type silently falls back to Premium SSD.
These observations are not an application latency requirement or target SLA:
validate with the customer and a representative target workload. A throttled
source can under-report unconstrained IOPS demand; investigate, remediate and
recapture before purchasing.

The reviewed regional matrices filter known unsupported regions but do not
validate subscription resource-SKU restrictions, zones, quotas or images.
Ultra needs VM Ultra compatibility enabled and does not support availability
sets; v2 commonly requires zonal VMs (some regions permit nonzonal resources).
Both need compatible 4k/512E sector settings. Use authenticated Azure resource
SKU checks before deployment; a retail rate does not prove eligibility.
Ultra's conflicting capacity-billing references and conservative rounding
are described in [pricing](pricing.md).

SQL Database covers **77 provisioned configurations**: all documented Gen5
GP/BC sizes (15 each), Gen5 Hyperscale sizes (14), premium Hyperscale sizes
(18), and memory-optimized premium Hyperscale sizes (15). DC-series, serverless,
elastic pools, and retired hardware are excluded. Each tier/hardware/core row
stores its own published memory, tempdb, and I/O limits. Gen5 GP/BC memory
matches in the reviewed tables; that is not assumed universally across tiers
or hardware. High-core ceilings are explicit, never extrapolated.

MI covers all **104 standalone base tier/hardware/core configurations** and
all **66 additional published flexible-memory allocations**. Memory follows
each family's documented ratio/cap; exact API values govern flexible memory.
`-Region` enforces the reviewed memory-optimized hardware and higher-storage
regional matrix; the integrated workflow always supplies it. Without a region,
conditional larger-storage options explicitly require regional verification.

The VM scope is x64 E-series with local temporary storage: Ebdsv5, Edsv6,
Eadsv6, Edsv7, Eadsv7, and Ebdsv6 Preview. All **62 published base sizes** and **37 exact
published constrained variants** are present, including the 192-core v6 and
372-core v7 high ends. There are **89 nonpreview configurations**;
`-IncludePreviewVm` admits ten Ebdsv6 Preview sizes and persists the opt-in.
Ebdsv5 adds all nine documented sizes (2, 4, 8, 16, 32, 48, 64, 96, 112 cores);
no constrained Ebdsv5 sizes are published in the reviewed sources. Every
modeled remote performance envelope uses an NVMe remote controller. No ARM,
diskless, SCSI profiles, or other VM families compete. All **14 Premium SSD LRS
base tiers P1-P80** are available to the disk-layout search, alongside the full
configurable Premium SSD v2 and Ultra ranges. Cache/burst uplift and
Performance Plus remain outside scope.
This is complete within the stated VM/disk scope, not an Azure-wide no-fit
claim. Regional
availability, subscription quotas, edition-specific buffer-pool/feature limits,
support, HA/DR equivalence, and deployment availability require validation.
See the source-linked [catalog reference](../src/SimpleSqlAssessment/Catalogs/README.md).
Standard-edition SQL CPU demand is limited to 24 virtual cores through SQL 2022
and 32 for SQL 2025, independently of host CPU capacity. Total committed/process
memory is not buffer-pool attribution, so edition-specific memory-pool limits
still need separate validation.

### SKU and price sourcing

`Catalogs\targets.json` is a reviewed, versioned offline snapshot of Microsoft
Learn resource tables. `Private\Catalog.ps1` expands that snapshot into the
supported tier/hardware/core combinations and preserves source URLs/revisions.
It does not call a live Azure SKU API. SQL Database capacities come from the
[single-database vCore limits](https://learn.microsoft.com/en-us/azure/azure-sql/database/resource-limits-vcore-single-databases);
MI capacities from [MI resource limits](https://learn.microsoft.com/en-us/azure/azure-sql/managed-instance/resource-limits);
VM/disk facts from the linked Ebdsv5, E-series v6/v7 and managed-disk specification tables.
Constrained sizes preserve parent memory, local disks, remote I/O, and disk
attachment counts, but expose only their **active** vCPUs. `BaseVCores` and
`BaseVmSize` identify the retained parent allocation. Only explicit published
variants are generated, never a theoretical half/quarter-core cross-product.
The constrained overview has inconsistent Edsv6 active-core column values;
active cores follow the documented naming suffix. Its missing Eadsv6 variants
are enumerated from reviewed exact public SKU identities and inherit documented
parent resources under the constrained-vCPU contract. Price identities prove
neither new-region availability nor subscription eligibility.

The public [Azure Retail Prices API](https://learn.microsoft.com/en-us/rest/api/cost-management/retail-prices/azure-retail-prices)
provides **rates only**, after capacity selection. It is not a capacity,
regional availability, quota, or deployment validation source. Exact meter
identities are resolved by region/currency and cached with retrieval dates;
missing or ambiguous mandatory rates leave the total unknown. New Hyperscale
databases have no separate SQL software license fee and no AHB eligibility.
Next-gen MI pricing uses Microsoft's documented GP baseline plus exact public
additional-IOPS and flexible-memory meters when those resources are required.
Missing extra-resource meters keep the complete total unknown rather than
silently pricing only the baseline.

The smallest feasible configuration per tier is returned, active cores then memory;
SQL Database hardware families compete within the Hyperscale tier just as MI
hardware families compete within their tiers. VM ties prefer newer generations, then catalog ID,
not price or extra temporary capacity. A constrained VM can therefore satisfy a
memory-heavy workload with fewer SQL license cores, but its compute/Windows
allocation still costs the parent amount. This is not a promise of global
price optimization, and premium hardware is priced with its own exact compute
meter rather than Gen5's rate. Target totals use the least expensive **complete**
quote among alternatives for each required scope, not the sum of alternative
tiers. SQL Database totals include each database; unavailable scopes keep the
target total unknown.

Static compatibility describes the collection timestamp, not the end of a
later performance run. Recollect after material source changes. Capture
checksums, catalog provenance, timestamps, and module/rule/catalog versions
make the boundary inspectable; they do not prove application correctness.

## Maintenance

Run `.\tools\Test-PublishedRuleCatalog.ps1` explicitly online to compare the two
published summary inventories with the frozen rule IDs. It reports additions
and removals without modifying rules; a changed page format is an error, not
an unchanged result. This is an ID-drift check, not automatic semantic review.
Review rule text, MI trace flags, capacity-source revisions, regional limits,
and retail meter identities before each catalog release. Update fixtures and
version the snapshot deliberately; assessment runs never update catalogs.
