BeforeAll {
    Set-StrictMode -Version 2.0
    $script:SsaModuleRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\src\SimpleSqlAssessment'))
    . (Join-Path $script:SsaModuleRoot 'Private\Common.ps1')
    . (Join-Path $script:SsaModuleRoot 'Private\Report.ps1')
    . (Join-Path $script:SsaModuleRoot 'Public\Export-SsaAssessment.ps1')
    $script:reportTestRoot = Join-Path $PSScriptRoot ('report-test-output-' + [guid]::NewGuid().ToString('N'))
    [void][IO.Directory]::CreateDirectory($script:reportTestRoot)

    function New-ReportFixture {
        [pscustomobject][ordered]@{
            SchemaVersion = '1.0'
            AssessmentId = 'assessment-1'
            GeneratedAt = '2026-10-22T12:00:00Z'
            Source = [pscustomobject]@{ Instance = 'SQL01'; ComputerName = 'HOST01'; VersionMajor = 16; Edition = 'Enterprise' }
            Inventory = @([pscustomobject]@{ Id = 5; Name = 'sales'; State = 'Online'; CompatibilityLevel = 160; DataMB = 102400; LogMB = 32768 })
            Configuration = [pscustomobject]@{ Region = 'eastus'; Currency = 'USD'; HoursPerMonth = 730; AhbEligible = $false }
            Targets = @(
                [pscustomobject]@{ Target = 'SqlDatabase'; Compatibility = 'Blocked'; BlockerCount = 1; WarningCount = 0; ReviewCount = 1; SizingStatus = 'Pending'; MonthlyPayg = $null; MonthlyAhb = $null },
                [pscustomobject]@{ Target = 'ManagedInstance'; Compatibility = 'NeedsReview'; BlockerCount = 0; WarningCount = 1; ReviewCount = 1; SizingStatus = 'Sized'; MonthlyPayg = 123.45; MonthlyAhb = $null },
                [pscustomobject]@{ Target = 'SqlVm'; Compatibility = 'Compatible'; BlockerCount = 0; WarningCount = 0; ReviewCount = 0; SizingStatus = 'Unavailable'; MonthlyPayg = $null; MonthlyAhb = $null }
            )
            Findings = @([pscustomobject]@{
                Target = 'SqlDatabase'; RuleId = 'DB001'; Category = 'Issue'; PublishedCategory = 'Issue'; Scope = 'Object'
                Database = 'sales'; Object = 'dbo.legacy'; Line = 3; Message = 'Unsupported feature'; Remediation = 'Review migration guidance'
                SourceUrl = 'https://learn.microsoft.com/azure/azure-sql/'
            })
            RuleEvaluations = @(
                [pscustomobject]@{ Target = 'SqlDatabase'; RuleId = 'DB001'; Database = 'sales'; Status = 'Finding'; Category = 'Issue'; Message = 'Unsupported feature'; SourceUrl = 'https://learn.microsoft.com/azure/azure-sql/' },
                [pscustomobject]@{ Target = 'ManagedInstance'; RuleId = 'MI001'; Database = 'sales'; Status = 'NeedsReview'; Category = 'Warning'; Message = 'Partial evidence'; SourceUrl = $null },
                [pscustomobject]@{ Target = 'SqlVm'; RuleId = 'VM001'; Database = ''; Status = 'Pass'; Category = 'Warning'; Message = 'Supported'; SourceUrl = $null }
            )
            Recommendations = @([pscustomobject]@{
                RecommendationId = 'rec-1'; CatalogId = 'mi-gp'; Target = 'ManagedInstance'; Database = $null; Status = 'Sized'
                ServiceTier = 'GeneralPurpose'; Hardware = 'Standard'; VCores = 8; MemoryGB = 40.8; DataGB = 128; LogGB = 32
                TempdbGB = 16; VmSize = $null; SqlEdition = $null; SqlMajorVersion = $null; Reason = 'Measured CPU with headroom'
                Confidence = 'Provisional'; Constraints = @('Capture incomplete'); PriceComponents = @('Compute', 'Storage')
            })
            Prices = @(
                [pscustomobject]@{
                    RecommendationId = 'rec-1'; Scenario = 'Payg'; Status = 'Partial'; TotalMonthly = 123.45
                    Currency = 'USD'; Region = 'eastus'; HoursPerMonth = 730
                    Components = @([pscustomobject]@{ Component = 'Compute'; MeterId = 'meter-1'; Quantity = 730; Unit = '1 Hour'; Rate = 0.169109589; MonthlyCost = 123.45; EffectiveStartDate = '2026-10-01'; RetrievedAt = '2026-10-22T11:00:00Z' })
                    Errors = @('Storage meter unavailable')
                },
                [pscustomobject]@{ RecommendationId = 'rec-1'; Scenario = 'Ahb'; Status = 'NotEligible'; TotalMonthly = $null; Currency = 'USD'; Region = 'eastus'; HoursPerMonth = 730; Components = @(); Errors = @('Not eligible') }
            )
            Performance = [pscustomobject]@{
                State = 'Interrupted'; RequestedSeconds = 604800; UsableSeconds = 60; WallSeconds = 180; MissingMetrics = @('LogMBps')
                Gaps = @([pscustomobject]@{ Start = '2026-10-22T10:01:00Z'; End = '2026-10-22T10:03:00Z'; Reason = 'Interrupted' })
                Summary = @([pscustomobject]@{ Metric = 'CpuPercent'; Database = $null; P95 = 62.5; Peak = 90; Unit = '%' })
                Series = @(
                    [pscustomobject]@{ Timestamp = '2026-10-22T10:00:00Z'; CpuPercent = 25; MemoryGB = 8; Iops = 100; ThroughputMBps = 2.5 },
                    [pscustomobject]@{ Timestamp = '2026-10-22T10:00:30Z'; CpuPercent = 90; MemoryGB = 8.5; Iops = 300; ThroughputMBps = 8 }
                )
            }
            Diagnostics = @('Provisional snapshot')
            Provenance = [pscustomobject]@{ ModuleVersion = '1.0.0'; RuleVersion = '2026.10.22'; CatalogVersion = '2026.10.22'; CollectionId = 'collection-1' }
        }
    }
    function Read-EmbeddedAssessment {
        param([string]$Path)
        $html = [IO.File]::ReadAllText($Path)
        $match = [regex]::Match($html, '(?s)<script type="application/json" id="ssa-data">(.*?)</script>')
        if (-not $match.Success) { throw 'Embedded report JSON is missing.' }
        return ($match.Groups[1].Value | ConvertFrom-Json)
    }
}

