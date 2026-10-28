# Simple SQL Assessment

A read-only, DMA-inspired PowerShell module for comparing **Azure SQL Database,
Azure SQL Managed Instance, and SQL Server on Azure VMs** from one SQL Server
collection. Version **0.1.0** is an initial pilot implementation, not a replacement
for application regression testing or a migration readiness sign-off.

- Covers all **30 SQL Database and 34 Managed Instance published rule mappings**
  with executable detectors, evidence limitations, and a separate six-check VM pack.
- Captures Windows counters and SQL observations for **seven usable days by default**.
  Capture is optional, durable, and resumable; outages extend the observation window.
- Produces constrained, provisional SKU options and itemized PAYG/Azure Hybrid
  Benefit estimates using the unauthenticated Azure Retail Prices API.
- Writes a standalone **offline HTML report**, JSON, CSV, and PowerShell objects.
  Compatibility and sizing can be rerun without reconnecting to SQL Server.

**Pilot boundary:** no real SQL Server source was available during initial
implementation. Live SQL collection and sustained seven-day operation still need
validation in your environment. An opt-in integration check is provided.

## Requirements and installation

Use Windows x64 with either Windows PowerShell **5.1 / .NET Framework 4.8** or
PowerShell **7.4+**. Source queries target Windows-hosted **SQL Server 2012+**.
The curated VM catalog covers SQL Server **2016-2025**; an older source requires
an explicit target-version choice for VM sizing. VM hardware targets x64
**Ebdsv5, Edsv6, Eadsv6, Edsv7, and Eadsv7**, including published
constrained-vCPU sizes. Ebdsv5 has local temporary SSD; the v6/v7 families
have raw local temporary NVMe. The modeled remote-disk performance requires
an NVMe remote controller and a compatible Generation 2 Windows/SQL image
for every family; image and disk-sector compatibility must be verified.

From this source directory:

```powershell
# Restore only missing, pinned dependencies to .dependencies.
.\build.ps1 -RestoreDependencies
Import-Module .\src\SimpleSqlAssessment\SimpleSqlAssessment.psd1
Test-SsaPrerequisite -SqlInstance 'SERVER\INSTANCE'
```

For a packaged ZIP, extract it and install the runtime dependency separately:

```powershell
Install-Module SqlServer -RequiredVersion 22.4.5.1 -Scope CurrentUser
Import-Module .\src\SimpleSqlAssessment\SimpleSqlAssessment.psd1
```

Module import never installs dependencies. The pinned Microsoft `SqlServer`
module supplies SqlClient and ScriptDom; PowerShell editions use separate
runtime assets. Use a fresh PowerShell process if another SQL library is loaded.
See [permissions and operations](docs/operations.md) before collecting.

## Run an assessment

```powershell
# Static report is available immediately, then seven usable days of capture.
$result = Invoke-SsaAssessment `
    -SqlInstance 'SERVER\INSTANCE' `
    -OutputPath 'C:\Assessments\Server01' `
    -Region eastus

# Compatibility only: no Windows counters or performance-based prices.
$result = Invoke-SsaAssessment `
    -SqlInstance 'SERVER\INSTANCE' `
    -OutputPath 'C:\Assessments\Server01-static' `
    -Region eastus -SkipPerformance
```

Windows integrated SQL authentication is the default. For SQL authentication,
pass a `PSCredential` created with `Get-Credential`; do not put passwords in
scripts. SQL connections are encrypted and validate the server certificate.
`-TrustServerCertificate` is an explicit opt-out, not the default.

AHB is opt-in, based on your entitlement:

```powershell
$result = Invoke-SsaAssessment `
    -CollectionPath 'C:\Assessments\Server01\collection' `
    -OutputPath 'C:\Assessments\Server01' `
    -Region eastus -Currency USD -HoursPerMonth 730 `
    -SqlHybridBenefit -WindowsHybridBenefit
```

