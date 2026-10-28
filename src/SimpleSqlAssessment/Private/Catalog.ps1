function New-SsaCatalogCandidate {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Creates an in-memory specification object only.')]
    param([string]$Id, [string]$Target, [string]$ServiceTier, [string]$Hardware, [int]$VCores, $MemoryGB, $Source, [string]$CatalogVersion)
    [pscustomobject][ordered]@{
        Id = $Id; Target = $Target; ServiceTier = $ServiceTier; Hardware = $Hardware
        VCores = $VCores; MemoryGB = $MemoryGB; MaxDataGB = $null; MaxLogGB = $null
        MaxTempdbGB = $null; MaxTempdbLogGB = $null; MaxIops = $null; MaxThroughputMBps = $null; MaxLogMBps = $null
        MaxDatabases = $null; VmSize = $null; SqlMajorVersions = @(); SupportedEditions = @()
        MaxDataDisks = $null; LocalTempGB = $null; MaxLocalIops = $null
        MaxAdvancedIops = $null; MaxAdvancedThroughputMBps = $null
        ComputeProduct = $null; ComputeArmSku = $null; ComputeSku = $null; ComputeMeter = $null; WindowsProduct = $null
        Generation = $null; Preview = $false; BaseVCores = $null; BaseVmSize = $null
        LocalTempDisks = $null; LocalTempDiskGB = $null; LocalTempDiskType = $null; RemoteDiskController = $null
        DefaultMemoryGB = $MemoryGB; AdditionalMemoryGB = 0; RegionalMaxDataGB = $null
        StorageRegions = @(); SupportedRegions = @(); IoModel = $null; ThroughputUnbounded = $false
        MaxLogFileGB = $null; MaxDataFileGB = $null; MaxFilesPerInstance = $null; MaxFilesPerDatabase = $null
        StorageScope = 'DatabaseData'; ComputeModel = 'Provisioned'; RegionAvailability = 'NotVerified'
        Confidence = 'DocumentedSubset'; SourceUrl = $Source.Url; SourceRevision = $Source.Revision
        CatalogVersion = $CatalogVersion; Notes = @()
    }
}

function ConvertTo-SsaVmRetailName {
    param([string]$VmSize, [string]$Format)
    if ($Format -eq 'DisplayName') { return $VmSize.Replace('Standard_', '').Replace('_', ' ') }
    if ($Format -eq 'ArmSku') { return $VmSize }
    throw "Unknown VM retail identity format: $Format."
}

function Get-SsaManagedInstanceCapacity {
    param($Candidate, [string]$Region)
    $supported = @(Get-SsaValue $Candidate 'SupportedRegions' @())
    if ($Region -and $supported.Count -and $Region -notin $supported) { return $null }
    $maximum = $Candidate.MaxDataGB
    $regional = Get-SsaValue $Candidate 'RegionalMaxDataGB'
    $regions = @(Get-SsaValue $Candidate 'StorageRegions' @())
    if ($null -ne $regional -and (-not $Region -or $Region -in $regions)) { $maximum = $regional }
    [pscustomobject]@{ MaxDataGB = $maximum; RegionUnverified = (-not $Region -and ($supported.Count -gt 0 -or $null -ne $regional)) }
}

