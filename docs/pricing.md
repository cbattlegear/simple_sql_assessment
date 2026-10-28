# Public retail pricing

Pricing calls the unauthenticated
[Azure Retail Prices API](https://learn.microsoft.com/en-us/rest/api/cost-management/retail-prices/azure-retail-prices)
for exact public product/SKU/meter identities. It does not require an Azure
subscription login and does not send source definitions or inventory.

SQL Database compute mappings cover all 77 included provisioned configurations:
GP/BC Gen5, plus Hyperscale Gen5, premium, and memory-optimized premium. Each
hardware family uses its own verified compute product and ARM SKU, multiplied
by the selected vCore count. Missing premium prices are never replaced with
Gen5 rates. Capacity remains sourced from Microsoft Learn, not price meters;
DC-series, serverless, and pools are not recommendations.

```powershell
$skus = Get-SsaSkuRecommendation -CollectionPath 'C:\Assessments\Server01\collection' |
    Where-Object Status -NE Unavailable
$quotes = Get-SsaPriceEstimate -Recommendation $skus `
    -Region eastus -Currency USD -HoursPerMonth 730 `
    -CachePath 'C:\Assessments\Server01\pricing-cache' `
    -SqlHybridBenefit -WindowsHybridBenefit
```

Filter out unavailable sizing results before manually calling the pricing
command. `Invoke-SsaAssessment` does that automatically.

## Included components

GP/BC SQL Database and classic MI PAYG combine the exact **base compute and
separate SQL license meters**, plus billable storage. Base compute alone is not
PAYG for those tiers. SQL AHB omits SQL license charges only under the caller's
entitlement assertion.

GP/BC SQL Database storage bills the configured data reservation plus the
automatic **30% billable log allowance**, not just the observed data allocation.
The configured data reservation must also satisfy the proportional log-capacity
limit. `ReservedStorageGB` remains the configured data cap; the Storage component
quantity includes the extra log allowance, which does not consume that data cap.

New Hyperscale databases have **no SQL software license fee** and do not qualify
for AHB. Their PAYG quote needs only compute and allocated data storage, with a
**10-GiB storage billing minimum** and no log surcharge. The AHB scenario is
`NotEligible`, even with `-SqlHybridBenefit`. Legacy existing-database AHB
arrangements are outside this new-migration model. These distinctions follow the
[vCore billing rules](https://learn.microsoft.com/en-us/azure/azure-sql/database/service-tiers-sql-database-vcore#data-and-log-storage)
and [Hyperscale pricing model](https://learn.microsoft.com/en-us/azure/azure-sql/database/service-tier-hyperscale#hyperscale-pricing-model).

MI pricing covers every standalone base core size and every documented premium
flexible-memory allocation. Next-gen GP uses the documented classic GP
compute/license/storage baseline, **plus separately billed additional IOPS and
memory**. `ProvisionedIops` must be supplied; the quote never assumes a missing
allocation is free. Included IOPS is `min(core cap, max(300, 3 * reserved GiB))`;
only provisioned IOPS above that amount is billed, using the exact public
`Additional IOPS` meter for a full month. Flexible memory bills allocated minus
default memory per GB/hour. AHB discounts neither extra resource.
See the [next-gen billing model](https://learn.microsoft.com/en-us/azure/azure-sql/managed-instance/service-tiers-next-gen-general-purpose-use#architectural-model)
and [flexible-memory billing rules](https://learn.microsoft.com/en-us/azure/azure-sql/managed-instance/resource-limits#pricing).
Regional hardware and storage limits apply to explicit price requests too.

VM PAYG combines Windows VM compute, separately priced SQL licensing, and every
required managed disk in the recommended layout. SQL and Windows AHB switches
are independent. Storage/disks are priced as a full provisioned month even
when `HoursPerMonth` changes compute running hours.

Exact VM compute identities cover all **99 scoped E-series sizes**,
including 37 constrained variants and ten explicitly opt-in Ebdsv6 Preview
sizes. VM compute is charged once per VM/hour, not per active vCPU. Constrained
sizes have their own exact public meters and retain parent compute/Windows
cost; they never receive an invented proportional compute discount.
The nine Ebdsv5 sizes use `Virtual Machines Ebdsv5 Series[ Windows]`,
ARM-formatted SKU names such as `Standard_E112ibds_v5`, and different,
display-formatted meter names such as `E112ibds v5`. SKU and meter names are
matched independently; a similar display name is not an alias for the SKU.
NVMe and SCSI remote-controller deployments have the same compute rates,
but sizing models the NVMe performance profile, not the lower SCSI limits.
SQL licensing instead uses the exact `Virtual Machines Licenses` product
`SQL Server Standard` or `SQL Server Enterprise`, SKU `1 vCore`, meter
`1 vCore License`, empty region, with **max(4, active vCPUs)** per hour.
It is not charged on disabled parent cores, and uses the real per-core meter
even at 160/248/372 cores, where matching per-VM sized-license meters are absent.
Missing exact prices never fall back to another generation, parent, or family.
Windows AHB resolves the family's exact base-compute product, which may be
named `Linux`; that meter represents compute without the Windows license,
not a switch to a Linux SQL deployment.

Tempdb on the VM's included local temporary drive has no separate managed-disk
charge. When it cannot fit on that VM's local drive (including storage growth),
the estimate includes the required managed tempdb disks rather than choosing a
larger VM solely for temporary capacity. `TempdbPlacement` and `DiskLayout`
make this distinction visible in the recommendation.
Local capacity sums every local NVMe device for v6/v7, subject to initialization,
appropriate volume/file layout, and available free space. Ebdsv5 uses its
published per-VM temporary SSD volume capacity, not raw local NVMe. All 14 base Premium SSD LRS tiers
P1-P80 have exact disk mappings. Premium SSD v2 and Ultra are independently
sized/priced alternatives, not fixed-tier aliases.

### Configurable disks and latency-informed comparisons

Premium SSD v2 and Ultra each have three public resource meters: capacity
(`1 GiB/Hour`), provisioned IOPS (`1/Hour`) and throughput (`1/Hour`).
Exact identities are `Azure Premium SSD v2` / `Premium LRS` / `Premium LRS
Provisioned {Capacity|IOPS|Throughput (MBps)}`, and `Ultra Disks` / `Ultra LRS` /
`Ultra LRS Provisioned {Capacity|IOPS|Throughput (MBps)}`. ARM SKU is explicitly
empty in these public retail rows, not substituted with the deployment SKU.
V2 includes 3,000 IOPS and 125 MB/s **per disk**; only provisioned excess is
billed. Paid rows have `tierMinimumUnits` 3,000 and 125 respectively. The
zero-rate baseline rows are not mistaken for free excess performance.
Ultra bills all provisioned IOPS and throughput. Baseline v2 resources are
shown in the layout and incur no extra-performance component.

Hourly provisioned disk resources use **730 hours/month**, independently of
compute `HoursPerMonth`. OS disks retain their fixed monthly Premium SSD
rate. Ultra VM reservation charges apply only when Ultra compatibility is
enabled without an attached Ultra disk; these alternatives always attach
Ultra data/log disks, so that surcharge is not added.

**Ultra documentation conflict:** the current
[disk-types reference](https://learn.microsoft.com/en-us/azure/virtual-machines/disks-types)
describes per-GiB capacity billing, but the
[pricing page](https://azure.microsoft.com/en-us/pricing/details/managed-disks/)
still explicitly rounds provisioned capacity to the next size offer (its
200-GiB example bills 256 GiB). This model conservatively rounds **billed**
Ultra capacity to 4, 8, 16, ... 65,536 GiB. Actual provisioned capacity remains
in 1-GiB increments. `BilledSizeGB` is separate from `SizeGB`; confirm actual
billing before purchase. This is a disclosed conservative estimate, not an
assertion that these two references agree.

All three alternatives retain CPU/memory, attachment and type-specific
**sustained** remote VM limits. The pricing-stage suggestion selects the
lowest complete scenario-specific total within the source-latency policy;
it never compares a partial subtotal with a complete cost. It is not a
globally price-optimal VM or striped layout search. Both v2 and Ultra target
submillisecond service; queue depth alone cannot establish that Ultra is
needed. See the [methodology](methodology.md) for thresholds and limitations.

Component output includes meter ID, product/SKU, quantity, unit, published
rate, effective date, retrieval time, and monthly cost. Published zero rates
remain distinguishable from missing prices. Region, currency, and mapping
version are retained. The included retail-reference fixture is historical
test evidence, never a fallback for current quotes.

AHB licensing rights, core minimums, Software Assurance, and qualifying OS/SQL
licenses must be independently verified. The tool neither establishes rights
nor includes the price of acquiring those rights.

## Explicit incompleteness

Quotes are `Complete`, `Partial`, `Unavailable`, or `NotEligible`.
Any missing or ambiguous mandatory component leaves `TotalMonthly` null;
`KnownMonthly` is only a known subtotal. Missing required extra-IOPS or
flexible-memory rates make MI quotes incomplete, just like missing compute,
license, or storage meters.

The model excludes reservations, savings plans, negotiated/EA/CSP discounts,
taxes, currency conversion outside published API rates, license purchase/SA,
backup overages/LTR, snapshots, egress, networking, private endpoints,
monitoring, migration costs, geo-replication, and custom HA/DR topologies.
A single VM is not availability-equivalent to PaaS. This is a scoped public
retail estimate, not a complete TCO calculation or offer.

## Cache and resilience

The cache is keyed by region, currency, API version, and exact query coverage,
with a seven-day freshness window. In the integrated workflow it is under
`OutputPath\pricing-cache`; standalone pricing defaults to
`.\.ssa-pricing-cache`.

`-Offline` makes no HTTP requests. Missing, malformed, incomplete, or stale
cache data yields explicit missing-price results. `-AllowStaleCache` permits
marked stale use offline or after a failed online refresh. Reusing a bundle
in a different output directory does not automatically copy its pricing cache.

`-PriceData` supplies explicit API-shaped rows for controlled analysis and
never silently falls back to online requests. Exact-name matching rejects
confusable DevTest, serverless, pools, replicas, different redundancies,
unrelated disk meters, and duplicate conflicting rates.

Pagination is restricted to the HTTPS Retail Prices API endpoint; loops and
redirects are rejected. Rate-limit/server failures use bounded retries and
Retry-After handling. There is no broad unmarked online/offline fallback.

Detailed identities, billing units, and known catalog limitations are in the
[catalog reference](../src/SimpleSqlAssessment/Catalogs/README.md).
