function Get-SsaSkuRecommendation {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$CollectionPath,
        [ValidateRange(1,100)][double]$Percentile = 95,
        [ValidateRange(0,500)][double]$HeadroomPercent = 20,
        [ValidateRange(0,500)][double]$StorageGrowthPercent = 20,
        [ValidatePattern('^[a-z][a-z0-9]+$')][string]$Region,
        [int]$TargetSqlMajorVersion = 0,
        [ValidateSet('Standard','Enterprise')][string]$TargetSqlEdition,
        [switch]$IncludePreviewVm
    )
    $bundle = Read-SsaBundle $CollectionPath
    $performance = Get-SsaPerformanceAnalysis $CollectionPath $bundle $Percentile
    $samples = @($performance.Samples)
    $managedTempdbAssessment = $null
    $catalog = Get-SsaCatalog
    $factor = 1 + $HeadroomPercent/100
    $storageFactor = 1 + $StorageGrowthPercent/100
    $cores = Get-SsaDemand $samples 'UsedCores' '' $Percentile
    $memory = Get-SsaDemand $samples 'MemoryGB' '' $Percentile
    $temp = @($samples | ForEach-Object { $_.Databases } | Where-Object DatabaseId -EQ 2)
    $observedTempdbGB = $null; $observedTempdbLogGB = $null
    if ($temp.Count) {
        $observedTempdbGB = [Math]::Ceiling([double](($temp | ForEach-Object { $_.DataGB + $_.LogGB } | Measure-Object -Maximum).Maximum)*$storageFactor)
        $observedTempdbLogGB = [Math]::Ceiling([double](($temp | Measure-Object LogGB -Maximum).Maximum)*$storageFactor)
    }
    $groups = @(
        [pscustomobject]@{ Target = 'ManagedInstance'; Database = ''; Databases = @($bundle.Databases); Candidates = $catalog.ManagedInstance }
    )
    foreach ($profile in @(Get-SsaValue $catalog 'DiskProfiles' @([pscustomobject]@{Id='PremiumSSD';Configurable=$false}))) {
        $groups += [pscustomobject]@{Target='SqlVm';Database='';Databases=@($bundle.Databases);Candidates=$catalog.Vm;DiskProfile=$profile}
    }
    foreach ($db in $bundle.Databases) { $groups += [pscustomobject]@{ Target = 'SqlDatabase'; Database = $db.Name; Databases = @($db); Candidates = $catalog.SqlDatabase } }
    foreach ($group in $groups) {
        $reason = $null
        $diskType = $null
        if ($group.Target -eq 'SqlVm') {
            $diskType = $group.DiskProfile.Id
            if ($group.DiskProfile.Configurable -and $Region -and $Region -notin $group.DiskProfile.Regions) { $reason = "$diskType is outside the documented regional availability matrix for $Region." }
        }
        if (-not $group.Databases.Count) { $reason = 'No user databases are visible; obtain a complete database inventory before recommending a target.' }
        if ($null -eq $cores -or $null -eq $memory) { $reason = 'No usable paired Windows/SQL observations are available; performance sizing is unavailable.' }
        $dataGB = 0.0; $logGB = 0.0
        foreach ($db in $group.Databases) {
            if ($null -eq $db.DataMB -or $null -eq $db.LogMB) { $reason = 'Allocated storage evidence is incomplete.'; continue }
            $observedData = 0.0; $observedLog = 0.0
            $observedFiles = @($samples | ForEach-Object { $_.Databases } | Where-Object { $_.Database -eq $db.Name })
            if ($observedFiles.Count) {
                $observedData = ($observedFiles | Measure-Object DataGB -Maximum).Maximum
                $observedLog = ($observedFiles | Measure-Object LogGB -Maximum).Maximum
            }
            $dataGB += [Math]::Max($db.DataMB/1024,[double]$observedData) * $storageFactor
            $logGB += [Math]::Max($db.LogMB/1024,[double]$observedLog) * $storageFactor
            if ($db.State -ne 'ONLINE') { $reason = 'An included database was not online during static collection.' }
            if ($group.Target -eq 'SqlVm' -and @(Get-SsaEvidenceRows $bundle 'FileStream' $db.Name).Count) { $reason = 'FILESTREAM/FileTable external storage is not measured by the file-allocation model; supply a separate storage assessment before VM sizing.' }
        }
        if ($group.Target -in @('SqlVm','ManagedInstance')) {
            foreach ($id in @(1,3,4)) {
                $system = @($samples | ForEach-Object { $_.Databases } | Where-Object DatabaseId -EQ $id)
                if ($system.Count) {
                    $dataGB += [double](($system | Measure-Object DataGB -Maximum).Maximum)*$storageFactor
                    $logGB += [double](($system | Measure-Object LogGB -Maximum).Maximum)*$storageFactor
                }
            }
        }
        $dataGB = [Math]::Ceiling($dataGB); $logGB = [Math]::Ceiling($logGB)
        $requiredCores = [double]$cores * $factor
        $sqlRequiredCores = $requiredCores
        $requiredMemory = [double]$memory * $factor
        $iops = Get-SsaDemand $samples 'Iops' $group.Database $Percentile
        $throughput = Get-SsaDemand $samples 'ThroughputMBps' $group.Database $Percentile
        $logRate = Get-SsaDemand $samples 'LogMBps' $group.Database $Percentile
        if ($null -eq $iops -or $null -eq $throughput -or $null -eq $logRate) { $reason = 'I/O or log-rate observations are unavailable for the requested scope.' }
        $iops = [double]$iops * $factor
        # Capture is MiB/s; all catalog and disk rate limits use decimal MB/s.
        $throughput = [double]$throughput * $factor * 1.048576; $logRate = [double]$logRate * $factor * 1.048576
        $remoteIops = $null; $remoteThroughput = $null; $remoteLogRate = $null
        if ($group.Target -eq 'ManagedInstance') {
            $remoteIops = Get-SsaDemand $samples 'Iops' '' $Percentile -ExcludeTempdb
            $remoteThroughput = Get-SsaDemand $samples 'ThroughputMBps' '' $Percentile -ExcludeTempdb
            $remoteLogRate = Get-SsaDemand $samples 'LogMBps' '' $Percentile -ExcludeTempdb
            if ($null -eq $remoteIops -or $null -eq $remoteThroughput -or $null -eq $remoteLogRate) { $reason = 'MI remote-storage I/O observations are incomplete; tempdb cannot substitute for user/system database file evidence.' }
            $remoteIops = [double]$remoteIops*$factor
            $remoteThroughput = [double]$remoteThroughput*$factor*1.048576
            $remoteLogRate = [double]$remoteLogRate*$factor*1.048576
        }
        $tempdbGB = [double]$observedTempdbGB
        if ($null -eq $observedTempdbGB) { $reason = 'Tempdb observations are missing; target tempdb capacity cannot be assessed.' }
        $roleDemand = $null
        if ($group.Target -eq 'SqlVm') {
            $hostCpu = Get-SsaDemand $samples 'HostCpuPercent' '' $Percentile
            $requiredCores = [Math]::Max($requiredCores,[double]$hostCpu/100*$bundle.Source.LogicalProcessors*$factor)
            $requiredMemory += 4
            $hostMemory = Get-SsaDemand $samples 'HostUsedMemoryGB' '' $Percentile
            if ($null -ne $hostMemory) { $requiredMemory = [Math]::Max($requiredMemory,[double]$hostMemory*$factor) }
            $iops = [Math]::Max($iops,[double](Get-SsaDemand $samples 'HostIops' '' $Percentile)*$factor)
            $throughput = [Math]::Max($throughput,[double](Get-SsaDemand $samples 'HostThroughputMBps' '' $Percentile)*$factor*1.048576)
            $roleDemand = @{}
            $remoteIops = Get-SsaDemand $samples 'Iops' '' $Percentile -ExcludeTempdb
            $remoteThroughput = Get-SsaDemand $samples 'ThroughputMBps' '' $Percentile -ExcludeTempdb
            if ($null -eq $remoteIops -or $null -eq $remoteThroughput) { $reason = 'VM remote-storage I/O observations excluding tempdb are incomplete.' }
            $remoteIops = [Math]::Max([double]$remoteIops*$factor, [double](Get-SsaDemand $samples 'HostIops' '' $Percentile)*$factor)
            $remoteThroughput = [Math]::Max([double]$remoteThroughput*$factor*1.048576, [double](Get-SsaDemand $samples 'HostThroughputMBps' '' $Percentile)*$factor*1.048576)
            foreach ($role in @('Data','Log','Tempdb')) {
                $opsMetric = $role+'Iops'; $rateMetric = $role+'ThroughputMBps'; $database = ''
                if ($role -eq 'Tempdb') { $opsMetric = 'Iops'; $rateMetric = 'ThroughputMBps'; $database = 'tempdb' }
                $exclude = $role -ne 'Tempdb'
                $ops = Get-SsaDemand $samples $opsMetric $database $Percentile -ExcludeTempdb:$exclude
                $rate = Get-SsaDemand $samples $rateMetric $database $Percentile -ExcludeTempdb:$exclude
                if ($null -eq $ops -or $null -eq $rate) { $ops = $iops/$factor; $rate = $throughput/$factor/1.048576 }
                $roleDemand[$role] = @{ Iops = [double]$ops*$factor; ThroughputMBps = [double]$rate*$factor*1.048576 }
            }
        }
        $major = $TargetSqlMajorVersion
        if (-not $major) { $major = $bundle.Source.VersionMajor }
        $edition = $TargetSqlEdition
        if (-not $edition) {
            if ($bundle.Source.Edition -match 'Enterprise') { $edition = 'Enterprise' }
            elseif ($bundle.Source.Edition -match 'Standard') { $edition = 'Standard' }
            else { $edition = 'Standard'; if ($group.Target -eq 'SqlVm') { $reason = 'Select an explicit production VM SQL edition for this source edition.' } }
        }
        $sqlCoreLimit = $null
        if ($group.Target -eq 'SqlVm' -and $edition -eq 'Standard') {
            $sqlCoreLimit = 24
            if ($major -ge 17) { $sqlCoreLimit = 32 }
            if ($sqlRequiredCores -gt $sqlCoreLimit) { $reason = "Observed SQL CPU demand with headroom exceeds the target Standard edition limit of $sqlCoreLimit virtual cores. Assess an Enterprise target or reduce SQL CPU demand; a larger Standard-edition VM cannot remove this limit." }
        }
        $feasible = @()
        $fittedTiers = @{}
        if (-not $reason) {
            foreach ($candidate in @($group.Candidates | Sort-Object VCores,MemoryGB,{ -[int](Get-SsaValue $_ 'Generation' 0) },Id)) {
                # Later candidates cannot outrank the first feasible option under the selection policy.
                if ($fittedTiers.ContainsKey($candidate.ServiceTier)) { continue }
                if ($group.Target -eq 'SqlVm' -and $diskType -ne 'PremiumSSD') {
                    $candidate = $candidate.PSObject.Copy()
                    $candidate.MaxIops = Get-SsaValue $candidate 'MaxAdvancedIops'
                    $candidate.MaxThroughputMBps = Get-SsaValue $candidate 'MaxAdvancedThroughputMBps'
                }
                $candidateIops = $iops; $candidateThroughput = $throughput; $candidateLogRate = $logRate
                if ($group.Target -eq 'SqlVm') {
                    if ((Get-SsaValue $candidate 'Preview' $false) -and -not $IncludePreviewVm) { continue }
                    $local = Get-SsaValue $candidate 'LocalTempGB'
                    if ($null -ne $local -and $local -gt 0 -and $tempdbGB -le $local) {
                        $candidateIops = $remoteIops; $candidateThroughput = $remoteThroughput
                    }
                }
                if ($group.Target -eq 'ManagedInstance' -and $candidate.ServiceTier -in @('GeneralPurpose','NextGenGeneralPurpose')) {
                    $candidateIops = $remoteIops; $candidateThroughput = $remoteThroughput; $candidateLogRate = $remoteLogRate
                }
                $storageLimit = $candidate.MaxDataGB
                $regionUnverified = $false
                if ($group.Target -eq 'ManagedInstance') {
                    $capacity = Get-SsaManagedInstanceCapacity $candidate $Region
                    if (-not $capacity) { continue }
                    $storageLimit = $capacity.MaxDataGB
                    $regionUnverified = $capacity.RegionUnverified
                }
                $known = $true
                $mandatoryBounds = @('VCores','MemoryGB')
                if ($group.Target -ne 'SqlVm') { $mandatoryBounds += 'MaxDataGB' }
                foreach ($constraint in $mandatoryBounds) {
                    if ($null -eq (Get-SsaValue $candidate $constraint)) { $known = $false }
                }
                if (-not $known) { continue }
                $storage = $dataGB
                if ($group.Target -ne 'SqlDatabase') { $storage += $logGB }
                if ((Get-SsaValue $candidate 'StorageScope') -eq 'InstanceDataLogAndTempdb') { $storage += $tempdbGB }
                $reservedStorage = $storage; $effectiveLogLimit = $candidate.MaxLogGB
                if ($group.Target -eq 'SqlDatabase' -and $null -ne $candidate.MaxLogGB -and $candidate.MaxLogGB -gt 0) {
                    $reservedStorage = [Math]::Ceiling([Math]::Max($dataGB,$logGB*$candidate.MaxDataGB/$candidate.MaxLogGB))
                    $effectiveLogLimit = $reservedStorage*$candidate.MaxLogGB/$candidate.MaxDataGB
                } elseif ($group.Target -eq 'ManagedInstance') { $reservedStorage = [Math]::Max(32,[Math]::Ceiling($storage/32)*32) }
                if ($candidate.VCores -lt $requiredCores -or $candidate.MemoryGB -lt $requiredMemory) { continue }
                if ($null -ne $storageLimit -and $storageLimit -lt $reservedStorage) { continue }
                if ($null -ne $effectiveLogLimit -and $effectiveLogLimit -lt $logGB) { continue }
                $tempdbLimit = Get-SsaValue $candidate 'MaxTempdbGB'
                if ($group.Target -eq 'ManagedInstance' -and $candidate.ServiceTier -eq 'BusinessCritical') { $tempdbLimit = $storageLimit }
                if ($group.Target -ne 'SqlVm' -and $null -ne $tempdbLimit -and $tempdbLimit -lt $tempdbGB) { continue }
                $tempdbLogLimit = Get-SsaValue $candidate 'MaxTempdbLogGB'
                if ($null -ne $tempdbLogLimit -and $tempdbLogLimit -lt $observedTempdbLogGB) { continue }
                $exceeded = $false
                foreach ($bound in @(@('MaxIops',$candidateIops),@('MaxThroughputMBps',$candidateThroughput),@('MaxLogMBps',$candidateLogRate))) {
                    $limit = Get-SsaValue $candidate $bound[0]
                    if ($null -ne $limit -and [double]$limit -lt $bound[1]) { $exceeded = $true }
                }
                if ($exceeded) { continue }
                if ($group.Target -eq 'SqlVm' -and ($null -eq $candidate.MaxIops -or $null -eq $candidate.MaxThroughputMBps)) { continue }
                if ((Get-SsaValue $candidate 'MaxDatabases') -and $group.Databases.Count -gt $candidate.MaxDatabases) { continue }
                if ($group.Target -eq 'SqlVm' -and ($major -notin $candidate.SqlMajorVersions -or $edition -notin $candidate.SupportedEditions)) { continue }
                $ioAllocation = $null
                if ($group.Target -eq 'ManagedInstance') {
                    $files = @(Get-SsaValue $performance 'FileInventory' @() | Where-Object DatabaseId -NE 2)
                    $fileFailure = $false
                    foreach ($file in $files) {
                        $maximum = Get-SsaValue $candidate 'MaxDataFileGB'
                        if ($file.Type -eq 'LOG') { $maximum = Get-SsaValue $candidate 'MaxLogFileGB' }
                        elseif ($candidate.ServiceTier -ne 'GeneralPurpose') { $maximum = $storageLimit }
                        if ($null -ne $maximum -and $file.SizeGB*$storageFactor -gt $maximum) { $fileFailure = $true; break }
                    }
                    $instanceFiles = Get-SsaValue $candidate 'MaxFilesPerInstance'
                    if ($null -ne $instanceFiles -and $files.Count -gt $instanceFiles) { $fileFailure = $true }
                    $databaseFiles = Get-SsaValue $candidate 'MaxFilesPerDatabase'
                    if ($null -ne $databaseFiles -and @($files | Group-Object DatabaseId | Where-Object Count -GT $databaseFiles).Count) { $fileFailure = $true }
                    if ($fileFailure) { continue }
                    if ($candidate.ServiceTier -eq 'NextGenGeneralPurpose') {
                        $ioAllocation = Get-SsaManagedInstanceIoAllocation $candidate $reservedStorage $candidateIops $candidateThroughput
                        if (-not $ioAllocation) { continue }
                    }
                }
                $layout = @()
                if ($group.Target -eq 'SqlVm') {
                    $layout = Get-SsaDiskLayout $candidate $catalog $dataGB $logGB $tempdbGB $candidateIops $candidateThroughput $logRate $roleDemand $diskType
                    if (-not $layout) { continue }
                }
                $feasible += [pscustomobject]@{ Candidate = $candidate; Layout = $layout; ReservedStorageGB = $reservedStorage; LogLimit = $effectiveLogLimit; StorageLimit=$storageLimit; TempdbLimit=$tempdbLimit; IoAllocation=$ioAllocation; RegionUnverified=$regionUnverified; Iops=$candidateIops; ThroughputMBps=$candidateThroughput; LogMBps=$candidateLogRate }
                $fittedTiers[$candidate.ServiceTier] = $true
            }
        }
        $selected = @($feasible | Sort-Object { $_.Candidate.VCores },{ $_.Candidate.MemoryGB },{ -[int](Get-SsaValue $_.Candidate 'Generation' 0) },{ $_.Candidate.Id } | Group-Object { $_.Candidate.ServiceTier } | ForEach-Object { $_.Group | Select-Object -First 1 })
        if (-not $selected.Count) {
            if (-not $reason) {
                $reason = 'No configuration in the catalog satisfies the known CPU, memory, storage, I/O, log, file, region, edition/version, and disk-layout constraints.'
                if ($group.Target -eq 'SqlVm') { $reason += " VM scope is x64 Ebdsv5 plus E-series v6/v7 with local temporary storage, NVMe remote controllers and $diskType managed disks; not an Azure-wide no-fit conclusion. Ebdsv6 Preview requires -IncludePreviewVm." }
            }
            [pscustomobject]@{ RecommendationId = [guid]::NewGuid().ToString(); CatalogId = $null; Target = $group.Target; Database = $group.Database; Status = 'Unavailable'; ServiceTier = $null; Hardware = $null; VCores = $null; MemoryGB = $null; DataGB = $dataGB; LogGB = $logGB; TempdbGB = $tempdbGB; VmSize = $null; SqlEdition = $edition; SqlMajorVersion = $major; Reason = $reason; Confidence = 'Unavailable'; Constraints = @(); PriceComponents = @(); DiskLayout = @(); DiskType=$diskType }
            continue
        }
        foreach ($choice in $selected) {
            $candidate = $choice.Candidate
            $tempdbPlacement = $null; $tempdbNote = ''
            $storageAssessment = $null
            if ($group.Target -eq 'SqlVm') {
                $storageAssessment = Get-SsaValue $performance 'StorageAssessment'
                $tempdbPlacement = 'ManagedDisk'
                if (-not @($choice.Layout | Where-Object Role -EQ Tempdb).Count) {
                    $tempdbPlacement = 'LocalTemporary'
                    $tempdbNote = ' Tempdb fits on the selected VM local temporary storage, including growth; no managed tempdb disk is allocated or billed. Verify free space after pagefile/other use and steady-state local writes; local performance limits are not validated. Recreate tempdb before SQL startup after host changes.'
                    if ($candidate.LocalTempDiskType -eq 'NVMe') {
                        $tempdbNote += ' Aggregate local NVMe capacity is device count times per-device GiB and requires a striped temporary volume or appropriate multi-file placement, not an assumed preformatted D: drive. Initialize/format raw local NVMe before use.'
                    } else {
                        $tempdbNote += ' Ebdsv5 uses a local temporary SSD volume with the published per-VM capacity, not raw local NVMe. Its required NVMe remote disk controller is separate from local temp storage.'
                    }
                } else {
                    $tempdbNote = ' Tempdb uses managed disks because the selected VM local temporary capacity is insufficient or unknown; a larger VM is not preferred merely to fit tempdb on a local drive.'
                    if (-not $managedTempdbAssessment) { $managedTempdbAssessment = Get-SsaStorageAssessment $samples $Percentile -IncludeTempdb }
                    $storageAssessment = $managedTempdbAssessment
                }
            }
            $storageRequired = $dataGB; $storageLimit = $choice.StorageLimit; $storageResource = 'Data storage'
            if ($group.Target -ne 'SqlDatabase') { $storageRequired += $logGB; $storageResource = 'Data and log storage' }
            if ((Get-SsaValue $candidate 'StorageScope') -eq 'InstanceDataLogAndTempdb') { $storageRequired += $tempdbGB; $storageResource = 'Data, log, and tempdb storage' }
            if ($group.Target -eq 'SqlVm') { $storageLimit = ($choice.Layout | Where-Object { $_.Role -in @('Data','Log') } | Measure-Object ProvisionedGB -Sum).Sum }
            $constraints = @(
                [pscustomobject]@{ Resource = 'CPU'; Required = $requiredCores; Limit = $candidate.VCores; Unit = 'logical-core estimate' },
                [pscustomobject]@{ Resource = 'Memory'; Required = $requiredMemory; Limit = $candidate.MemoryGB; Unit = 'GiB' },
                [pscustomobject]@{ Resource = $storageResource; Required = $storageRequired; Limit = $storageLimit; Unit = 'GiB' },
                [pscustomobject]@{ Resource = 'I/O operations'; Required = $choice.Iops; Limit = $candidate.MaxIops; Unit = 'IOPS' },
                [pscustomobject]@{ Resource = 'I/O throughput'; Required = $choice.ThroughputMBps; Limit = $candidate.MaxThroughputMBps; Unit = 'MB/s (decimal)' },
                [pscustomobject]@{ Resource = 'Log throughput'; Required = $choice.LogMBps; Limit = $candidate.MaxLogMBps; Unit = 'MB/s (decimal)' }
            )
            if ($group.Target -eq 'SqlDatabase') { $constraints += [pscustomobject]@{Resource='Log storage';Required=$logGB;Limit=$choice.LogLimit;Unit='GiB'} }
            if ($group.Target -ne 'SqlVm') {
                $constraints += [pscustomobject]@{Resource='Reserved storage';Required=$choice.ReservedStorageGB;Limit=$storageLimit;Unit='GiB'}
                $constraints += [pscustomobject]@{Resource='Tempdb storage';Required=$tempdbGB;Limit=$choice.TempdbLimit;Unit='GiB'}
                if ($null -ne (Get-SsaValue $candidate 'MaxTempdbLogGB')) {
                    $constraints += [pscustomobject]@{Resource='Tempdb log storage';Required=$observedTempdbLogGB;Limit=$candidate.MaxTempdbLogGB;Unit='GiB'}
                }
                if ($choice.IoAllocation) {
                    ($constraints | Where-Object Resource -EQ 'I/O operations').Limit = $choice.IoAllocation.ProvisionedIops
                    ($constraints | Where-Object Resource -EQ 'I/O throughput').Limit = $choice.IoAllocation.ThroughputMBps
                }
                if (Get-SsaValue $candidate 'ThroughputUnbounded' $false) {
                    ($constraints | Where-Object Resource -EQ 'I/O throughput') | Add-Member NoteProperty DocumentedUnlimited $true
                }
            }
            if ($group.Target -eq 'SqlVm') {
                if ($null -ne $sqlCoreLimit) { $constraints += [pscustomobject]@{Resource='SQL edition CPU';Required=$sqlRequiredCores;Limit=[Math]::Min($sqlCoreLimit,$candidate.VCores);Unit='virtual cores'} }
                $tempdbCapacity = Get-SsaValue $candidate 'LocalTempGB'
                if ($tempdbPlacement -eq 'ManagedDisk') { $tempdbCapacity = ($choice.Layout | Where-Object Role -EQ Tempdb | Measure-Object ProvisionedGB -Sum).Sum }
                $constraints += [pscustomobject]@{Resource='Tempdb storage';Required=$tempdbGB;Limit=$tempdbCapacity;Unit='GiB'}
                $constraints += [pscustomobject]@{Resource='Attached data disks';Required=($choice.Layout | Where-Object Role -NE Os | Measure-Object Count -Sum).Sum;Limit=$candidate.MaxDataDisks;Unit='disks'}
            }
            $unknownLimits = @($constraints | Where-Object { $null -eq $_.Limit -and -not (Get-SsaValue $_ 'DocumentedUnlimited' $false) } | ForEach-Object { $_.Resource })
            $constraintNote = ''
            if ($unknownLimits.Count) { $constraintNote = ' Unpublished/unverified target limits: ' + ($unknownLimits -join ', ') + '. These are not treated as unlimited or as validated; target workload testing is required.' }
            if ($choice.RegionUnverified) { $constraintNote += ' The chosen MI hardware or higher storage cap requires a supported region; specify -Region to enforce the published regional matrix. Regional capacity and quota still require deployment verification.' }
            if ($group.Target -eq 'ManagedInstance' -and $candidate.ServiceTier -eq 'GeneralPurpose') { $constraintNote += ' Classic GP per-file I/O performance and per-database log throughput still require layout-specific verification; aggregate I/O is not a validated per-file guarantee.' }
            if ($group.Target -eq 'SqlVm') {
                $constraintNote += " Independently sized $diskType alternative; OS remains Premium SSD. Active cores govern CPU sizing and SQL licensing; base cores identify retained allocation. VM ties prefer newer generations then catalog ID, not lowest price. Disk layouts minimize provisioned capacity then attachment count, not global cost. Use a Generation 2 NVMe-compatible Windows/SQL image, NVMe remote controller and compatible sector size. Remote limits use this disk type's sustained VM envelope, never burst/caching. SQL tempdb I/O is excluded when local; total host I/O remains a conservative floor. OS disk I/O, local writes, regional capacity, zone, quota and image eligibility remain unverified."
                if ($candidate.Hardware -eq 'Ebdsv5') { $constraintNote += ' Ebdsv5 uses the selected NVMe storage envelope, not the lower SCSI profile; E112ibds_v5 is NVMe-only.' }
                if ($diskType -ne 'PremiumSSD') { $constraintNote += ' Premium SSD v2 and Ultra are data disks only, LRS, no host caching; verify subscription resource-SKU and zone eligibility. Ultra requires VM Ultra compatibility enabled. Neither public prices nor the regional matrix prove deployability.' }
                if ($diskType -eq 'UltraSSD') { $constraintNote += ' Ultra pricing documentation conflicts on capacity rounding: this estimate conservatively rounds billed capacity to the published disk-size offers; provisioned capacity remains in 1-GiB increments. Confirm actual billing before purchase.' }
                if (Get-SsaValue $candidate 'Preview' $false) { $constraintNote += ' PREVIEW: Ebdsv6 was explicitly enabled with -IncludePreviewVm; verify preview terms, support, and regional availability.' }
            }
            [pscustomobject]@{
                RecommendationId = [guid]::NewGuid().ToString(); CatalogId = $candidate.Id; Target = $group.Target; Database = $group.Database
                DiskType = $diskType
                StorageAssessment = $storageAssessment
                Status = 'Provisional'; ServiceTier = $candidate.ServiceTier; Hardware = $candidate.Hardware; VCores = $candidate.VCores; MemoryGB = $candidate.MemoryGB
                DataGB = [Math]::Ceiling($dataGB); LogGB = [Math]::Ceiling($logGB); TempdbGB = [Math]::Ceiling($tempdbGB)
                TempdbPlacement = $tempdbPlacement
                ReservedStorageGB = $choice.ReservedStorageGB
                ProvisionedIops = $(if ($choice.IoAllocation) { $choice.IoAllocation.ProvisionedIops } else { $null })
                IncludedIops = $(if ($choice.IoAllocation) { $choice.IoAllocation.IncludedIops } else { $null })
                AdditionalIops = $(if ($choice.IoAllocation) { $choice.IoAllocation.AdditionalIops } else { $null })
                AdditionalMemoryGB = Get-SsaValue $candidate 'AdditionalMemoryGB' 0
                BaseVCores = Get-SsaValue $candidate 'BaseVCores'; BaseVmSize = Get-SsaValue $candidate 'BaseVmSize'
                VmGeneration = Get-SsaValue $candidate 'Generation'; VmPreview = Get-SsaValue $candidate 'Preview' $false
                LocalTempDisks = Get-SsaValue $candidate 'LocalTempDisks'; LocalTempDiskGB = Get-SsaValue $candidate 'LocalTempDiskGB'; LocalTempGB = Get-SsaValue $candidate 'LocalTempGB'
                LocalTempDiskType = Get-SsaValue $candidate 'LocalTempDiskType'; RemoteDiskController = Get-SsaValue $candidate 'RemoteDiskController'
                VmSize = Get-SsaValue $candidate 'VmSize'; SqlEdition = $edition; SqlMajorVersion = $major
                Reason = 'Smallest cataloged configuration per tier satisfying the known measured constraint envelope. CPU assumes no hardware-generation uplift. Database CPU/memory/tempdb use conservative whole-instance upper bounds; validate on the target. GP/BC SQL Database reserved storage includes the proportional log-cap requirement. VM OS memory reserve is four GiB and OS disk is 128 GiB; individual OS I/O attribution is unverified. Compatibility blockers are evaluated separately.' + $tempdbNote + $constraintNote
                Confidence = 'Provisional'; Constraints = $constraints; PriceComponents = @(); DiskLayout = @($choice.Layout)
            }
        }
    }
}
