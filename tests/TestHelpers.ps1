function New-TestBundle {
    $database = [pscustomobject]@{ Id = 5; Name = 'App'; State = 'ONLINE'; CompatibilityLevel = 110; DataMB = 1024.0; LogMB = 128.0 }
    $evidence = @()
    foreach ($kind in @('Databases','LinkedServers','Providers','Jobs','Mail','Principals','Audits','Credentials','Triggers','TraceFlags')) {
        $rows = @(); if ($kind -eq 'Databases') { $rows = @($database) }
        $evidence += [pscustomobject]@{ Kind = $kind; Database = ''; Status = 'Collected'; Rows = $rows; Error = $null }
    }
    foreach ($kind in @('Files','Definitions','Assemblies','FileStream','Broker','Dependencies','Synonyms','ObjectNames','DatabasePrincipals','SkuFeatures','ExternalDataSources')) {
        $rows = @()
        if ($kind -eq 'Files') {
            $rows = @([pscustomobject]@{ Id = 1; Type = 'ROWS'; Name = 'App'; SizeMB = 1024.0 },[pscustomobject]@{ Id = 2; Type = 'LOG'; Name = 'App_log'; SizeMB = 128.0 })
        }
        $evidence += [pscustomobject]@{ Kind = $kind; Database = 'App'; Status = 'Collected'; Rows = $rows; Error = $null }
    }
    [pscustomobject]@{
        SchemaVersion = '1.0'; CollectionId = 'test-collection'; CollectedAt = '2026-01-01T00:00:00Z'
        Source = [pscustomobject]@{ Instance = 'FIXTURE'; ComputerName = 'localhost'; Identity = 'fixture-identity'; VersionMajor = 16; Edition = 'Standard Edition'; LogicalProcessors = 4; SqlProcessId = 100 }
        Databases = @($database); Evidence = $evidence; Definitions = @(); Diagnostics = @()
    }
}

function Set-TestEvidence {
    param($Bundle, [string]$Kind, $Rows, [string]$Database = '')
    $entry = @($Bundle.Evidence | Where-Object { $_.Kind -eq $Kind -and $_.Database -eq $Database })
    $entry[0].Rows = @($Rows)
}

function New-TestRawSample {
    param([int]$Second = 0, [int]$ProcessId = 100, [string]$StartTime = 'stable')
    [pscustomobject]@{
        Timestamp = ([datetime]'2026-01-01T00:00:00Z').AddSeconds($Second).ToString('o')
        SourceIdentity = 'fixture-identity'; SqlProcessId = $ProcessId; StartTime = $StartTime
        MemoryGB = 1.0
        Windows = [pscustomobject]@{ CpuPercent = 10.0; UsedCores = 0.4; HostCpuPercent = 15.0; WorkingSetGB = 1.0; HostIops = 10.0; HostThroughputMBps = 1.0 }
        Files = @(
            [pscustomobject]@{ DatabaseId = 5; DatabaseName = 'App'; FileId = 1; FileGuid = 'a'; Type = 'ROWS'; SizeMB = 1024.0; Reads = $Second*10L; Writes = $Second*5L; ReadBytes = $Second*81920L; WriteBytes = $Second*40960L; ReadStallMs = $Second*1L; WriteStallMs = $Second*1L },
            [pscustomobject]@{ DatabaseId = 2; DatabaseName = 'tempdb'; FileId = 1; FileGuid = 't'; Type = 'ROWS'; SizeMB = 128.0; Reads = $Second*1L; Writes = $Second*1L; ReadBytes = $Second*8192L; WriteBytes = $Second*8192L; ReadStallMs = $Second*1L; WriteStallMs = $Second*1L }
        )
    }
}

function Save-TestBundle {
    param([string]$Path, $Bundle = (New-TestBundle))
    [void][IO.Directory]::CreateDirectory($Path)
    $json = ConvertTo-Json -InputObject $Bundle -Depth 30
    [IO.File]::WriteAllText((Join-Path $Path 'inventory.json'),$json)
    return $Bundle
}

function Save-ObservedBundle {
    param([string]$Path, $Bundle = (New-TestBundle), [double]$TempdbSizeMB = 128, [double]$TempdbLogSizeMB = 0)
    $bundle = Save-TestBundle $Path $Bundle
    $module = Get-Module SimpleSqlAssessment
    $previous = $null
    foreach ($second in @(0,30,60)) {
        $raw = New-TestRawSample $second
        ($raw.Files | Where-Object DatabaseId -EQ 2).SizeMB = $TempdbSizeMB
        if ($TempdbLogSizeMB -gt 0) {
            $raw.Files += [pscustomobject]@{DatabaseId=2;DatabaseName='tempdb';FileId=2;FileGuid='temp-log';Type='LOG';SizeMB=$TempdbLogSizeMB;Reads=0L;Writes=0L;ReadBytes=0L;WriteBytes=0L;ReadStallMs=0L;WriteStallMs=0L}
        }
        & $module {
            param($root,$bundle,$previous,$raw,$sequence)
            $sample = ConvertTo-SsaRateSample $previous $raw 30
            $payload = ConvertTo-Json -InputObject ([pscustomobject]@{Raw=$raw;Sample=$sample}) -Depth 30 -Compress
            Write-SsaJson (Join-Path $root ('performance\sample-{0:D10}.json' -f $sequence)) ([pscustomobject]@{SchemaVersion='1.0';Sequence=$sequence;CollectionId=$bundle.CollectionId;Sha256=Get-SsaHash $payload;Payload=$payload})
        } $Path $bundle $previous $raw ([int]($second/30)+1)
        $previous = $raw
    }
    & $module {
        param($root,$id)
        Write-SsaJson (Join-Path $root 'capture.json') ([pscustomobject]@{SchemaVersion='1.0';CollectionId=$id;State='Completed';RequestedSeconds=60;UsableSeconds=60;StartedAt='2026-01-01T00:00:00Z';LastSequence=3;SampleIntervalSeconds=30;ConfigurationHash=Get-SsaHash ('{0:R}|{1:R}' -f [double]60,[double]30)})
    } $Path $bundle.CollectionId
    return $bundle
}