`-SqlHybridBenefit` asserts qualifying SQL license rights. The independent
`-WindowsHybridBenefit` switch affects only VM OS licensing. These switches do
not verify or purchase licenses. New Hyperscale databases have no SQL software
license fee and are not AHB-eligible; their PAYG estimate already reflects this.

Preview VMs are excluded by default. To also assess all ten **Ebdsv6 Preview**
sizes, pass `-IncludePreviewVm` to `Invoke-SsaAssessment` or
`Get-SsaSkuRecommendation`. A selected preview option is labeled in the result.
Neither switch deploys anything or establishes preview support/availability.

## Separate collection, capture, and analysis

```powershell
$bundle = New-SsaCollection -SqlInstance 'SERVER\INSTANCE' `
    -CollectionPath 'C:\Assessments\Server01\collection'

Start-SsaPerformanceCapture -CollectionPath 'C:\Assessments\Server01\collection'

# After an interrupted process or repaired connectivity:
Resume-SsaPerformanceCapture -CollectionPath 'C:\Assessments\Server01\collection'

# Reuse an existing pricing cache; no SQL or pricing network calls.
$result = Invoke-SsaAssessment `
    -CollectionPath 'C:\Assessments\Server01\collection' `
    -OutputPath 'C:\Assessments\Server01' -Region eastus -Offline
```

Resume never restores stored credentials: provide `-Credential` again if needed.
It retains the original duration and interval and rebaselines after downtime.
An offline run with no usable cache still produces a report with unavailable
prices, not invented totals. See [recovery and security](docs/operations.md).

## Output

Open `assessment.html` directly in a browser. No server, CDN, installed reporting
tool, or network access is needed to view it. The report includes target
comparison, inventory, findings and coverage filters, performance/gap charts,
SKU constraints, itemized prices, and provenance. External documentation links
are followed only when you choose them.

```text
Server01\
  assessment.html
  assessment.json
  csv\
    target-summary.csv
    findings.csv
    rule-coverage.csv
    recommendations.csv
    cost-components.csv
    performance-summary.csv
  collection\
    inventory.json
    manifest.json
    capture.json
    performance\sample-0000000001.json ...
  pricing-cache\
