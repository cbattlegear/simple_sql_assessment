function Get-SsaUtcNow { [datetime]::UtcNow }

function Get-SsaCaptureConfigurationHash {
    param([double]$RequestedSeconds, [double]$SampleIntervalSeconds)
    Get-SsaHash ($RequestedSeconds.ToString('R',[cultureinfo]::InvariantCulture)+'|'+$SampleIntervalSeconds.ToString('R',[cultureinfo]::InvariantCulture))
}

function Get-SsaCounterMap {
    param([string]$ComputerName)
    $local = [Microsoft.Win32.Registry]::LocalMachine
    $englishKey = $local.OpenSubKey('SOFTWARE\Microsoft\Windows NT\CurrentVersion\Perflib\009')
    if (-not $englishKey) { throw 'English performance-counter name indexes are unavailable on the collector.' }
    try { $english = $englishKey.GetValue('Counter') } finally { $englishKey.Dispose() }
    $remote = $null; $languageKey = $null
    try {
        if ($ComputerName -in @('.','localhost',$env:COMPUTERNAME)) { $remote = [Microsoft.Win32.Registry]::LocalMachine }
        else { $remote = [Microsoft.Win32.RegistryKey]::OpenRemoteBaseKey([Microsoft.Win32.RegistryHive]::LocalMachine, $ComputerName) }
        $languageKey = $remote.OpenSubKey('SOFTWARE\Microsoft\Windows NT\CurrentVersion\Perflib\CurrentLanguage')
        if (-not $languageKey) { throw 'Localized counter names are unavailable. Run the collector locally or grant read-only remote counter/registry access.' }
        $localized = $languageKey.GetValue('Counter')
        $byId = @{}
        for ($i = 0; $i -lt $localized.Count - 1; $i += 2) { $byId[[string]$localized[$i]] = [string]$localized[$i+1] }
        $map = @{}
        for ($i = 0; $i -lt $english.Count - 1; $i += 2) {
            if ($byId.ContainsKey([string]$english[$i])) { $map[[string]$english[$i+1]] = $byId[[string]$english[$i]] }
        }
        return $map
    } finally {
        if ($languageKey) { $languageKey.Dispose() }
        if ($remote -and $ComputerName -notin @('.','localhost',$env:COMPUTERNAME)) { $remote.Dispose() }
    }
}

