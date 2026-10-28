BeforeAll {
    $root = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
    Import-Module (Join-Path $root 'src\SimpleSqlAssessment\SimpleSqlAssessment.psd1') -Force
    . (Join-Path (Split-Path $PSScriptRoot -Parent) 'TestHelpers.ps1')
    $script:module = Get-Module SimpleSqlAssessment
}
Describe 'Rate and usable-duration accounting' {
    It 'does not count a first baseline or an outage as usable time' {
        $first = New-TestRawSample 0
        $later = New-TestRawSample 300
        $baseline = & $script:module {param($x) ConvertTo-SsaRateSample $null $x 30} $first
        $gap = & $script:module {param($a,$b) ConvertTo-SsaRateSample $a $b 30} $first $later
        $baseline.UsableSeconds | Should -Be 0
        $gap.UsableSeconds | Should -Be 0
    }
    It 'calculates actual elapsed-time rates and converts bytes into MiB' {
        $a = New-TestRawSample 0; $b = New-TestRawSample 30
        $sample = & $script:module {param($a,$b) ConvertTo-SsaRateSample $a $b 30} $a $b
        $sample.UsableSeconds | Should -Be 30
        ($sample.Databases | Where-Object Database -EQ App).Iops | Should -Be 15
        ($sample.Databases | Where-Object Database -EQ App).ThroughputMBps | Should -Be (122880.0/1MB)
    }
    It 'rebaselines after a SQL restart, PID change, or counter decrease' {
        $a = New-TestRawSample 30
        foreach ($b in @((New-TestRawSample 60 101),(New-TestRawSample 60 100 'restarted'),(New-TestRawSample 0))) {
            $sample = & $script:module {param($a,$b) ConvertTo-SsaRateSample $a $b 30} $a $b
            $sample.UsableSeconds | Should -Be 0
        }
    }
    It 'uses nearest-rank percentiles and rejects invalid resource values' {
        (& $script:module { Get-SsaPercentile -Values (1..100) -Percentile 95 }) | Should -Be 95
        { & $script:module { Get-SsaPercentile -Values @(1,-1) } } | Should -Throw
    }
    It 'aggregates simultaneous database samples before taking the percentile' {
        $samples = @(
            [pscustomobject]@{Timestamp='2026-01-01T00:00:00Z';UsableSeconds=30;Databases=@([pscustomobject]@{Iops=100},[pscustomobject]@{Iops=0})},
            [pscustomobject]@{Timestamp='2026-01-01T00:11:00Z';UsableSeconds=30;Databases=@([pscustomobject]@{Iops=0},[pscustomobject]@{Iops=100})}
        )
        (& $script:module {param($s) Get-SsaDemand $s 'Iops' '' 95} $samples) | Should -Be 100
    }
}
Describe 'Durable capture' {
    BeforeEach {
        $script:collection = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $null = Save-TestBundle $script:collection
        $rawSamples = @(0..20 | ForEach-Object { New-TestRawSample $_ })
        & $script:module { param($samples) $script:FixtureSecond = 0; $script:FixtureRawSamples=$samples; $script:FixtureFailure=$false } $rawSamples
        Mock New-SsaSqlConnection -ModuleName SimpleSqlAssessment { New-Object IO.MemoryStream }
        Mock Start-Sleep -ModuleName SimpleSqlAssessment {}
        Mock Get-SsaRawSample -ModuleName SimpleSqlAssessment {
            & (Get-Module SimpleSqlAssessment) {
                if ($script:FixtureFailure -and $script:FixtureSecond -ge 1) { throw 'Injected connection failure.' }
                $script:FixtureRawSamples[$script:FixtureSecond++]
            }
        }
    }
    It 'persists and resumes completed captures without duplicating samples' {
        $state = Start-SsaPerformanceCapture -CollectionPath $script:collection -Duration ([timespan]::FromSeconds(1)) -SampleIntervalSeconds 1
        $state.State | Should -Be 'Completed'
        $state.UsableSeconds | Should -Be 1
        $state.LastSequence | Should -Be 2
        $resumed = Resume-SsaPerformanceCapture -CollectionPath $script:collection
        $resumed.LastSequence | Should -Be 2
        @(Get-ChildItem (Join-Path $script:collection 'performance') -Filter 'sample-*.json').Count | Should -Be 2
    }
    It 'detects a corrupted committed segment rather than discarding it' {
        $null = Start-SsaPerformanceCapture -CollectionPath $script:collection -Duration ([timespan]::FromSeconds(1)) -SampleIntervalSeconds 1
        $file = Join-Path $script:collection 'performance\sample-0000000001.json'
        $record = Get-Content -Raw $file | ConvertFrom-Json
        $record.Sha256 = 'tampered'
        [IO.File]::WriteAllText($file,($record | ConvertTo-Json -Depth 20))
        { Resume-SsaPerformanceCapture -CollectionPath $script:collection } | Should -Throw '*Corrupt*'
    }
    It 'extends observation collection after failure without counting outage time' {
        & $script:module { $script:FixtureFailure = $true }
        { Start-SsaPerformanceCapture -CollectionPath $script:collection -Duration ([timespan]::FromSeconds(1)) -SampleIntervalSeconds 1 } | Should -Throw '*Injected*'
        $checkpoint = Get-Content -Raw (Join-Path $script:collection 'capture.json') | ConvertFrom-Json
        $checkpoint.State | Should -Be 'FailedResumable'
        $checkpoint.UsableSeconds | Should -Be 0
        & $script:module { $script:FixtureFailure = $false; $script:FixtureSecond = 10 }
        $state = Resume-SsaPerformanceCapture -CollectionPath $script:collection
        $state.State | Should -Be 'Completed'
        $state.UsableSeconds | Should -Be 1
        $state.LastSequence | Should -Be 3
        $analysis = & $script:module {param($p) $b=Read-SsaBundle $p; Get-SsaPerformanceAnalysis $p $b} $script:collection
        $analysis.WallSeconds | Should -Be 11
        $analysis.Gaps.Count | Should -Be 1
    }
    It 'rejects changed checkpoint configuration instead of mixing settings' {
        $null = Start-SsaPerformanceCapture -CollectionPath $script:collection -Duration ([timespan]::FromSeconds(1)) -SampleIntervalSeconds 1
        $path = Join-Path $script:collection 'capture.json'
        $checkpoint = Get-Content -Raw $path | ConvertFrom-Json
        $checkpoint.SampleIntervalSeconds = 60
        [IO.File]::WriteAllText($path,($checkpoint | ConvertTo-Json))
        { Resume-SsaPerformanceCapture -CollectionPath $script:collection } | Should -Throw '*configuration was modified*'
    }
    It 'rejects a second writer without changing the first writer checkpoint' {
        $lock = [IO.File]::Open((Join-Path $script:collection 'capture.lock'),[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
        try {
            { Start-SsaPerformanceCapture -CollectionPath $script:collection -Duration ([timespan]::FromSeconds(1)) } | Should -Throw
            Test-Path (Join-Path $script:collection 'capture.json') | Should -BeFalse
        } finally { $lock.Dispose() }
    }
    It 'resumes fractional settings across collector locale changes' {
        $original = [Threading.Thread]::CurrentThread.CurrentCulture
        try {
            [Threading.Thread]::CurrentThread.CurrentCulture = [cultureinfo]'fr-FR'
            $null = Start-SsaPerformanceCapture -CollectionPath $script:collection -Duration ([timespan]::FromSeconds(1.5)) -SampleIntervalSeconds 1.25
            [Threading.Thread]::CurrentThread.CurrentCulture = [cultureinfo]'en-US'
            $state = Resume-SsaPerformanceCapture -CollectionPath $script:collection
            $state.State | Should -Be Completed
            $state.RequestedSeconds | Should -Be 1.5
        } finally { [Threading.Thread]::CurrentThread.CurrentCulture = $original }
    }
}
