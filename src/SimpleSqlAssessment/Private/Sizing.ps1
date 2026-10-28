function Get-SsaPercentile {
    param([double[]]$Values, [ValidateRange(1,100)][double]$Percentile = 95)
    if (-not $Values.Count) { return $null }
    foreach ($value in $Values) { if ([double]::IsNaN($value) -or [double]::IsInfinity($value) -or $value -lt 0) { throw 'Sizing observations must be finite, nonnegative values.' } }
    $sorted = @($Values | Sort-Object)
    return $sorted[[Math]::Max(0, [int][Math]::Ceiling($sorted.Count * $Percentile / 100.0) - 1)]
}

function Get-SsaDemand {
    param($Samples, [string]$Metric, [string]$Database, [double]$Percentile = 95, [switch]$ExcludeTempdb)
    $buckets = @{}
    foreach ($sample in $Samples) {
        if ($sample.UsableSeconds -le 0) { continue }
        $value = $null
        if ($Database) {
            $db = @($sample.Databases | Where-Object { $_.Database -eq $Database })
            if ($db.Count -eq 1) { $value = Get-SsaValue $db[0] $Metric }
        } elseif ($Metric -in @('Iops','ThroughputMBps','LogMBps','DataIops','LogIops','DataThroughputMBps','LogThroughputMBps')) {
            $databases = @($sample.Databases)
            if ($ExcludeTempdb) { $databases = @($databases | Where-Object { (Get-SsaValue $_ 'DatabaseId') -ne 2 -and $_.Database -ne 'tempdb' }) }
            if (-not $databases.Count -or @($databases | Where-Object { $null -eq (Get-SsaValue $_ $Metric) }).Count) { return $null }
            $value = ($databases | Measure-Object -Property $Metric -Sum).Sum
        } else { $value = Get-SsaValue $sample $Metric }
        if ($null -eq $value) { return $null }
        if ([double]::IsNaN([double]$value) -or [double]$value -lt 0) { throw "Invalid $Metric observation." }
        $key = [Math]::Floor(([datetime]$sample.Timestamp).ToUniversalTime().Ticks / [timespan]::FromMinutes(10).Ticks)
        if (-not $buckets.ContainsKey($key) -or $value -gt $buckets[$key]) { $buckets[$key] = [double]$value }
    }
    return (Get-SsaPercentile -Values @($buckets.Values) -Percentile $Percentile)
}

