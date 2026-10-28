function Get-SsaConfigurableDisk {
    param($Profile, [double]$SizeGB, [double]$Iops, [double]$ThroughputMBps, [int]$Count, [string]$Role)
    $mbps = [math]::Max($Profile.MinThroughputMBps,[math]::Ceiling($ThroughputMBps/$Count))
    $io = [math]::Max($Profile.MinIops,[math]::Max([math]::Ceiling($Iops/$Count),4*$mbps))
    $size = [math]::Max($Profile.MinSizeGB,[math]::Ceiling($SizeGB/$Count))
    if ($io -gt $Profile.IncludedIops) { $size = [math]::Max($size,[math]::Ceiling($io/$Profile.IopsPerGB)) }
    if ($size -gt $Profile.MaxSizeGB -or $io -gt $Profile.MaxIops -or $mbps -gt $Profile.MaxThroughputMBps) { return $null }
    $billed = $size
    if ($Profile.Id -eq 'UltraSSD') { $billed = @($Profile.BillingSizesGB | Where-Object { $_ -ge $size })[0] }
    [pscustomobject]@{
        DiskId=$Profile.Id; DiskType=$Profile.Id; Role=$Role; Count=$Count; SizeGB=$size
        ProvisionedGB=$size*$Count; Iops=$io; ThroughputMBps=$mbps; BilledSizeGB=$billed
        IncludedIops=$Profile.IncludedIops; IncludedThroughputMBps=$Profile.IncludedThroughputMBps
        Caching='None'; Redundancy='LRS'
    }
}

function Assert-SsaConfigurableDisk {
    param($Entry, $Profile, [string]$Region)
    if ($Entry.Role -notin @('Data','Log','Tempdb')) { throw 'Premium SSD v2 and Ultra cannot be OS disks.' }
    if ($Region -and $Region -notin $Profile.Regions) { throw 'Disk type is outside the documented regional availability matrix.' }
    foreach ($field in @('Count','SizeGB','Iops','ThroughputMBps')) {
        $value = [double]0
        if (-not [double]::TryParse([string](Get-SsaValue $Entry $field),[Globalization.NumberStyles]::Float,[cultureinfo]::InvariantCulture,[ref]$value) -or
            [double]::IsInfinity($value) -or [double]::IsNaN($value) -or $value -lt 1 -or $value % 1 -ne 0) { throw "Configurable disk $field must be an explicit positive integer." }
    }
    if ($Entry.SizeGB -lt $Profile.MinSizeGB -or $Entry.SizeGB -gt $Profile.MaxSizeGB -or
        $Entry.Iops -lt $Profile.MinIops -or $Entry.Iops -gt $Profile.MaxIops -or
        $Entry.ThroughputMBps -lt $Profile.MinThroughputMBps -or $Entry.ThroughputMBps -gt $Profile.MaxThroughputMBps -or
        $Entry.ThroughputMBps -gt $Entry.Iops/4 -or
        $Entry.Iops -gt [math]::Max($Profile.IncludedIops,$Entry.SizeGB*$Profile.IopsPerGB)) { throw 'Configurable disk capacity/IOPS/throughput or coupling limits are exceeded.' }
    if ((Get-SsaValue $Entry 'Caching' 'None') -ne 'None' -or
        (Get-SsaValue $Entry 'Redundancy' 'LRS') -ne 'LRS' -or
        (Get-SsaValue $Entry 'DiskType' $Profile.Id) -ne $Profile.Id) { throw 'Configurable disks require their exact type, LRS redundancy and no host caching.' }
}