function Get-SsaWindowsSample {
    param([string]$ComputerName, [int]$SqlProcessId, [int]$LogicalProcessors)
    if ($LogicalProcessors -lt 1) { throw 'Logical processor count must be known for performance normalization.' }
    if (-not (Get-Variable -Name SsaCounterMaps -Scope Script -ErrorAction SilentlyContinue)) { $script:SsaCounterMaps = @{} }
    if (-not $script:SsaCounterMaps.ContainsKey($ComputerName)) { $script:SsaCounterMaps[$ComputerName] = Get-SsaCounterMap $ComputerName }
    $names = $script:SsaCounterMaps[$ComputerName]
    foreach ($required in @('Processor','% Processor Time','Memory','Available MBytes','Process','ID Process','Working Set - Private','LogicalDisk','Disk Reads/sec','Disk Writes/sec','Disk Read Bytes/sec','Disk Write Bytes/sec','Free Megabytes','Avg. Disk Queue Length')) {
        if (-not $names.ContainsKey($required)) { throw "Required Windows counter '$required' could not be localized." }
    }
    $paths = @(
        "\$($names.Processor)(_Total)\$($names.'% Processor Time')",
        "\$($names.Memory)\$($names.'Available MBytes')",
        "\$($names.Process)(*)\$($names.'ID Process')",
        "\$($names.Process)(*)\$($names.'% Processor Time')",
        "\$($names.Process)(*)\$($names.'Working Set - Private')"
    )
    foreach ($counter in @('Disk Reads/sec','Disk Writes/sec','Disk Read Bytes/sec','Disk Write Bytes/sec','Free Megabytes','Avg. Disk Queue Length')) {
        $paths += "\$($names.LogicalDisk)(*)\$($names[$counter])"
    }
    $counterSet = Get-Counter -ComputerName $ComputerName -Counter $paths -SampleInterval 1 -MaxSamples 2 -ErrorAction Stop | Select-Object -Last 1
    $samples = @($counterSet.CounterSamples)
    $pidSamples = @($samples | Where-Object { $_.Path.EndsWith('\'+$names.'ID Process', [StringComparison]::OrdinalIgnoreCase) -and [int]$_.CookedValue -eq $SqlProcessId })
    if ($pidSamples.Count -ne 1) { throw 'Cannot uniquely match SQL Server PID to the Windows process counter instance.' }
    # InstanceName omits the #N suffix for duplicate process names; match the full PDH instance path.
    $processPath = $pidSamples[0].Path.Substring(0,$pidSamples[0].Path.LastIndexOf('\'))
    $cpu = @($samples | Where-Object { $_.Path -eq ($processPath+'\'+$names.'% Processor Time') })
    $memory = @($samples | Where-Object { $_.Path -eq ($processPath+'\'+$names.'Working Set - Private') })
    $hostCpu = @($samples | Where-Object { $_.InstanceName -eq '_total' -and $_.Path -like "*\$($names.Processor)(*" -and $_.Path.EndsWith('\'+$names.'% Processor Time', [StringComparison]::OrdinalIgnoreCase) })
    $availableMemory = @($samples | Where-Object { $_.Path.EndsWith('\'+$names.'Available MBytes', [StringComparison]::OrdinalIgnoreCase) })
    if ($cpu.Count -ne 1 -or $memory.Count -ne 1 -or $hostCpu.Count -ne 1) { throw 'Required host/process counter samples are missing or ambiguous.' }
    $diskTotals = @($samples | Where-Object { $_.InstanceName -eq '_total' -and ($_.Path.EndsWith('\'+$names.'Disk Reads/sec', [StringComparison]::OrdinalIgnoreCase) -or $_.Path.EndsWith('\'+$names.'Disk Writes/sec', [StringComparison]::OrdinalIgnoreCase) -or $_.Path.EndsWith('\'+$names.'Disk Read Bytes/sec', [StringComparison]::OrdinalIgnoreCase) -or $_.Path.EndsWith('\'+$names.'Disk Write Bytes/sec', [StringComparison]::OrdinalIgnoreCase)) })
    if ($availableMemory.Count -ne 1 -or $diskTotals.Count -ne 4) { throw 'Required host memory/disk performance observations are missing.' }
    foreach ($counter in (@($cpu[0],$memory[0],$hostCpu[0],$availableMemory[0]) + $diskTotals)) {
        if ($counter.Status -ne 0 -or [double]::IsNaN($counter.CookedValue) -or $counter.CookedValue -lt 0) { throw 'A required Windows counter returned invalid data.' }
    }
    $hostIops = 0.0; $hostBytes = 0.0
    foreach ($counter in $samples) {
        if ($counter.InstanceName -ne '_total') { continue }
        if ($counter.Path.EndsWith('\'+$names.'Disk Reads/sec', [StringComparison]::OrdinalIgnoreCase) -or $counter.Path.EndsWith('\'+$names.'Disk Writes/sec', [StringComparison]::OrdinalIgnoreCase)) { $hostIops += $counter.CookedValue }
        if ($counter.Path.EndsWith('\'+$names.'Disk Read Bytes/sec', [StringComparison]::OrdinalIgnoreCase) -or $counter.Path.EndsWith('\'+$names.'Disk Write Bytes/sec', [StringComparison]::OrdinalIgnoreCase)) { $hostBytes += $counter.CookedValue }
    }
    $pressure = @($samples | Where-Object { $_.InstanceName -ne '_total' -and $_.Path.EndsWith('\'+$names.'Avg. Disk Queue Length', [StringComparison]::OrdinalIgnoreCase) } | ForEach-Object {
        if ($_.Status -ne 0 -or [double]::IsNaN($_.CookedValue) -or [double]::IsInfinity($_.CookedValue) -or $_.CookedValue -lt 0) { throw 'A required volume queue counter returned invalid data.' }
        [pscustomobject]@{ Volume=$_.InstanceName; AvgQueueLength=$_.CookedValue }
    })
    if (-not $pressure.Count) { throw 'Required per-volume disk queue observations are missing.' }
    [pscustomobject]@{
        CpuPercent = $cpu[0].CookedValue / $LogicalProcessors
        UsedCores = $cpu[0].CookedValue / 100.0; HostCpuPercent = $hostCpu[0].CookedValue
        WorkingSetGB = $memory[0].CookedValue / 1GB; AvailableMemoryGB = $availableMemory[0].CookedValue / 1024
        HostIops = $hostIops; HostThroughputMBps = $hostBytes / 1MB
        DiskPressure = $pressure
        Volumes = @($samples | Where-Object { $_.InstanceName -ne '_total' -and $_.Path.EndsWith('\'+$names.'Free Megabytes', [StringComparison]::OrdinalIgnoreCase) } | ForEach-Object { [pscustomobject]@{ Volume = $_.InstanceName; FreeGB = $_.CookedValue / 1024 } })
    }
}

function Get-SsaRawSample {
    param($Connection, $Bundle)
    $source = Get-SsaSource $Connection
    if ($source.Identity -ne $Bundle.Source.Identity) { throw 'The source host/instance identity changed. Start a new collection; do not mix hosts after failover.' }
    if ($source.LogicalProcessors -ne $Bundle.Source.LogicalProcessors -or $source.VersionMajor -ne $Bundle.Source.VersionMajor -or $source.Edition -ne $Bundle.Source.Edition) { throw 'Source CPU topology, engine version, or edition changed. Create a fresh static collection.' }
    $windows = Get-SsaWindowsSample $source.ComputerName $source.SqlProcessId $source.LogicalProcessors
    $files = @(Invoke-SsaQuery $Connection "SELECT v.database_id AS DatabaseId,d.name AS DatabaseName,v.file_id AS FileId,CONVERT(varchar(36),m.file_guid) AS FileGuid,m.type_desc AS Type,m.size/128.0 AS SizeMB,v.num_of_reads AS Reads,v.num_of_writes AS Writes,v.num_of_bytes_read AS ReadBytes,v.num_of_bytes_written AS WriteBytes,v.io_stall_read_ms AS ReadStallMs,v.io_stall_write_ms AS WriteStallMs,vs.volume_mount_point AS Volume FROM sys.dm_io_virtual_file_stats(NULL,NULL) v JOIN sys.master_files m ON m.database_id=v.database_id AND m.file_id=v.file_id JOIN sys.databases d ON d.database_id=v.database_id OUTER APPLY sys.dm_os_volume_stats(v.database_id,v.file_id) vs WHERE d.source_database_id IS NULL;")
    $memory = @(Invoke-SsaQuery $Connection "SELECT cntr_value AS MemoryKB FROM sys.dm_os_performance_counters WHERE object_name LIKE '%:Memory Manager' AND counter_name='Total Server Memory (KB)';")
    $start = @(Invoke-SsaQuery $Connection 'SELECT CONVERT(varchar(33),sqlserver_start_time,126) AS StartTime FROM sys.dm_os_sys_info;')
    if ($memory.Count -ne 1) { throw 'SQL committed-memory counter is missing or ambiguous.' }
    foreach ($db in $Bundle.Databases) {
        if ($db.State -eq 'ONLINE' -and -not @($files | Where-Object { $_.DatabaseId -eq $db.Id }).Count) { throw "Required file I/O observations are missing for database '$($db.Name)'." }
        if (@($files | Where-Object { $_.DatabaseId -eq $db.Id -and $_.DatabaseName -ne $db.Name }).Count) { throw 'A database was renamed. Create a fresh static collection before resuming performance analysis.' }
    }
    $knownIds = @($Bundle.Databases | ForEach-Object { $_.Id })
    if (@($files | Where-Object { $_.DatabaseId -gt 4 -and $_.DatabaseId -notin $knownIds }).Count) { throw 'Database membership changed. Create a fresh static collection before resuming performance analysis.' }
    [pscustomobject]@{
        Timestamp = (Get-SsaUtcNow).ToString('o'); SourceIdentity = $source.Identity
        SqlProcessId = $source.SqlProcessId; StartTime = $start[0].StartTime
        Windows = $windows; MemoryGB = [Math]::Max($memory[0].MemoryKB / 1MB, $windows.WorkingSetGB)
        HostUsedMemoryGB = $(if ($null -ne $source.PhysicalMemoryGB) { [Math]::Max(0,$source.PhysicalMemoryGB-$windows.AvailableMemoryGB) } else { $null })
        Files = $files
        ClientSnapshot = Get-SsaClientSnapshot $Connection $source.VersionMajor
    }
}

function ConvertTo-SsaRateSample {
    param($Previous, $Current, [double]$SampleIntervalSeconds)
    $elapsed = 0.0; $valid = $false; $reason = 'Initial baseline'
    if ($Previous) {
        $elapsed = ([datetime]$Current.Timestamp - [datetime]$Previous.Timestamp).TotalSeconds
        $valid = $elapsed -gt 0 -and $elapsed -le $SampleIntervalSeconds * 2.5 -and $Previous.StartTime -eq $Current.StartTime -and $Previous.SqlProcessId -eq $Current.SqlProcessId -and @($Previous.Files).Count -eq @($Current.Files).Count
        $reason = 'Counter discontinuity or observation gap'
    }
    $databases = New-Object 'System.Collections.Generic.List[object]'
    $fileLatency = New-Object 'System.Collections.Generic.List[object]'
    if ($valid) {
        $oldFiles = @{}
        foreach ($file in $Previous.Files) { $oldFiles["$($file.DatabaseId)|$($file.FileId)|$($file.FileGuid)"] = $file }
        $group = @{}
        foreach ($file in $Current.Files) {
            $key = "$($file.DatabaseId)|$($file.FileId)|$($file.FileGuid)"
            if (-not $oldFiles.ContainsKey($key)) { $valid = $false; break }
            $old = $oldFiles[$key]
            foreach ($metric in @('Reads','Writes','ReadBytes','WriteBytes','ReadStallMs','WriteStallMs')) {
                if ([double]$file.$metric -lt [double]$old.$metric) { $valid = $false; break }
            }
            if (-not $valid) { break }
            $readCount = $file.Reads-$old.Reads; $writeCount = $file.Writes-$old.Writes
            $fileLatency.Add([pscustomobject]@{
                DatabaseId=$file.DatabaseId; FileId=$file.FileId; Type=$file.Type; Volume=Get-SsaValue $file 'Volume'
                ReadLatencyMs=$(if ($readCount -gt 0) { ($file.ReadStallMs-$old.ReadStallMs)/[double]$readCount } else { $null })
                WriteLatencyMs=$(if ($writeCount -gt 0) { ($file.WriteStallMs-$old.WriteStallMs)/[double]$writeCount } else { $null })
            })
            if (-not $group.ContainsKey([string]$file.DatabaseId)) {
                $group[[string]$file.DatabaseId] = [ordered]@{ Database = $file.DatabaseName; DatabaseId = $file.DatabaseId; Iops = 0.0; ThroughputMBps = 0.0; LogMBps = 0.0; DataGB = 0.0; LogGB = 0.0; DataIops = 0.0; LogIops = 0.0; DataThroughputMBps = 0.0; LogThroughputMBps = 0.0 }
            }
            $db = $group[[string]$file.DatabaseId]
            $db.Iops += (($file.Reads-$old.Reads)+($file.Writes-$old.Writes)) / $elapsed
            $db.ThroughputMBps += (($file.ReadBytes-$old.ReadBytes)+($file.WriteBytes-$old.WriteBytes)) / $elapsed / 1MB
            if ($file.Type -eq 'LOG') {
                $db.LogGB += $file.SizeMB / 1024
                $db.LogMBps += ($file.WriteBytes-$old.WriteBytes) / $elapsed / 1MB
                $db.LogIops += (($file.Reads-$old.Reads)+($file.Writes-$old.Writes)) / $elapsed
                $db.LogThroughputMBps += (($file.ReadBytes-$old.ReadBytes)+($file.WriteBytes-$old.WriteBytes)) / $elapsed / 1MB
            } else {
                $db.DataGB += $file.SizeMB / 1024
                $db.DataIops += (($file.Reads-$old.Reads)+($file.Writes-$old.Writes)) / $elapsed
                $db.DataThroughputMBps += (($file.ReadBytes-$old.ReadBytes)+($file.WriteBytes-$old.WriteBytes)) / $elapsed / 1MB
            }
        }
        if ($valid) { foreach ($db in $group.Values) { $databases.Add([pscustomobject]$db) } }
    }
    [pscustomobject]@{
        Timestamp = $Current.Timestamp; UsableSeconds = $(if ($valid) { $elapsed } else { 0.0 })
        GapReason = $(if ($valid) { $null } else { $reason })
        CpuPercent = $Current.Windows.CpuPercent; UsedCores = $Current.Windows.UsedCores
        HostCpuPercent = $Current.Windows.HostCpuPercent; MemoryGB = $Current.MemoryGB
        HostUsedMemoryGB = Get-SsaValue $Current 'HostUsedMemoryGB'
        HostIops = $Current.Windows.HostIops; HostThroughputMBps = $Current.Windows.HostThroughputMBps
        FileIoLatency = @($(if ($valid) { $fileLatency.ToArray() } else { @() }))
        DiskPressure = @(Get-SsaValue $Current.Windows 'DiskPressure' @())
        Databases = $databases.ToArray()
    }
}

function Read-SsaCaptureRecords {
    param([string]$CollectionPath, $Bundle)
    $path = Join-Path $CollectionPath 'performance'
    if (-not (Test-Path -LiteralPath $path)) { return }
    $sequence = 0
    foreach ($file in @(Get-ChildItem -LiteralPath $path -Filter 'sample-*.json' | Sort-Object Name)) {
        $wrapper = Read-SsaJson $file.FullName
        $sequence++
        if ($wrapper.SchemaVersion -ne '1.0' -or $wrapper.Sequence -ne $sequence -or $wrapper.CollectionId -ne $Bundle.CollectionId -or (Get-SsaHash $wrapper.Payload) -ne $wrapper.Sha256) { throw "Corrupt, unsupported, or inconsistent committed sample: $($file.Name)" }
        $payload = $wrapper.Payload | ConvertFrom-Json -ErrorAction Stop
        if ($payload.Raw.SourceIdentity -ne $Bundle.Source.Identity) { throw "Mismatched source identity in $($file.Name)." }
        $payload
    }
}

function Invoke-SsaCapture {
    param([string]$CollectionPath, [timespan]$Duration = ([timespan]::FromDays(7)), [double]$SampleIntervalSeconds = 30, [pscredential]$Credential, [switch]$TrustServerCertificate, [switch]$Resume)
    $root = Resolve-SsaFileSystemPath $CollectionPath
    $bundle = Read-SsaBundle $root
    if ($Duration.TotalSeconds -le 0 -or $SampleIntervalSeconds -lt 1) { throw 'Capture duration must be positive and sample interval must be at least one second.' }
    $capturePath = Join-Path $root 'capture.json'
    $lock = [IO.File]::Open((Join-Path $root 'capture.lock'), [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
    $connection = $null; $state = $null
    try {
        if ($Resume) {
            $state = Read-SsaJson $capturePath
            if ($state.SchemaVersion -ne '1.0' -or $state.CollectionId -ne $bundle.CollectionId) { throw 'Capture checkpoint does not match the collection/schema.' }
            if ($state.RequestedSeconds -le 0 -or $state.SampleIntervalSeconds -lt 1 -or $state.LastSequence -lt 0) { throw 'Capture checkpoint contains invalid duration, interval, or sequence values.' }
            $expectedConfig = Get-SsaCaptureConfigurationHash $state.RequestedSeconds $state.SampleIntervalSeconds
            if ($expectedConfig -ne $state.ConfigurationHash) { throw 'Capture configuration was modified. Start a separate collection instead of mixing observation settings.' }
            $Duration = [timespan]::FromSeconds($state.RequestedSeconds)
            $SampleIntervalSeconds = $state.SampleIntervalSeconds
        } elseif (Test-Path -LiteralPath $capturePath) { throw 'Capture already exists. Use Resume-SsaPerformanceCapture.' }
        else {
            $state = [pscustomobject]@{ SchemaVersion = '1.0'; CollectionId = $bundle.CollectionId; State = 'Pending'; StartedAt = (Get-SsaUtcNow).ToString('o'); UpdatedAt = $null; RequestedSeconds = $Duration.TotalSeconds; SampleIntervalSeconds = $SampleIntervalSeconds; ConfigurationHash = Get-SsaCaptureConfigurationHash $Duration.TotalSeconds $SampleIntervalSeconds; UsableSeconds = 0.0; LastSequence = 0; Error = $null }
        }
        $committedCount = 0; $usableSeconds = 0.0
        Read-SsaCaptureRecords $root $bundle | ForEach-Object { $committedCount++; $usableSeconds += $_.Sample.UsableSeconds }
        if ($state.LastSequence -gt $committedCount) { throw 'Checkpoint references missing committed observations.' }
        $state.LastSequence = $committedCount
        $state.UsableSeconds = $usableSeconds
        if ($state.UsableSeconds -ge $state.RequestedSeconds) { $state.State = 'Completed'; Write-SsaJson $capturePath $state; return $state }
        # Never calculate a rate across a stopped collector, regardless of elapsed time.
        $previous = $null
        $endpoint = Get-SsaValue $bundle.Source 'ConnectionEndpoint' $bundle.Source.Instance
        $connection = New-SsaSqlConnection $endpoint 'master' $Credential -TrustServerCertificate:$TrustServerCertificate
        $state.State = 'Running'; $state.Error = $null
        Write-SsaJson $capturePath $state
        while ($state.UsableSeconds -lt $state.RequestedSeconds) {
            $iterationStart = Get-SsaUtcNow
            $raw = $null
            for ($attempt = 0; $attempt -lt 3; $attempt++) {
                try { $raw = Get-SsaRawSample $connection $bundle; break }
                catch {
                    if ($attempt -eq 2) { throw }
                    Write-Warning "Performance sample failed; retry $($attempt+1) of 2. No failure interval is counted as usable."
                    Start-Sleep -Seconds ([Math]::Pow(2,$attempt))
                    $previous = $null
                }
            }
            $sample = ConvertTo-SsaRateSample $previous $raw $SampleIntervalSeconds
            $sequence = $state.LastSequence + 1
            $payload = ConvertTo-Json -InputObject ([pscustomobject]@{ Raw = $raw; Sample = $sample }) -Depth 30 -Compress
            $wrapper = [pscustomobject]@{ SchemaVersion = '1.0'; Sequence = $sequence; CollectionId = $bundle.CollectionId; Sha256 = Get-SsaHash $payload; Payload = $payload }
            $samplePath = Join-Path $root ('performance\sample-{0:D10}.json' -f $sequence)
            Write-SsaJson $samplePath $wrapper
            $state.LastSequence = $sequence
            $state.UsableSeconds += $sample.UsableSeconds
            $state.UpdatedAt = $raw.Timestamp
            Write-SsaJson $capturePath $state
            $previous = $raw
            Write-Progress -Activity 'SQL assessment performance capture' -Status ("{0:N1} of {1:N1} observation hours" -f ($state.UsableSeconds/3600),($state.RequestedSeconds/3600)) -PercentComplete ([Math]::Min(100,100*$state.UsableSeconds/$state.RequestedSeconds))
            if ($state.UsableSeconds -lt $state.RequestedSeconds) {
                $remaining = [Math]::Max(0,$SampleIntervalSeconds-((Get-SsaUtcNow)-$iterationStart).TotalSeconds)
                if ($remaining -gt 0) { Start-Sleep -Milliseconds ([int]($remaining*1000)) }
            }
        }
        $state.State = 'Completed'
        Write-SsaJson $capturePath $state
        return $state
    } catch {
        if ($state -and $state.State -eq 'Running') {
            $state.State = 'FailedResumable'; $state.Error = 'Capture failed. Verify SQL/counter connectivity and resume with fresh credentials.'
            $state.UpdatedAt = (Get-SsaUtcNow).ToString('o')
            Write-SsaJson $capturePath $state
        }
        throw
    } finally {
        if ($state -and $state.State -eq 'Running') {
            $state.State = 'Interrupted'; $state.UpdatedAt = (Get-SsaUtcNow).ToString('o')
            Write-SsaJson $capturePath $state
        }
        if ($connection) { $connection.Dispose() }
        $lock.Dispose()
        Write-Progress -Activity 'SQL assessment performance capture' -Completed
    }
}