function Get-SsaPerformanceAnalysis {
    param([string]$CollectionPath, $Bundle, [double]$Percentile = 95)
    $capturePath = Join-Path $CollectionPath 'capture.json'
    $state = [pscustomobject]@{ State = 'Unavailable'; RequestedSeconds = 604800; UsableSeconds = 0; StartedAt = $null }
    if (Test-Path -LiteralPath $capturePath) { $state = Read-SsaJson $capturePath }
    $fileInventory = @{}
    $clientObservations = New-SsaClientObservationState
    Add-SsaClientSnapshot $clientObservations (Get-SsaValue $Bundle 'ClientSnapshot')
    $previousRaw = $null
    $samples = @(Read-SsaCaptureRecords $CollectionPath $Bundle | ForEach-Object {
        Add-SsaClientSnapshot $clientObservations (Get-SsaValue $_.Raw 'ClientSnapshot')
        foreach ($file in @(Get-SsaValue $_.Raw 'Files' @())) {
            $key = [string]$file.DatabaseId + '|' + $file.FileId
            if (-not $fileInventory.ContainsKey($key)) {
                $fileInventory[$key] = [pscustomobject]@{ DatabaseId=$file.DatabaseId; Database=$file.DatabaseName; FileId=$file.FileId; Type=$file.Type; SizeGB=0.0 }
            }
            $fileInventory[$key].SizeGB = [math]::Max($fileInventory[$key].SizeGB, [double]$file.SizeMB/1024)
        }
        $sample = $_.Sample
        if ($sample.UsableSeconds -gt 0 -and $null -eq (Get-SsaValue $sample 'FileIoLatency') -and $previousRaw) {
            $derived = ConvertTo-SsaRateSample $previousRaw $_.Raw ([math]::Max(1,$sample.UsableSeconds))
            $sample | Add-Member NoteProperty FileIoLatency $derived.FileIoLatency
        }
        $previousRaw = $_.Raw
        $sample
    })
    $summary = New-Object 'System.Collections.Generic.List[object]'
    $series = New-Object 'System.Collections.Generic.List[object]'
    $gaps = New-Object 'System.Collections.Generic.List[object]'
    $usable = 0.0
    if ($samples.Count) { $usable = [double](($samples | Measure-Object UsableSeconds -Sum).Sum) }
    foreach ($metric in @('CpuPercent','UsedCores','MemoryGB','Iops','ThroughputMBps','LogMBps','HostIops','HostThroughputMBps','HostCpuPercent')) {
        $values = @($samples | Where-Object { $_.UsableSeconds -gt 0 } | ForEach-Object {
            if ($metric -in @('Iops','ThroughputMBps','LogMBps')) { ($_.Databases | Measure-Object -Property $metric -Sum).Sum }
            else { Get-SsaValue $_ $metric }
        } | Where-Object { $null -ne $_ })
        if ($values.Count) {
            $unit = 'count'; if ($metric -like '*GB') { $unit = 'GiB' } elseif ($metric -like '*MBps') { $unit = 'MiB/s' } elseif ($metric -like '*Percent') { $unit = '%' }
            $summary.Add([pscustomobject]@{ Metric = $metric; Database = ''; P95 = Get-SsaDemand $samples $metric '' $Percentile; Peak = ($values | Measure-Object -Maximum).Maximum; Unit = $unit })
        }
    }
    $previous = $null; $seriesBuckets = @{}
    foreach ($sample in $samples) {
        if ($sample.UsableSeconds -eq 0 -and $previous) {
            $gaps.Add([pscustomobject]@{ Start = $previous.Timestamp; End = $sample.Timestamp; DurationSeconds = ([datetime]$sample.Timestamp-[datetime]$previous.Timestamp).TotalSeconds; Reason = $sample.GapReason })
        }
        $bucket = [Math]::Floor(([datetime]$sample.Timestamp).Ticks / [timespan]::FromMinutes(10).Ticks)
        if ($sample.UsableSeconds -gt 0) {
            $point = [pscustomobject]@{ Timestamp = $sample.Timestamp; CpuPercent = $sample.CpuPercent; MemoryGB = $sample.MemoryGB; Iops = ($sample.Databases | Measure-Object Iops -Sum).Sum; ThroughputMBps = ($sample.Databases | Measure-Object ThroughputMBps -Sum).Sum }
            if (-not $seriesBuckets.ContainsKey($bucket)) { $seriesBuckets[$bucket] = $point }
            else {
                foreach ($metric in @('CpuPercent','MemoryGB','Iops','ThroughputMBps')) { if ($point.$metric -gt $seriesBuckets[$bucket].$metric) { $seriesBuckets[$bucket].$metric = $point.$metric } }
            }
        }
        $previous = $sample
    }
    foreach ($key in @($seriesBuckets.Keys | Sort-Object)) { $series.Add($seriesBuckets[$key]) }
    $wall = 0
    if ($samples.Count -gt 1) { $wall = ([datetime]$samples[-1].Timestamp - [datetime]$samples[0].Timestamp).TotalSeconds }
    [pscustomobject]@{
        State = $state.State; RequestedSeconds = $state.RequestedSeconds; SampleIntervalSeconds = Get-SsaValue $state 'SampleIntervalSeconds'; UsableSeconds = $usable; WallSeconds = $wall
        Gaps = $gaps.ToArray(); Summary = $summary.ToArray(); Series = $series.ToArray()
        Samples = $samples; Percentile = $Percentile; FileInventory = @($fileInventory.Values)
        StorageAssessment = Get-SsaStorageAssessment $samples $Percentile
        ClientDependencies = ConvertTo-SsaClientDependencies $clientObservations (Get-SsaValue $state 'SampleIntervalSeconds')
        Notes = @('Ten-minute metric maxima are independent envelope points, not a simultaneous workload trace.', 'Per-database CPU/memory use the whole observed SQL instance as a conservative upper bound; not measured database attribution.')
    }
}

function Get-SsaManagedInstanceIoAllocation {
    param($Candidate, [double]$ReservedStorageGB, [double]$Iops, [double]$ThroughputMBps)
    $included = [math]::Min([double]$Candidate.MaxIops, [math]::Max([double]300, 3*$ReservedStorageGB))
    $required = [math]::Max([double]300, [math]::Ceiling($Iops))
    if ($ThroughputMBps -gt 75) { $required = [math]::Max($required, [math]::Ceiling($ThroughputMBps*30)) }
    $provisioned = [math]::Max($included, $required)
    if ($provisioned -gt $Candidate.MaxIops -or $ThroughputMBps -gt $Candidate.MaxThroughputMBps) { return $null }
    $throughput = [math]::Min([double]$Candidate.MaxThroughputMBps, [math]::Max([double]75, $provisioned/30))
    [pscustomobject]@{ ProvisionedIops=$provisioned; IncludedIops=$included; AdditionalIops=$provisioned-$included; ThroughputMBps=$throughput }
}