```

`$result` is the shared PowerShell result model, including output paths in
`$result.OutputFiles`. `Export-SsaAssessment -Assessment $result -OutputPath ...`
regenerates HTML/JSON/CSV without contacting SQL or Azure.

**Treat both bundles and reports as sensitive.** Full definitions and job commands
are excluded from presentation exports, but names, topology, findings, and prices
may still be confidential. Collection bundles retain full definitions and can
contain embedded secrets. Review and protect artifacts before sharing.

## Commands and boundaries

| Command | Purpose |
| --- | --- |
| `Test-SsaPrerequisite` | Check runtime, SQL libraries, source, and optional counters |
| `Get-SsaAssessmentRule` | Inspect published mappings and the separately scoped VM rules |
| `New-SsaCollection` | Create a read-only, local static evidence bundle |
| `Start-SsaPerformanceCapture` | Start durable Windows/SQL capture |
| `Resume-SsaPerformanceCapture` | Validate and resume an existing capture |
| `Invoke-SsaAssessment` | Collect or reassess; size, price, and export all targets |
| `Get-SsaSkuRecommendation` | Calculate provisional options from a captured bundle |
| `Get-SsaPriceEstimate` | Price recommendations, with exact meters and cache support |
| `Export-SsaAssessment` | Write the standalone report and structured exports |

Missing evidence means **NeedsReview**, not compatibility. Application-only
queries, encrypted modules, and unresolved dynamic SQL prevent exhaustive
application coverage. VM upgrade, edition, restore, OS, and external dependency
checks are deliberately bounded. See [rules and sizing](docs/methodology.md).

SQL Database covers **77 provisioned configurations** across all documented
Gen5 GP/BC sizes and Gen5, premium, and memory-optimized premium Hyperscale
sizes. DC-series, serverless, and elastic pools are excluded. Memory and limits
are stored per tier/hardware/core, not extrapolated from a universal ratio.
Managed Instance covers **all 104 standalone base configurations plus all 66
documented flexible-memory alternatives**, with tier/hardware/core-specific
limits and verified next-gen GP additional-IOPS/memory pricing.
VM coverage includes **all 62 base sizes and 37 published constrained variants**
across the six in-scope families: **89 nonpreview sizes plus 10 opt-in Preview
sizes**. Storage compares **all three disk types**: 14 base Premium SSD LRS
tiers P1-P80, configurable Premium SSD v2 (1-65,536 GiB, up to 80,000 IOPS /
2,000 MB/s per disk), and Ultra (4-65,536 GiB, up to 400,000 IOPS / 10,000 MB/s).
Each type gets an independently sized VM/layout and itemized PAYG/AHB quote.
The report suggests the lowest completely priced option within an observed
latency policy, using interval SQL file latency and same-volume disk queues.
This is a heuristic, not a latency SLA or proof that queues are caused by disks.
Missing evidence produces no suggestion. Both newer types target submillisecond
latency; Ultra is not automatically preferred just because queues exist.
OS disks remain Premium SSD; v2/Ultra require no host caching and verified
region/zone/VM compatibility. Ultra capacity estimates conservatively round
billed capacity because Microsoft's pricing and disk-type references conflict.
Other VM families, ARM, and diskless sizes are
outside this explicit scope, not asserted infeasible. These are not live regional
inventories. Tempdb uses the selected VM's local temporary capacity when it fits; otherwise
managed disks are used instead of upsizing solely for temporary capacity.
Raw local NVMe initialization applies to v6/v7; tempdb recreation after host
changes applies to all families. Ebdsv5 includes all nine sizes from 2 to 112
vCPUs, with 75-3,800 GiB of temporary SSD and no invented constrained variants.
Unpublished limits remain explicitly unverified. Taxes, discounts, ancillary
services, backup overages, and custom HA are not complete TCO. See
[pricing details](docs/pricing.md) and the [catalog reference](src/SimpleSqlAssessment/Catalogs/README.md).

Deferred: DTU, serverless, elastic pools, consolidation, reservations, savings
plans, runtime query capture, deployment, migration, and automatic remediation.

## Maintaining SKU coverage

The repository-local custom agent **`sku-maintainer`** is defined in
`.github\agents\sku-maintainer.agent.md` and included in the source ZIP.
Select it in Copilot's custom agent picker and use a prompt such as:

```text
Refresh all supported SQL Database, Managed Instance, SQL VM, and disk SKUs
against current Microsoft documentation and the Azure Retail Prices API.
Update resource limits, regional constraints, exact pricing mappings, tests,
and documentation. Report additions, retirements, and unresolved discrepancies.
```

The agent requires complete supported matrices, not subsets, while preserving
the exclusions, preview gating, tempdb policy, and three-way disk comparison.
It checks specifications separately from prices and does not infer deployment
availability from a retail meter. It is an on-demand agent, not a scheduled job.

## Development

```powershell
.\build.ps1 -RestoreDependencies
.\build.ps1 -Test -Lint
powershell -NoProfile -NonInteractive -ExecutionPolicy RemoteSigned `
    -File .\build.ps1 -Test -Lint
.\build.ps1 -Package

# Explicitly opt into a real-source test using integrated authentication.
$env:SSA_TEST_SQLINSTANCE = 'LAB-SQL\INSTANCE'
.\build.ps1 -Test
```

The build creates `artifacts\SimpleSqlAssessment-0.1.0.zip` without SQL library
binaries, local collections, test artifacts, or credentials. The ZIP preserves
the source layout and includes tests/build tooling. Dependency and
licensing references are in [third-party notices](docs/third-party-notices.md).

Generate an explicitly synthetic, partial-capture demonstration without a SQL
source:

```powershell
.\examples\New-SyntheticAssessment.ps1
# Optionally retrieve real public retail rates for the synthetic SKU choices.
.\examples\New-SyntheticAssessment.ps1 -OutputPath .\artifacts\sample-priced -RefreshPrices
```