AfterAll {
    if ($script:reportTestRoot -and [IO.Directory]::Exists($script:reportTestRoot)) {
        Remove-Item -LiteralPath $script:reportTestRoot -Recurse -Force
    }
}

Describe 'Export-SsaAssessment' {
    It 'writes all default outputs and returns only the output locations' {
        $assessment = New-ReportFixture
        $output = @($assessment | Export-SsaAssessment -OutputPath (Join-Path $script:reportTestRoot 'default'))
        $output.Count | Should -Be 1
        $paths = $output[0]
        $paths.PSObject.Properties.Name | Should -Contain 'HtmlPath'
        $paths.PSObject.Properties.Name | Should -Not -Contain 'AssessmentId'
        Test-Path -LiteralPath $paths.HtmlPath | Should -BeTrue
        Test-Path -LiteralPath $paths.JsonPath | Should -BeTrue
        @($paths.CsvFiles.PSObject.Properties).Count | Should -Be 8
        foreach ($property in $paths.CsvFiles.PSObject.Properties) {
            Test-Path -LiteralPath $property.Value | Should -BeTrue
            [IO.File]::ReadAllText($property.Value).Length | Should -BeGreaterThan 0
        }
    }

    It 'preserves values, relationships, nulls, and counts across HTML, JSON, and CSV' {
        $assessment = New-ReportFixture
        $paths = Export-SsaAssessment -Assessment $assessment -OutputPath (Join-Path $script:reportTestRoot 'parity')
        $json = [IO.File]::ReadAllText($paths.JsonPath) | ConvertFrom-Json
        $embedded = Read-EmbeddedAssessment $paths.HtmlPath
        ($embedded | ConvertTo-Json -Depth 60 -Compress) | Should -Be ($json | ConvertTo-Json -Depth 60 -Compress)
        ($json | ConvertTo-Json -Depth 60 -Compress) | Should -Be ($assessment | ConvertTo-Json -Depth 60 -Compress)
        $json.Targets[0].MonthlyPayg | Should -BeNullOrEmpty
        $json.Targets[1].MonthlyPayg | Should -Be 123.45
        $json.Configuration.AhbEligible | Should -BeFalse
        $embedded.Inventory[0].Id | Should -Be 5
        $embedded.Inventory[0].DataMB | Should -Be 102400
        $summary = @(Import-Csv -LiteralPath $paths.CsvFiles.'target-summary')
        $summary.Count | Should -Be 3
        $summary[0].MonthlyPayg | Should -Be ''
        $summary[1].MonthlyPayg | Should -Be '123.45'
        @(Import-Csv -LiteralPath $paths.CsvFiles.findings).Count | Should -Be $json.Findings.Count
        @(Import-Csv -LiteralPath $paths.CsvFiles.'rule-coverage').Count | Should -Be $json.RuleEvaluations.Count
        $recommendation = @(Import-Csv -LiteralPath $paths.CsvFiles.recommendations)[0]
        $recommendation.RecommendationId | Should -Be $json.Recommendations[0].RecommendationId
        $recommendation.CatalogId | Should -Be 'mi-gp'
        $costs = @(Import-Csv -LiteralPath $paths.CsvFiles.'cost-components')
        $costs.Count | Should -Be 2
        $costs[0].RecommendationId | Should -Be $recommendation.RecommendationId
        $costs[0].Target | Should -Be 'ManagedInstance'
        $costs[0].MonthlyCost | Should -Be '123.45'
        $costs[1].Status | Should -Be 'NotEligible'
        $costs[1].TotalMonthly | Should -Be ''
        $costs[1].Component | Should -Be ''
        @($costs[0].Errors | ConvertFrom-Json).Count | Should -Be 1
        @(Import-Csv -LiteralPath $paths.CsvFiles.'performance-summary')[0].Peak | Should -Be '90'
    }

    It 'retains VM tempdb placement and the billable disk layout in every export' {
        $assessment = New-ReportFixture
        $rec = $assessment.Recommendations[0]
        $rec.Target = 'SqlVm'
        $rec | Add-Member NoteProperty TempdbPlacement 'LocalTemporary'
        $rec | Add-Member NoteProperty DiskLayout @([pscustomobject]@{DiskId='P10-LRS';Role='Os';Count=1})
        $paths = Export-SsaAssessment $assessment -OutputPath (Join-Path $script:reportTestRoot 'tempdb-placement')
        $json = Get-Content -LiteralPath $paths.JsonPath -Raw | ConvertFrom-Json
        $embedded = Read-EmbeddedAssessment $paths.HtmlPath
        $csv = @(Import-Csv -LiteralPath $paths.CsvFiles.recommendations)[0]
        $json.Recommendations[0].TempdbPlacement | Should -Be LocalTemporary
        $embedded.Recommendations[0].TempdbPlacement | Should -Be LocalTemporary
        $csv.TempdbPlacement | Should -Be LocalTemporary
        @($csv.DiskLayout | ConvertFrom-Json)[0].Role | Should -Be Os
    }

    It 'preserves client evidence and coverage across HTML, JSON, and formula-safe CSV' {
        $assessment = New-ReportFixture
        $attack = '</script><img src=x onerror=alert(1)>'
        $assessment | Add-Member NoteProperty ClientDependencies ([pscustomobject]@{
            Status = 'Partial'; SnapshotsObserved = 2; SnapshotsUnavailable = 1; SnapshotsNotCollected = 0
            FirstSnapshotAt = '2026-01-01T00:00:00Z'; LastSnapshotAt = '2026-01-01T00:00:30Z'; SampleIntervalSeconds = 30
            Clients = @([pscustomobject]@{
                Location = 'Remote'; ClientAddress = '192.0.2.10'; HostName = '=malicious-client'; ProgramName = $attack
                ClientInterfaceName = 'Example driver'; LoginName = 'example-login'; Databases = @('App','OtherDb')
                Transports = @('TCP'); AuthenticationSchemes = @('KERBEROS'); EncryptionStates = @('TRUE')
                FirstObservedAt = '2026-01-01T00:00:00Z'; LastObservedAt = '2026-01-01T00:00:30Z'; SamplesSeen = 2; PeakSessions = 3
            }); Diagnostics = @([pscustomobject]@{ Message = 'Fixture denied.'; SnapshotCount = 1 }); Notes = @('Observed only.')
        })
        $paths = Export-SsaAssessment $assessment -OutputPath (Join-Path $script:reportTestRoot 'clients')
        $json = Get-Content -Raw $paths.JsonPath | ConvertFrom-Json
        $embedded = Read-EmbeddedAssessment $paths.HtmlPath
        ($embedded.ClientDependencies | ConvertTo-Json -Depth 10) | Should -Be ($json.ClientDependencies | ConvertTo-Json -Depth 10)
        $embedded.ClientDependencies.Status | Should -Be Partial
        $csv = @(Import-Csv $paths.CsvFiles.'client-dependencies')
        $csv.Count | Should -Be 1
        $csv[0].HostName | Should -Be "'=malicious-client"
        $csv[0].ProgramName | Should -Be $attack
        $csvDatabases = $csv[0].Databases | ConvertFrom-Json
        $csvDatabases.Count | Should -Be 2
        $csvDatabases[0] | Should -Be App
        $csvDatabases[1] | Should -Be OtherDb
        $csv[0].SamplesSeen | Should -Be '2'
        $csv[0].PeakSessions | Should -Be '3'
        $html = Get-Content -Raw $paths.HtmlPath
        $html | Should -Match 'id="clients"'
        $html | Should -Match 'client-filter-location'
        $html | Should -Not -Match '<img src=x'
    }

    It 'retains configured MI IOPS, included resources, extra memory, and reserved storage across all exports' {
        $assessment = New-ReportFixture
        $rec = $assessment.Recommendations[0]
        foreach ($entry in @(
            @{Name='ReservedStorageGB';Value=1024},@{Name='ProvisionedIops';Value=6400},
            @{Name='IncludedIops';Value=3072},@{Name='AdditionalIops';Value=3328},@{Name='AdditionalMemoryGB';Value=12}
        )) { $rec | Add-Member NoteProperty $entry.Name $entry.Value }
        $paths = Export-SsaAssessment $assessment -OutputPath (Join-Path $script:reportTestRoot 'mi-resources')
        $json = Get-Content -LiteralPath $paths.JsonPath -Raw | ConvertFrom-Json
        $embedded = Read-EmbeddedAssessment $paths.HtmlPath
        $csv = @(Import-Csv -LiteralPath $paths.CsvFiles.recommendations)[0]
        foreach ($name in @('ReservedStorageGB','ProvisionedIops','IncludedIops','AdditionalIops','AdditionalMemoryGB')) {
            $json.Recommendations[0].$name | Should -Be $rec.$name
            $embedded.Recommendations[0].$name | Should -Be $rec.$name
            $csv.$name | Should -Be ([string]$rec.$name)
            [IO.File]::ReadAllText($paths.HtmlPath) | Should -Match ('"'+$name+'"')
        }
    }
    It 'preserves VM active/base cores, generation, preview state, local storage type and remote controller across every export' -ForEach @(
        @{Family='Eadsv7';BaseSize='Standard_E32ads_v7';BaseCores=32;Generation=7;LocalDisks=4;LocalDiskGB=440;LocalType='NVMe'},
        @{Family='Ebdsv5';BaseSize='Standard_E112ibds_v5';BaseCores=112;Generation=5;LocalDisks=1;LocalDiskGB=3800;LocalType='SSD'}
    ) {
        $assessment = New-ReportFixture
        $rec = $assessment.Recommendations[0]
        $rec.Target = 'SqlVm'
        $fields = @{
            BaseVmSize=$BaseSize;BaseVCores=$BaseCores;VmGeneration=$Generation;VmPreview=$false
            LocalTempDisks=$LocalDisks;LocalTempDiskGB=$LocalDiskGB;LocalTempGB=($LocalDisks*$LocalDiskGB)
            LocalTempDiskType=$LocalType;RemoteDiskController='NVMe'
        }
        foreach ($name in $fields.Keys) { $rec | Add-Member NoteProperty $name $fields[$name] }
        $paths = Export-SsaAssessment $assessment -OutputPath (Join-Path $script:reportTestRoot ('vm-resources-'+$Family))
        $json = Get-Content -LiteralPath $paths.JsonPath -Raw | ConvertFrom-Json
        $embedded = Read-EmbeddedAssessment $paths.HtmlPath
        $csv = @(Import-Csv -LiteralPath $paths.CsvFiles.recommendations)[0]
        foreach ($name in $fields.Keys) {
            $json.Recommendations[0].$name | Should -Be $fields[$name]
            $embedded.Recommendations[0].$name | Should -Be $fields[$name]
            $csv.$name | Should -Be ([string]$fields[$name])
            [IO.File]::ReadAllText($paths.HtmlPath) | Should -Match ('"'+$name+'"')
        }
    }

    It 'neutralizes closing script tags without losing hostile data in JSON' {
        $assessment = New-ReportFixture
        $attack = '</script><script>window.pwned=true</script><img src=x onerror=alert(1)>&' + [char]0x2028 + [char]0x2029
        $assessment.Source.Instance = $attack
        $assessment.Findings[0].Message = $attack
        $assessment.Findings[0].SourceUrl = 'javascript:alert(1)'
        $paths = Export-SsaAssessment -Assessment $assessment -OutputPath (Join-Path $script:reportTestRoot 'hostile')
        $html = [IO.File]::ReadAllText($paths.HtmlPath)
        $html | Should -Not -Match '<script>window\.pwned'
        $html | Should -Not -Match '<img src=x'
        $html | Should -Match '\\u003c/script\\u003e'
        $html | Should -Match '\\u2028\\u2029'
        (Read-EmbeddedAssessment $paths.HtmlPath).Findings[0].Message | Should -Be $attack
        ([IO.File]::ReadAllText($paths.JsonPath) | ConvertFrom-Json).Source.Instance | Should -Be $attack
        $html | Should -Not -Match '\.innerHTML|insertAdjacentHTML|document\.write'
        $html | Should -Match 'textContent'
        $html | Should -Match 'https:'
        $html | Should -Match 'learn\.microsoft\.com'
        $html | Should -Match "connect-src 'none'"
        $html | Should -Not -Match '<script[^>]+src=|<link[^>]+href=|\bfetch\s*\(|XMLHttpRequest'
    }

    It 'protects CSV formulas including control-prefixed values while leaving JSON and the input untouched' {
        $assessment = New-ReportFixture
        $values = @('=1+1', '+cmd', '-2+3', '@SUM(A1:A2)', " `t=HYPERLINK(`"https://example.invalid`")", "`tplain", "`rplain", "`nplain", ([string][char]0xFEFF + '=1'), "comma, quote`" and`nline", 'sales', '123')
        $assessment.Findings = @($values | ForEach-Object {
            [pscustomobject]@{ Target = 'SqlDatabase'; RuleId = 'DB001'; Database = $_; Message = $_; Line = -1 }
        })
        $paths = Export-SsaAssessment -Assessment $assessment -OutputPath (Join-Path $script:reportTestRoot 'formula')
        $csv = @(Import-Csv -LiteralPath $paths.CsvFiles.findings)
        $json = [IO.File]::ReadAllText($paths.JsonPath) | ConvertFrom-Json
        for ($i = 0; $i -lt $values.Count; $i++) {
            $expected = $values[$i]
            if ($i -lt 9) { $expected = "'" + $expected }
            $csv[$i].Database | Should -Be $expected
            $json.Findings[$i].Database | Should -Be $values[$i]
            $assessment.Findings[$i].Database | Should -Be $values[$i]
            $csv[$i].Line | Should -Be '-1'
        }
    }

    It 'bounds large HTML series while preserving extrema, gap edges, missing metrics, and original JSON' {
        $assessment = New-ReportFixture
        $start = [datetimeoffset]::Parse('2026-10-22T00:00:00Z')
        $assessment.Performance.Series = @(for ($i = 0; $i -lt 2500; $i++) {
            $seconds = $i * 10
            if ($i -ge 1250) { $seconds += 3600 }
            $cpu = 25
            if ($i -eq 343) { $cpu = 99 }
            if ($i -eq 918) { $cpu = 1 }
            $memory = 8
            if ($i -eq 1499) { $memory = $null }
            [pscustomobject]@{ Timestamp = $start.AddSeconds($seconds).ToString('o'); CpuPercent = $cpu; MemoryGB = $memory; Iops = 100; ThroughputMBps = 2.5 }
        })
        $paths = Export-SsaAssessment -Assessment $assessment -OutputPath (Join-Path $script:reportTestRoot 'large-series')
        $embedded = Read-EmbeddedAssessment $paths.HtmlPath
        $original = [IO.File]::ReadAllText($paths.JsonPath) | ConvertFrom-Json
        $original.Performance.Series.Count | Should -Be 2500
        $assessment.Performance.Series.Count | Should -Be 2500
        $embedded.Performance.Series.Count | Should -BeLessThan 2000
        $embedded.Performance.ReportSeries.InputCount | Should -Be 2500
        $embedded.Performance.ReportSeries.Discontinuities.Count | Should -Be 1
        @($embedded.Performance.Series | Where-Object { $_.CpuPercent -eq 99 }).Count | Should -Be 1
        @($embedded.Performance.Series | Where-Object { $_.CpuPercent -eq 1 }).Count | Should -Be 1
        foreach ($index in @(0, 1249, 1250, 1498, 1499, 1500, 2499)) {
            @($embedded.Performance.Series | Where-Object { ([datetimeoffset]$_.Timestamp) -eq ([datetimeoffset]$assessment.Performance.Series[$index].Timestamp) }).Count | Should -Be 1
        }
    }

    It 'handles empty and partial result objects and still writes CSV headers' {
        foreach ($assessment in @(
            [pscustomobject]@{},
            [pscustomobject]@{ Targets = @(); Findings = @(); Prices = @(); Performance = [pscustomobject]@{ State = 'Pending'; Summary = @(); Series = @() } },
            [pscustomobject]@{ Targets = $null; Findings = $null; Performance = $null; Recommendations = @([pscustomobject]@{ RecommendationId = 'pending'; Status = 'Unavailable' }) }
        )) {
            $paths = Export-SsaAssessment -Assessment $assessment -OutputPath (Join-Path $script:reportTestRoot ([guid]::NewGuid().ToString('N')))
            { Read-EmbeddedAssessment $paths.HtmlPath } | Should -Not -Throw
            [IO.File]::ReadAllText($paths.CsvFiles.findings).Trim() | Should -Be '"Target","RuleId","Category","PublishedCategory","Scope","Database","Object","Line","Message","Remediation","SourceUrl"'
            @(Import-Csv -LiteralPath $paths.CsvFiles.findings).Count | Should -Be 0
            [IO.File]::ReadAllText($paths.HtmlPath) | Should -Match 'Not available|Unavailable'
        }
    }

    It 'removes SQL definitions and secrets recursively, preserving permitted inventory metadata' {
        $assessment = New-ReportFixture
        $assessment.Inventory = [pscustomobject]@{
            Databases = @([pscustomobject]@{ Database = 'sales'; State = 'Online'; AssessmentState = 'Assessed'; DataGB = 100; Definition = 'SECRET_DEFINITION' })
            Dependencies = @('sales -> warehouse'); JobSteps = @([pscustomobject]@{ Command = 'SECRET_JOB' })
            Password = 'SECRET_PASSWORD'; SqlText = 'SECRET_SQL'
        }
        $assessment | Add-Member -NotePropertyName Definitions -NotePropertyValue @('SECRET_MODULE')
        $paths = Export-SsaAssessment -Assessment $assessment -OutputPath (Join-Path $script:reportTestRoot 'sanitized')
        $html = [IO.File]::ReadAllText($paths.HtmlPath)
        $jsonText = [IO.File]::ReadAllText($paths.JsonPath)
        $html | Should -Not -Match 'SECRET_'
        $jsonText | Should -Not -Match 'SECRET_'
        ($jsonText | ConvertFrom-Json).Inventory.Databases[0].DataGB | Should -Be 100
        $assessment.Inventory.Password | Should -Be 'SECRET_PASSWORD'
    }

    It 'atomically replaces existing snapshots and cleans staging files after a failed replacement' {
        $assessment = New-ReportFixture
        $directory = Join-Path $script:reportTestRoot 'atomic'
        $paths = Export-SsaAssessment -Assessment $assessment -OutputPath $directory
        $assessment.AssessmentId = 'assessment-2'
        Export-SsaAssessment -Assessment $assessment -OutputPath $directory | Out-Null
        (Read-EmbeddedAssessment $paths.HtmlPath).AssessmentId | Should -Be 'assessment-2'
        $old = [IO.File]::ReadAllText($paths.HtmlPath)
        $lock = [IO.File]::Open($paths.HtmlPath, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
        try {
            { Write-SsaReportText -Path $paths.HtmlPath -Text 'truncated' } | Should -Throw
        } finally { $lock.Dispose() }
        [IO.File]::ReadAllText($paths.HtmlPath) | Should -Be $old
        @(Get-ChildItem -LiteralPath $directory -Recurse -Filter '*.tmp').Count | Should -Be 0
    }

    It 'contains keyboard labels, comparison targets, print support, charts, and the Clawpilot theme' {
        $paths = Export-SsaAssessment -Assessment (New-ReportFixture) -OutputPath (Join-Path $script:reportTestRoot 'ui')
        $html = [IO.File]::ReadAllText($paths.HtmlPath)
        foreach ($fragment in @('scoutTheme', '--cp-bg: #f7f4ef;', '--cp-accent: #fd8ea1;', 'Segoe UI', 'aria-live="polite"', 'aria-label', '@media print', 'beforeprint', 'createElementNS', 'SqlDatabase', 'ManagedInstance', 'SqlVm', 'Source inventory', 'Itemized pricing', 'Assumptions')) {
            $html | Should -Match ([regex]::Escape($fragment))
        }
        $html | Should -Not -Match '__SSA_DATA__|__SSA_STYLES__|__SSA_SCRIPT__'
    }
}