function Get-SsaDiskLayout {
    param($Candidate, $Catalog, [double]$DataGB, [double]$LogGB, [double]$TempdbGB, [double]$Iops, [double]$ThroughputMBps, [double]$LogMBps, $RoleDemand, [string]$DiskType = 'PremiumSSD')
    $maxDisks = Get-SsaValue $Candidate 'MaxDataDisks'
    if (-not $maxDisks) { return $null }
    $layouts = @([pscustomobject]@{ Entries = @(); Count = 0; ProvisionedGB = 0.0 })
    $roles = @(
        @{ Role = 'Os'; Size = 128.0; Iops = 0.0; MBps = 0.0 },
        @{ Role = 'Data'; Size = [Math]::Max(1,$DataGB); Iops = $Iops; MBps = $ThroughputMBps },
        @{ Role = 'Log'; Size = [Math]::Max(1,$LogGB); Iops = $Iops; MBps = [Math]::Max($LogMBps,$ThroughputMBps) },
        @{ Role = 'Tempdb'; Size = [Math]::Max(1,$TempdbGB); Iops = $Iops; MBps = $ThroughputMBps }
    )
    if ($RoleDemand) {
        foreach ($role in $roles) {
            if ($role.Role -eq 'Os') { continue }
            $role.Iops = $RoleDemand[$role.Role].Iops
            $role.MBps = $RoleDemand[$role.Role].ThroughputMBps
        }
    }
    foreach ($role in $roles) {
        if ($role.Role -eq 'Tempdb') {
            $localCapacity = Get-SsaValue $Candidate 'LocalTempGB'
            if ($null -ne $localCapacity -and $localCapacity -gt 0 -and $TempdbGB -le $localCapacity) { continue }
        }
        $choices = @()
        $tiers = @($Catalog.Disks)
        if ($DiskType -ne 'PremiumSSD' -and $role.Role -ne 'Os') { $tiers = @() }
        foreach ($disk in $tiers) {
            if (-not $disk.SizeGB -or -not $disk.Iops -or -not $disk.ThroughputMBps) { continue }
            $count = [int][Math]::Max(1,[Math]::Max([Math]::Ceiling($role.Size/$disk.SizeGB),[Math]::Max([Math]::Ceiling($role.Iops/$disk.Iops),[Math]::Ceiling($role.MBps/$disk.ThroughputMBps))))
            if ($role.Role -eq 'Os' -and $count -ne 1) { continue }
            $choices += [pscustomobject]@{ DiskId = $disk.Id; DiskType = 'PremiumSSD'; Role = $role.Role; Count = $count; SizeGB = $disk.SizeGB; ProvisionedGB = $count*$disk.SizeGB; Iops=$disk.Iops; ThroughputMBps=$disk.ThroughputMBps; Caching='None' }
        }
        if ($DiskType -ne 'PremiumSSD' -and $role.Role -ne 'Os') {
            $profile = @($Catalog.DiskProfiles | Where-Object Id -EQ $DiskType)
            if ($profile.Count -ne 1 -or -not $profile[0].Configurable) { throw "Unknown configurable disk type: $DiskType." }
            for ($n = 1; $n -le $maxDisks; $n++) {
                $choice = Get-SsaConfigurableDisk $profile[0] $role.Size $role.Iops $role.MBps $n $role.Role
                if ($choice) { $choices += $choice }
            }
        }
        # Retain the least-capacity layout for each attachment count, not just each role independently.
        $next = @{}
        foreach ($layout in $layouts) {
            foreach ($choice in $choices) {
                $count = $layout.Count
                if ($role.Role -ne 'Os') { $count += $choice.Count }
                if ($count -gt $maxDisks) { continue }
                $size = $layout.ProvisionedGB + $choice.ProvisionedGB
                if (-not $next.ContainsKey($count) -or $size -lt $next[$count].ProvisionedGB) {
                    $next[$count] = [pscustomobject]@{ Entries = @($layout.Entries) + @($choice); Count = $count; ProvisionedGB = $size }
                }
            }
        }
        if (-not $next.Count) { return $null }
        $layouts = @($next.Values)
    }
    $selected = $layouts | Sort-Object ProvisionedGB,Count | Select-Object -First 1
    return ,@($selected.Entries)
}