function Get-SsaCatalog {
    $data = Read-SsaJson (Join-Path $script:SsaModuleRoot 'Catalogs\targets.json')
    $sources = @{}
    foreach ($source in $data.Sources) { $sources[$source.Id] = $source }
    $db = New-Object 'System.Collections.Generic.List[object]'
    foreach ($family in $data.SqlDatabaseFamilies) {
        foreach ($row in $family.Rows) {
            $item = New-SsaCatalogCandidate -Id ($family.SloPrefix + '_' + $row.VCores) -Target SqlDatabase -ServiceTier $family.ServiceTier -Hardware $family.Hardware -VCores $row.VCores -MemoryGB $row.MemoryGB -Source $sources.sqldb -CatalogVersion $data.Version
            $item.SourceUrl += '#' + $family.SourceSection
            $item.ComputeProduct = $family.ComputeProduct
            $item.ComputeArmSku = $family.ComputeArmSku
            $item.MaxTempdbGB = $row.MaxTempdbGB
            $item.MaxDatabases = 1
            $item.MaxLogMBps = $row.MaxLogMiBps * 1.048576
            if ($family.ServiceTier -eq 'Hyperscale') {
                $item.MaxDataGB = $family.MaxDataGB
                $item.MaxLocalIops = $row.MaxLocalIops
                $item.Notes += 'Unlimited log capacity is represented by null. MaxIops is unknown: local SSD IOPS are not an end-to-end remote page-server limit. No secondary replica is modeled.'
            } else {
                $item.MaxDataGB = $row.MaxDataGB
                $item.MaxLogGB = $row.MaxLogGB
                $item.MaxIops = $row.MaxIops
                $item.Notes += 'GP/BC log limits depend on provisioned maximum data size; listed limits are at catalog maximum, not a guarantee for smaller allocations.'
            }

            $item.Notes += 'Memory and resource limits are explicit values from this tier/hardware/core table, not inferred across tiers or extrapolated per core. MBps fields are decimal MB/s; documented MiB/s converted by 1.048576. No hardware-generation CPU uplift is assumed.'
            $db.Add($item)
        }
    }
    $mi = New-Object 'System.Collections.Generic.List[object]'
    foreach ($family in $data.ManagedInstanceFamilies) {
        foreach ($cores in $family.Cores) {
            $tier = $family.ServiceTier
            $id = 'MI_' + $tier + '_' + $family.Hardware + '_' + $cores
            $memory = [math]::Round([math]::Min([double]$family.MemoryCapGB, [double]$family.MemoryPerCore * $cores), 1)
            $item = New-SsaCatalogCandidate -Id $id -Target ManagedInstance -ServiceTier $tier -Hardware $family.Hardware -VCores $cores -MemoryGB $memory -Source $sources.mi -CatalogVersion $data.Version
            $bounds = @($family.StorageLimits | Where-Object { $cores -in $_.Cores })
            if ($bounds.Count -ne 1) { throw "Missing or ambiguous MI storage specification for $id." }
            $item.SourceUrl += '#number-of-vcores'
            $item.Confidence = 'DocumentedStandaloneMatrix'
            $item.MaxDataGB = $bounds[0].MaxDataGB
            $item.RegionalMaxDataGB = Get-SsaValue $bounds[0] 'RegionalMaxDataGB'
            if ($null -ne $item.RegionalMaxDataGB) { $item.StorageRegions = @($data.ManagedInstancePremiumRegions) }
            if ($family.Hardware -eq 'Premium-series-memory-optimized') { $item.SupportedRegions = @($data.ManagedInstancePremiumRegions) }
            $item.StorageScope = 'InstanceDataAndLog'
            $item.MaxDatabases = 100
            $item.MaxTempdbGB = [math]::Min(1920, 24 * $cores)
            $item.MaxTempdbLogGB = 120
            $item.MaxLogMBps = [math]::Min(120, 4.5 * $cores) * 1.048576
            $item.MaxLogFileGB = 2048
            $item.MaxDataFileGB = 8192
            $item.MaxFilesPerInstance = 280
            $item.IoModel = 'PerFile'
            if ($tier -eq 'NextGenGeneralPurpose') {
                $io = @($data.ManagedInstanceNextGenIo | Where-Object { $cores -in $_.Cores })
                if ($io.Count -ne 1) { throw "Missing or ambiguous next-gen MI I/O specification for $id." }
                $item.IoModel = 'Provisioned'
                $item.MaxIops = $io[0].MaxIops
                $item.MaxThroughputMBps = $io[0].MaxThroughputMBps
                $item.MaxDatabases = 500
                $item.MaxDataFileGB = $item.MaxDataGB
                $item.MaxFilesPerInstance = $null
                $item.MaxFilesPerDatabase = 4096
                if ($family.Hardware -ne 'Gen5') { $item.MaxLogMBps = [math]::Min(192, 4.5 * $cores) * 1.048576 }
                $item.Notes += 'Next-gen GP uses verified GP baseline meters plus additional IOPS and, when configured, flexible-memory charges.'
            } elseif ($tier -eq 'BusinessCritical') {
                $item.IoModel = 'Local'
                $item.StorageScope = 'InstanceDataLogAndTempdb'
                $item.MaxTempdbGB = $item.MaxDataGB
                $item.MaxTempdbLogGB = $null
                $item.MaxDataFileGB = $item.MaxDataGB
                $item.MaxFilesPerInstance = $null
                $item.MaxFilesPerDatabase = 32767
                $item.MaxIops = [math]::Min(320000, 4000 * $cores)
                $item.ThroughputUnbounded = $true
                $logCap = 192
                if ($family.Hardware -eq 'Gen5') { $logCap = 160 }
                $item.MaxLogMBps = [math]::Min($logCap, 16 * $cores) * 1.048576
            }
            $label = 'General Purpose'; $short = 'GP'
            if ($tier -eq 'BusinessCritical') { $label = 'Business Critical'; $short = 'BC' }
            $item.ComputeProduct = 'SQL Managed Instance ' + $label + ' - Compute Gen5'
            $item.ComputeArmSku = 'SQLMI_' + $short + '_Compute_Gen5'
            if ($family.Hardware -ne 'Gen5') {
                $item.ComputeProduct = 'SQL Managed Instance ' + $label + ' - Premium Series Compute'
                $item.ComputeArmSku = 'SQLMI_' + $short + '_Compute_Premium'
                if ($family.Hardware -eq 'Premium-series-memory-optimized') {
                    $item.ComputeProduct = 'SQL Managed Instance ' + $label + ' - Premium Series Memory Optimized Compute'
                    $item.ComputeArmSku += '_Memory_Optimized'
                }
            }
            $item.Notes += 'All documented standalone core sizes are represented; no instance pools. Memory follows the documented hardware ratio and cap, with no CPU-generation uplift. MaxDataGB is aggregate reserved data/log storage plus BC tempdb, not an independent data allowance. Per-log-file limit is 2048 GiB. Higher regional storage caps and memory-optimized hardware require a supported region.'
            $mi.Add($item)
            if ($family.Hardware -eq 'Premium-series' -and $tier -in @('NextGenGeneralPurpose','BusinessCritical')) {
                $flex = @($data.ManagedInstanceFlexibleMemory | Where-Object VCores -EQ $cores)
                if ($flex.Count -ne 1) { throw "Missing or ambiguous flexible-memory specification for $id." }
                foreach ($amount in @($flex[0].MemoryGB | Where-Object { $_ -gt $memory })) {
                    $variant = $item.PSObject.Copy()
                    $variant.Id = $id + '_Memory' + $amount
                    $variant.MemoryGB = $amount
                    $variant.AdditionalMemoryGB = $amount - $memory
                    $variant.SourceUrl = $sources.mi.Url + '#flexible-memory'
                    $variant.Notes += 'This exact API memory allocation is explicitly documented; extra memory is billed per GB/hour.'
                    $mi.Add($variant)
                }
            }
        }
    }
    $vms = New-Object 'System.Collections.Generic.List[object]'
    foreach ($family in $data.VmFamilies) {
        foreach ($row in $family.Rows) {
            $sourceId = $family.Hardware.ToLowerInvariant()
            $item = New-SsaCatalogCandidate -Id $row.VmSize -Target SqlVm -ServiceTier VirtualMachine -Hardware $family.Hardware -VCores $row.VCores -MemoryGB $row.MemoryGB -Source $sources[$sourceId] -CatalogVersion $data.Version
            foreach ($field in @('VmSize', 'MaxDataDisks', 'MaxIops', 'MaxThroughputMBps', 'LocalTempDisks', 'LocalTempDiskGB')) { $item.$field = $row.$field }
            $item.MaxAdvancedIops = $row.MaxAdvancedIops
            $item.MaxAdvancedThroughputMBps = $row.MaxAdvancedThroughputMBps
            $item.LocalTempGB = $row.LocalTempDisks * $row.LocalTempDiskGB
            $item.Generation = $family.Generation
            $item.Preview = $family.Preview
            $item.LocalTempDiskType = $family.LocalTempDiskType
            $item.RemoteDiskController = $family.RemoteDiskController
            $item.BaseVCores = $row.VCores
            $item.BaseVmSize = $row.VmSize
            $item.ComputeProduct = $family.ComputeProduct
            $item.WindowsProduct = $family.WindowsProduct
            $item.ComputeArmSku = $item.VmSize
            $meterFormat = Get-SsaValue $family 'MeterNameFormat' $family.MeterFormat
            $item.ComputeSku = ConvertTo-SsaVmRetailName $item.VmSize $family.MeterFormat
            $item.ComputeMeter = ConvertTo-SsaVmRetailName $item.VmSize $meterFormat
            $item.Confidence = 'DocumentedScopedMatrix'
            $item.SqlMajorVersions = @(13, 14, 15, 16, 17)
            $item.SupportedEditions = @('Standard', 'Enterprise')
            $item.StorageScope = 'ExplicitManagedDiskLayout'
            $item.Notes = @(
                'All published base sizes in this explicitly scoped x64 E-series family are included. MaxIops/MaxThroughputMBps are sustained uncached Premium SSD limits; MaxAdvancedIops/MaxAdvancedThroughputMBps are the distinct sustained Premium SSD v2/Ultra envelope. All require the NVMe remote controller, not SCSI, burst or caching. No CPU-generation uplift or HA/DR equivalence is assumed. Verify a Generation 2 NVMe-compatible Windows/SQL image and sector-size compatibility.',
                'SQL 2016-2025 Standard/Enterprise targets require supported OS/image verification. Standard SQL CPU is capped at 24 virtual cores through SQL 2022 and 32 for SQL 2025. Buffer-pool/feature limits require separate checks; process memory is not buffer-pool attribution. Regional deployment availability and quota are not established by documentation or retail prices.'
            )
            if ($item.LocalTempDiskType -eq 'NVMe') {
                $item.Notes += 'LocalTempGB is device count times per-device GiB, not one device capacity. Raw local NVMe devices require initialization and formatting; aggregate capacity requires a striped temporary volume or appropriate multi-file placement. Recreate tempdb before SQL startup after host changes. Do not put durable data or an ephemeral OS on this tempdb capacity.'
            } else {
                $item.Notes += 'Ebdsv5 local temporary storage is one logical SSD volume with the published per-VM capacity, not the raw local NVMe devices in v6/v7. Reserve pagefile/other usage and recreate tempdb before SQL startup after host changes. The modeled NVMe interface is for remote managed disks; the SCSI profile has lower remote limits and is not interchangeable. E112ibds_v5 is NVMe-only. Do not put durable data or an ephemeral OS on this tempdb capacity.'
            }
            $vms.Add($item)
            foreach ($active in @(Get-SsaValue $row 'ConstrainedVCores' @())) {
                if ($active -notin @(($row.VCores/2), ($row.VCores/4))) { throw "Invalid constrained vCPU mapping for $($row.VmSize)." }
                $variant = $item.PSObject.Copy()
                $variant.VCores = $active
                $variant.VmSize = $row.VmSize -replace ('^Standard_E' + $row.VCores), ('Standard_E' + $row.VCores + '-' + $active)
                $variant.Id = $variant.VmSize
                $variant.ComputeArmSku = $variant.VmSize
                $variant.ComputeSku = ConvertTo-SsaVmRetailName $variant.VmSize $family.MeterFormat
                $variant.ComputeMeter = ConvertTo-SsaVmRetailName $variant.VmSize $meterFormat
                $variant.Notes += 'This exact constrained SKU has a reviewed public meter. Only active vCPUs can satisfy CPU demand and incur SQL licensing (minimum four); memory, disk, I/O, and underlying VM/Windows cost retain the parent size. No arbitrary half/quarter-core combinations are generated.'
                $vms.Add($variant)
            }
        }
    }
    $disks = @(
        foreach ($disk in $data.Disks) {
            [pscustomobject]@{
                Id = $disk.Id; Tier = $disk.Tier; SizeGB = $disk.SizeGB
                Iops = $disk.Iops; ThroughputMBps = $disk.ThroughputMBps
                Redundancy = 'LRS'; DiskType = 'PremiumSSD'; SourceUrl = $sources.disk.Url
                SourceRevision = $sources.disk.Revision; CatalogVersion = $data.Version
                Notes = 'Base performance, no paid bursting, performance-plus, shared-disk mounts, snapshots, or transactions.'
            }
        }
    )
    [pscustomobject]@{
        Version = $data.Version; SourceUrls = @($data.Sources | ForEach-Object { $_.Url })
        Sources = $data.Sources; ReviewedAt = $data.ReviewedAt
        SqlDatabase = $db.ToArray(); ManagedInstance = $mi.ToArray(); Vm = $vms.ToArray(); Disks = $disks; DiskProfiles = $data.DiskProfiles
        Coverage = 'All documented allowed provisioned SQL Database sizes and standalone MI tier/hardware/core sizes, including every documented flexible-memory allocation. VM scope: x64 Ebdsv5, Edsv6, Eadsv6, Edsv7, Eadsv7 and opt-in Ebdsv6 Preview, all 62 base sizes plus 37 published constrained variants (99 total, 89 nonpreview), with NVMe remote controllers and local temporary storage. Managed disk alternatives: all 14 base Premium SSD LRS tiers P1-P80, full 1-65536 GiB Premium SSD v2 and 4-65536 GiB Ultra ranges with configurable IOPS/throughput and separate per-VM envelopes. OS disks remain Premium SSD. SCSI, other VM families/generations, ARM and diskless VMs are outside scope, not asserted infeasible. DC-series, serverless, pools and retired hardware are excluded. Specifications and prices do not establish region/zone, subscription, image or quota eligibility. Null mandatory constraints mean insufficient metadata, not unlimited performance.'
    }
}