function Get-SsaStorageAssessment {
    param($Samples, [double]$Percentile = 95, [switch]$IncludeTempdb)
    $latency = @(); $pressureSeconds = 0.0; $queueSeconds = 0.0; $observedSeconds = 0.0
    $queueValues = @()
    foreach ($sample in $Samples) {
        if ($sample.UsableSeconds -le 0) { continue }
        $files = @(Get-SsaValue $sample 'FileIoLatency' @() | Where-Object { $_ -and ($IncludeTempdb -or $_.DatabaseId -ne 2) })
        $active = @($files | Where-Object { $null -ne $_.ReadLatencyMs -or $null -ne $_.WriteLatencyMs })
        if (-not $active.Count) { continue }
        $observedSeconds += $sample.UsableSeconds
        $worst = [double](($active | ForEach-Object { $_.ReadLatencyMs; $_.WriteLatencyMs } | Where-Object { $null -ne $_ } | Measure-Object -Maximum).Maximum)
        $latency += $worst
        $volumes = @($active | ForEach-Object { Get-SsaValue $_ 'Volume' } | Where-Object { $_ } | ForEach-Object { $_.TrimEnd('\') })
        $queues = @(Get-SsaValue $sample 'DiskPressure' @() | Where-Object {
            $volume = Get-SsaValue $_ 'Volume'
            $volume -and ([string]$volume).TrimEnd('\') -in $volumes
        })
        if ($queues.Count) {
            $queue = [double](($queues | Measure-Object AvgQueueLength -Maximum).Maximum)
            $queueValues += $queue; $queueSeconds += $sample.UsableSeconds
        }
        # Queue depth alone is normal for parallel SSD I/O. Require concurrent latency on that SQL volume.
        $queuedSlow = $false
        foreach ($disk in $queues) {
            if ($disk.AvgQueueLength -lt 2) { continue }
            $sameVolume = @($active | Where-Object { ([string](Get-SsaValue $_ 'Volume')).TrimEnd('\') -ieq $disk.Volume.TrimEnd('\') })
            if (@($sameVolume | Where-Object { $_.ReadLatencyMs -ge 5 -or $_.WriteLatencyMs -ge 5 }).Count) { $queuedSlow = $true }
        }
        if ($worst -ge 10 -or $queuedSlow) { $pressureSeconds += $sample.UsableSeconds }
    }
    $p95 = $null; $queueP95 = $null; $policy = 'InsufficientEvidence'
    if ($latency.Count) {
        $p95 = Get-SsaPercentile $latency $Percentile
        $policy = 'GeneralSsd'
        if (($observedSeconds -gt 0 -and $pressureSeconds/$observedSeconds -ge 0.05) -or $p95 -le 1) { $policy = 'SubmillisecondPreferred' }
    }
    if ($queueValues.Count) { $queueP95 = Get-SsaPercentile $queueValues $Percentile }
    [pscustomobject]@{
        Policy=$policy; SqlFileLatencyMs=$p95; SqlVolumeQueueLength=$queueP95
        ObservedSeconds=$observedSeconds; QueueObservedSeconds=$queueSeconds; PressureSeconds=$pressureSeconds
        IncludesManagedTempdb=[bool]$IncludeTempdb
        Reason='Heuristic, not a latency SLA: per-sample worst active SQL file read/write stall delta per operation; requested nearest-rank percentile. Prefer submillisecond disks when >=5% of active sampled interval weight has >=10ms file latency or same-volume queue >=2 with >=5ms file latency; also preserve observed <=1ms service. Queue depth alone is not a bottleneck. Tempdb is included only for managed-tempdb alternatives. Missing volume mapping/queue data is not zero. Source bottlenecks can suppress observed IOPS; remediate and recapture before committing capacity.'
    }
}

function Update-SsaDiskSuggestion {
    param($Recommendations, $Prices)
    foreach ($scenario in @('Payg','Ahb')) {
        $options = @()
        foreach ($rec in @($Recommendations | Where-Object { (Get-SsaValue $_ 'Target') -eq 'SqlVm' -and (Get-SsaValue $_ 'DiskType') })) {
            $quotes = @($Prices | Where-Object { $_.RecommendationId -eq $rec.RecommendationId -and $_.Scenario -eq $scenario })
            foreach ($quote in $quotes) {
                $quote | Add-Member NoteProperty IsSuggested $false -Force
                $quote | Add-Member NoteProperty SuggestionReason 'No suggestion: insufficient SQL file-latency evidence.' -Force
                $assessment = Get-SsaValue $rec 'StorageAssessment'
                if (-not $assessment -or $assessment.Policy -eq 'InsufficientEvidence') { continue }
                if ($quote.Status -ne 'Complete') {
                    $quote.SuggestionReason = 'Not suggested: this scenario has no complete eligible quote; partial subtotals are never compared.'
                    continue
                }
                if ($assessment.Policy -eq 'SubmillisecondPreferred' -and $rec.DiskType -eq 'PremiumSSD') {
                    $quote.SuggestionReason = 'Not suggested: the observed latency/queue policy prefers the submillisecond class (Premium SSD v2 or Ultra).'
                    continue
                }
                $quote.SuggestionReason = 'Not suggested: another latency-eligible alternative wins on complete cost or the deterministic disk-type tie-break.'
                $options += $quote
            }
        }
        $winner = $options | Sort-Object TotalMonthly,DiskType,RecommendationId | Select-Object -First 1
        if ($winner) {
            $winner.IsSuggested = $true
            $winner.SuggestionReason = 'Lowest complete cost among independently sized alternatives meeting the observed latency policy. Premium SSD v2 and Ultra both target submillisecond latency; neither is guaranteed to cure source queues. Validate region/zone, VM capabilities, sector size and target workload latency before deployment.'
        }
    }
}
