# Target specifications and retail mappings

`Get-SsaCatalog` is private and returns `Version`, `SourceUrls`, `Sources`,
`SqlDatabase[]`, `ManagedInstance[]`, `Vm[]`, and `Disks[]`. IDs are stable; sizing
sets `Recommendation.CatalogId` to the candidate's `Id`. The source snapshot and
review date are in `targets.json`; catalog loading never discovers SKUs online.
Disk entries expose `Id`, `SizeGB`, `Iops`, and `ThroughputMBps`; VM candidates
expose `MaxDataDisks`. Recommendation disk entries may include `SizeGB`, which
must equal the selected catalog tier. Roles are case-insensitive (`Os` is valid).

## Coverage and units

SQL Database covers **77 provisioned single-database configurations**, every
documented core size in the following allowed tier/hardware families in the
[reviewed resource tables](https://learn.microsoft.com/en-us/azure/azure-sql/database/resource-limits-vcore-single-databases):

| Tier | Hardware | vCores | Configurations |
| --- | --- | --- | --- |
| General Purpose | Standard-series (Gen5) | 2, 4, 6, 8, 10, 12, 14, 16, 18, 20, 24, 32, 40, 80, 128 | 15 |
| Business Critical | Standard-series (Gen5) | 2, 4, 6, 8, 10, 12, 14, 16, 18, 20, 24, 32, 40, 80, 128 | 15 |
| Hyperscale | Standard-series (Gen5) | 2, 4, 6, 8, 10, 12, 14, 16, 18, 20, 24, 32, 40, 80 | 14 |
| Hyperscale | Premium-series | 2, 4, 6, 8, 10, 12, 14, 16, 18, 20, 24, 32, 40, 64, 80, 128, 160, 192 | 18 |
| Hyperscale | Memory-optimized premium-series | 2, 4, 6, 8, 10, 12, 14, 16, 18, 20, 24, 32, 40, 64, 80 | 15 |

DC-series, serverless, and elastic pools are explicitly excluded. Gen4 and Fsv2
are retired; M-series is not in the current provisioned capacity tables and is
not included merely because historical price meters exist. Unsupported
combinations are not invented: for example, Gen5 Hyperscale has no documented
64- or 128-core row in this snapshot.

`SqlDatabaseFamilies` stores explicit per-tier/hardware/core memory and resource
rows, each family with its own source section and exact compute meter identity.
Published Gen5 GP/BC memory matches at the same core counts, but is stored
independently, not inferred across tiers. Other limits differ (14-core GP
tempdb is 384 GiB versus BC's 448 GiB). Hyperscale memory-optimized hardware has
different memory amounts, and high-core memory/IOPS/tempdb ceilings use table
values, not linear extrapolation. Hardware families compete within each tier;
sizing still returns the smallest feasible option per tier, cores then memory,
without assuming newer CPUs provide an unmeasured performance uplift.

Managed Instance covers the **complete 104-configuration standalone base
matrix plus all 66 additional documented flexible-memory configurations**
(170 total), not a selected core-size subset:

| Hardware | General Purpose vCores | Next-gen GP / Business Critical vCores |
| --- | --- | --- |
| Standard-series (Gen5) | 4, 8, 16, 24, 32, 40, 64, 80 | 4, 8, 16, 24, 32, 40, 64, 80 |
| Premium-series | 4, 8, 16, 24, 32, 40, 64, 80 | 4, 6, 8, 10, 12, 16, 20, 24, 32, 40, 48, 56, 64, 80, 96, 128 |
| Memory-optimized premium-series | 4, 8, 16, 24, 32, 40, 64, 80 | 4, 6, 8, 10, 12, 16, 20, 24, 32, 40, 48, 56, 64, 80, 96, 128 |

The 2-core MI configuration is pool-only and is excluded with pools.
`ManagedInstanceFamilies` gives each tier/hardware family its actual core list,
memory ratio/cap, and storage bands. Gen5 has 5.1 GiB/core (408-GiB cap),
premium 7 GiB/core (560-GiB cap), and memory-optimized premium 13.6 GiB/core
(870.4-GiB cap). Do not apply an uncapped ratio to larger core counts.
`ManagedInstanceFlexibleMemory` enumerates exact supported API memory values
for premium next-gen GP and BC; no arbitrary memory ratios are invented.
The base configuration IDs remain stable; extra-memory IDs append
`_Memory{GB}` and expose `DefaultMemoryGB` / `AdditionalMemoryGB`.

Higher BC storage ceilings and memory-optimized premium hardware use the
reviewed [regional matrix](https://learn.microsoft.com/en-us/azure/azure-sql/managed-instance/region-availability).
`Get-SsaSkuRecommendation -Region` enforces it; the integrated assessment
always passes its region. Without a region, a conditional larger-storage
option is retained with an explicit verification warning, not silently
removed. Pricing always enforces its required region too.

VM scope is **x64 Ebdsv5 plus E-series v6/v7 with local temporary storage**,
not an arbitrary sample of older D/E sizes:

| Family | Base vCPUs | Base sizes | Constrained variants | Total |
| --- | --- | --- | --- | --- |
| Ebdsv5 (Intel, NVMe remote controller) | 2, 4, 8, 16, 32, 48, 64, 96, 112 | 9 | 0 published | 9 |
| Edsv6 (Intel) | 2, 4, 8, 16, 20, 32, 48, 64, 96, 128, 192 | 11 | 13 | 24 |
| Eadsv6 (AMD) | 2, 4, 8, 16, 20, 32, 48, 64, 96 | 9 | 11 | 20 |
| Edsv7 (Intel) | 2, 4, 8, 16, 20, 32, 48, 64, 96, 128, 192, 248, 372 | 13 | 0 published | 13 |
| Eadsv7 (AMD) | 2, 4, 8, 16, 32, 48, 64, 96, 128, 160 | 10 | 13 | 23 |
| Ebdsv6 (Intel, Preview) | 2, 4, 8, 16, 32, 48, 64, 96, 128, 192 | 10 | 0 published | 10 |

This is **62 base + 37 constrained = 99 configurations**. The default admits
the 89 nonpreview configurations; `-IncludePreviewVm` on sizing or assessment
also admits all ten Ebdsv6 Preview sizes. Selection still returns one smallest
feasible VM option, active cores then memory; ties prefer newer generations then catalog ID.
No CPU-generation uplift or global cheapest-price claim is made.

`VmFamilies` stores every published base resource row and its explicit
`ConstrainedVCores` list. Constrained sizes inherit the parent memory/storage/I/O
contract, not an extrapolated resource ratio. The Edsv6 constrained overview's
inconsistent active-core column is reconciled with the active-core naming
suffix; the Eadsv6 overview omission is reconciled with 11 exact public retail
SKU identities. All 99 SKU identities have separately reviewed Windows and
base-compute meters. These identities are not regional deployment guarantees.
The 96-core AMD v6 memory is **672 GiB**, not 768; the largest Intel sizes are
`E192ids_v6` (1,832 GiB) and `E372ids_v7` (2,832 GiB).

`VCores` is usable/active CPU; `BaseVCores` and `BaseVmSize` identify the parent.
`LocalTempGB = LocalTempDisks * LocalTempDiskGB` includes all devices. For
example, four 440-GiB NVMe devices provide 1,760 GiB only with appropriate
volume/file placement. The capacity is not an assumed preformatted D: drive.
NVMe initialization, tempdb recreation after host changes, Generation 2
Windows/SQL image eligibility, sector compatibility, local free space, and
steady-state write performance require verification.

Ebdsv5 uses the [NVMe remote-storage specification table](https://learn.microsoft.com/en-us/azure/virtual-machines/sizes/memory-optimized/ebdsv5-ebsv5-series#ebdsv5-series-nvme),
not the lower SCSI limits. The sustained Premium SSD and Ultra/Premium SSD v2
columns are stored separately; burst columns are never used.
`RemoteDiskController = NVMe` is an explicit deployment requirement on every
VM recommendation, not inferred from local disk type. Ebdsv5's
`LocalTempDiskType = SSD` is one logical temporary volume with its published
per-VM capacity (75-3,800 GiB), not raw local NVMe. Reserve pagefile/other
usage and recreate tempdb before SQL startup after host changes. In contrast,
v6/v7 expose `LocalTempDiskType = NVMe` and need raw-device initialization.
E112ibds_v5 is NVMe-only, with 672 GiB memory, 3,800 GiB temporary SSD,
64 data-disk attachments, and sustained Premium SSD limits of 260,000 IOPS /
8,000 MB/s. The NVMe profile requires Generation 2 and a compatible image.
No constrained Ebdsv5 variants appear in the reviewed documentation or exact
public family meters; no theoretical half/quarter-core sizes are generated.

All **14 base Premium SSD LRS tiers P1-P80**, full configurable Premium SSD v2
and full configurable Ultra ranges participate in independent layout searches.
`MaxAdvancedIops` / `MaxAdvancedThroughputMBps` preserve the distinct
v2/Ultra VM envelope, including constrained-parent inheritance. E112ibds_v5
supports 400,000 IOPS / 10,000 MB/s for these types, not its Premium SSD limits.
SCSI profiles, diskless/ARM VMs, other VM families/generations,
reservations, and custom HA are outside the explicit scope, not asserted
infeasible. This is not an exhaustive Azure-wide no-fit conclusion. The old
nine-entry mixed D/E v5 subset remains removed; only the full explicitly added
Ebdsv5 family competes with the full v6/v7 families.
Historical exports remain readable; pricing an old removed CatalogId requires
the matching older module/catalog rather than silently remapping it to another family.

Capacity/memory `GB` fields use the SQL/Azure sizing convention of GiB.
`MBps` fields use **decimal MB/s**; SQL log MiB/s values are explicitly converted
by 1.048576. VM disk throughput is already decimal MB/s. VM remote limits are
uncached sustained limits, with no burst or cache uplift. Unknown constraints
are null, not zero or assumed unlimited. Missing mandatory constraints require
an insufficient-metadata/provisional sizing result. Capacity/CPU matching is
not a guaranteed workload performance equivalence. Hyperscale local IOPS are separately exposed as
`MaxLocalIops`, not advertised as total remote I/O capacity.

`MaxDataGB` for MI is **reserved aggregate instance storage**, including log and
BC tempdb. It is not an independently available data allowance. `MaxLogGB` is
null for MI: the documented 2-TiB limit is per log file, not total instance log.
GP/next-gen tempdb logs have a separate 120-GiB limit, checked with storage growth.
Classic GP per-file performance and per-database log-rate limits still require
layout-specific verification; aggregate I/O is not a per-file guarantee.
Next-gen GP has explicit per-core IOPS and throughput caps and a configured
IOPS allocation. Included IOPS is `min(core cap, max(300, 3 * reserved GiB))`.
Required IOPS also accounts for throughput above the guaranteed 75 MB/s floor
using `ceil(required MB/s * 30)`. Throughput is capped by the documented
core-size limit. GP/next-gen remote I/O excludes local tempdb; BC shared local
I/O includes it. Observed system-database allocations are included in MI
reserved storage. Observed file counts and grown per-file capacity enforce
the documented instance/database/data/log-file limits.
BC throughput is explicitly documented as unlimited rather than mislabeled
as an unpublished limit; this is not an absence of the separate IOPS/log caps.
Hyperscale's unlimited log is represented by null plus its explanatory note.
Gen5 SQL Database GP/BC log caps apply at the catalog's maximum data allocation;
smaller allocations require checking the proportional log limit.

VM SQL targets deliberately cover Standard/Enterprise SQL 2016-2025 only; an
older source needs an explicit target choice, never an implicit upgrade. Windows
Standard-edition SQL CPU demand is capped at 24 virtual cores through SQL 2022,
and 32 for SQL 2025; a larger VM does not bypass this SQL limit. Host CPU demand
is checked separately, so non-SQL activity can still require a larger VM.
OS/image compatibility, edition-specific buffer-pool/feature limits, deployment availability,
quotas, and source ESU rights require separate verification. Public rates cannot
establish subscription or regional deployability.

## Exact pricing model

`retail-reference.json` contains **projected real API responses**, captured by
narrow public queries on 2026-10-22 and premium Hyperscale compute queries on
2026-10-23. Its common fields are restored by unit tests. The additional
`vm-retail-reference.json` contains all 198 real Windows/base VM identities,
14 disk tiers, two per-core SQL license meters and eight real v2/Ultra
capacity/IOPS/throughput tier rows reviewed 2026-10-27 (222 rows total).
It is evidence for the mappings, **not** an automatic offline fallback. Fixture
prices/dates are historical snapshots. Update mappings only after reviewing new
representative responses and documentation; do not fuzzy-match renamed products.

- GP/BC Gen5 SQL Database: exact
  `SQL Database Single/Elastic Pool {General Purpose|Business Critical} - Compute Gen5`,
  SKU/meter `vCore`, ARM SKU `SQLDB_{GP|BC}_Compute_Gen5`.
- Hyperscale Gen5: `SQL Database SingleDB/Elastic Pool Hyperscale - Compute Gen5`,
  ARM SKU `SQLDB_HyperScale_Compute_Gen5`.
- Hyperscale premium: `SQL Database Single/Elastic Pool Hyperscale - Premium Series Compute`,
  ARM SKU `SQLDB_HyperScale_Compute_Premium`; memory-optimized uses
  `SQL Database Single/Elastic Pool Hyperscale - Premium Series Memory Optimized Compute`,
  ARM SKU `SQLDB_HyperScale_Compute_Premium_Memory_Optimized`. Both use exact
  SKU/meter `vCore`, per vCore/hour. Neither substitutes a Gen5 price if its own
  meter is missing. The shared product names mention pools, but these estimates
  model only provisioned single databases, not pools or serverless.
- MI: `SQL Managed Instance {General Purpose|Business Critical} - Compute Gen5`
  or `- Premium Series [Memory Optimized ]Compute`, ARM SKU
  `SQLMI_{GP|BC}_Compute_{Gen5|Premium|Premium_Memory_Optimized}`.
- Next-gen GP uses the same baseline GP compute/license/storage identities,
  as explicitly documented by Microsoft, plus exact
  `SQL Managed Instance General Purpose - Storage`, SKU/meter/ARM SKU
  `Additional IOPS`, unit `1 IOPS/Month`, for provisioned IOPS above the included
  amount. `ProvisionedIops` is mandatory for next-gen quotes; missing IOPS is
  not assumed free. API rates are used directly, not inferred by dividing a
  storage rate.
- Flexible-memory premium next-gen GP uses its premium compute product,
  SKU `Addl Memory`, meter `Addl Memory Additional Memory`, ARM `Addl Memory`;
  BC uses SKU `Addl Mm`, meter `Addl Mm Additional Memory`, ARM
  `Additional Memory`. Both use `1 GB/Hour` for allocated minus default memory.
  AHB omits SQL license charges, not additional IOPS or memory.
- GP/BC SQL Database and classic MI PAYG add the matching tier's **separate**
  `- SQL License` product, SKU/meter `vCore`, region **`Global`**, per vCore/hour.
  Base compute alone is **not PAYG** for those tiers.
  SQL AHB omits that license charge under user-asserted entitlement; it does not
  manufacture a discount or substitute DevTest prices.
- New Hyperscale databases have no SQL software license fee. Their PAYG quote
  does not require a license meter; their AHB quote is `NotEligible`. Legacy
  existing-Hyperscale AHB arrangements are not modeled.
- PaaS storage uses exact `{tier} Data Stored`, `1 GB/Month` meters.
  GP/BC SQL Database bills the configured data reservation (`ReservedStorageGB`)
  **plus 30%** for the automatic log allowance. The data reservation must satisfy
  the proportional log-capacity limit; billing the allowance does not increase
  that configured data cap. Hyperscale bills allocated data with a ten-GiB
  minimum and no log surcharge. Log/tempdb are not extra managed disks.
  MI rounds data+log (+BC tempdb) to at least 32 GiB in 32-GiB increments.
  Hyperscale has no extra replica in this model.
  Backup overages/LTR are excluded; do not charge the included GP/BC backup
  allowance again. Catalog maxima are not automatically billable quantities.
- VM products and identities are explicit per family, not inferred universally
  from the hardware label. Edsv6 and Eadsv6/v7 use
  `Virtual Machines {family} Series[ Windows]`, SKU/meter display names such as
  `E32-8ads v7`. Edsv7 uses `Virtual Machines Edsv7-series Windows` or
  `Virtual Machines Edsv7-series Linux`; Ebdsv6 uses
  `Virtual Machines Ebdsv6-Series Windows` or `... Linux`.
  Their SKU/meter names are full ARM names such as `Standard_E4bds_v6`.
  Ebdsv5 uses `Virtual Machines Ebdsv5 Series[ Windows]`, SKU names such as
  `Standard_E4bds_v5`, and meter names such as `E4bds v5`; SKU and meter
  identities are separate fields (`ComputeSku` / `ComputeMeter`).
  Every mapping also requires the exact ARM SKU. Compute quantity is one
  VM/hour, including constrained VMs whose rates retain the parent amount.
- SQL licensing uses `Virtual Machines Licenses`,
  `SQL Server {Standard|Enterprise}`, SKU `1 vCore`, meter `1 vCore License`,
  **empty** meter region, with `max(4, active vCPUs)` per hour. This scales
  exactly to high-core VMs without inventing absent sized per-VM meters.
  Disabled parent cores are not licensed or counted as available CPU.
- SQL/Windows AHB switches are independent. Windows AHB uses the exact
  non-Windows VM base-compute product. SQL AHB omits SQL license charges.
  No Windows or SQL license purchase/SA cost is estimated.
- VM `DiskLayout` requires `{DiskId, Count, Role}` (`Purpose` aliases Role):
  OS/Data/Log/Tempdb. One OS disk >=128 GiB and separate data/log disks are
  mandatory. Sizing prefers included local temporary capacity for tempdb when
  its grown allocation fits; otherwise it uses explicit managed tempdb disks
  rather than upsizing solely for local capacity. `TempdbPlacement` records
  the choice; local storage is not an entry in the billable `DiskLayout`.
  Local v6/v7 capacity is aggregated across NVMe devices, subject to raw-device
  initialization, volume/file placement, available space, and unverified
  steady-state write performance. Ebdsv5 uses its per-VM temporary SSD capacity.
  No ephemeral OS uses this allocation.
  Disks use exact
  `Premium SSD Managed Disks`, SKU `{tier} LRS`, meter `{tier} LRS Disk`,
  `1/Month`. Disk Mount, ZRS, snapshots, and burst meters are not interchangeable.
  No paid bursting/performance-plus/shared disks are supported.

The mappings intentionally select **SKU `vCore`**, not similarly named sized
aliases such as `2 vCore` with different billing quantities. Current vCore
responses can be nonprimary; their published primary flag is exposed rather
than filtering them out or treating meter ID alone as a unique rate.

Next-gen baseline and extra-resource mappings have been verified against
Microsoft's billing documentation and representative public API responses.
Other regions/currencies are resolved against the same exact identities, not
assumed to have the fixture rates. An absent or ambiguous mandatory rate makes
the total null (`Partial`/`Unavailable`). A published zero is retained and
marked `PublishedZeroRate`; missing rates are never treated as zero.

## Cache and result interfaces

`Get-SsaPriceEstimate -Recommendation object[] -Region eastus` emits PAYG and
AHB quotes; without an applicable AHB switch the AHB quote is `NotEligible`.
New Hyperscale databases remain `NotEligible` even when that switch is supplied.
`Currency` defaults to USD and `HoursPerMonth` to 730. Monthly storage/disks
assume a full provisioned month, independently of compute running hours.

`-PriceData object[]` accepts explicit API-shaped data and **never** falls back
to the network, even when empty or incomplete. `-CachePath` is a directory
(default `.\.ssa-pricing-cache`). Each region/currency/API-version JSON envelope
records exact query coverage and retrieval time. Freshness is seven days.
`-Offline` never performs HTTP; stale use requires `-AllowStaleCache`.
An explicit stale permission also allows cache use after a failed online refresh.
No automatic unmarked fallback occurs. Pagination permits only HTTPS
`prices.azure.com:443/api/retail/prices`, refuses redirects/loops, and limits
pages. 429/5xx receive at most three retries, honoring Retry-After up to a
120-second bounded wait; larger values require retrying later.

Quotes expose required contract fields plus known subtotal, provenance,
freshness, mapping version, benefits, and exclusions. Components expose exact
meter identity, billing quantity/unit, published rate, effective date,
retrieval time, and zero-rate distinction. Decimal arithmetic is unrounded
until presentation. Missing required components leave `TotalMonthly = null`;
`KnownMonthly` is never presented as the complete total.
