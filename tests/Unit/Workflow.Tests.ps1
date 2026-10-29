BeforeAll {
    $root = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
    Import-Module (Join-Path $root 'src\SimpleSqlAssessment\SimpleSqlAssessment.psd1') -Force
    . (Join-Path (Split-Path $PSScriptRoot -Parent) 'TestHelpers.ps1')
    $script:module = Get-Module SimpleSqlAssessment
}
Describe 'Sizing and workflow integration' {
    BeforeEach {
        $script:collection = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        Mock Get-SsaCatalog -ModuleName SimpleSqlAssessment {
            $common = @{
                ServiceTier='GeneralPurpose';Hardware='Fixture';VCores=4;MemoryGB=16;MaxDataGB=1024;MaxLogGB=1024
                MaxIops=10000;MaxThroughputMBps=500;MaxLogMBps=100;MaxDatabases=500;MaxTempdbGB=1024
                SqlMajorVersions=@(11,12,13,14,15,16,17);SupportedEditions=@('Standard','Enterprise');MaxDataDisks=16
            }
            $db = [pscustomobject]$common.Clone(); $db | Add-Member NoteProperty Id 'db-fixture'; $db | Add-Member NoteProperty Target 'SqlDatabase'
            $mi = [pscustomobject]$common.Clone(); $mi | Add-Member NoteProperty Id 'mi-fixture'; $mi | Add-Member NoteProperty Target 'ManagedInstance'
            $mi | Add-Member NoteProperty SupportedRegions @('eastus')
            $vm = [pscustomobject]$common.Clone(); $vm | Add-Member NoteProperty Id 'vm-fixture'; $vm | Add-Member NoteProperty Target 'SqlVm'; $vm | Add-Member NoteProperty VmSize 'Fixture_VM'
            [pscustomobject]@{Version='fixture';SqlDatabase=@($db);ManagedInstance=@($mi);Vm=@($vm);Disks=@([pscustomobject]@{Id='FixtureDisk';SizeGB=128;Iops=1000;ThroughputMBps=200})}
        }
        Mock Get-SsaPriceEstimate -ModuleName SimpleSqlAssessment {
            param($Recommendation)
            foreach ($item in $Recommendation) {
                [pscustomobject]@{RecommendationId=$item.RecommendationId;Scenario='Payg';Status='Complete';TotalMonthly=100.0;Currency='USD';Region='eastus';HoursPerMonth=730;Components=@();Errors=@()}
            }
        }
        Mock New-SsaSqlConnection -ModuleName SimpleSqlAssessment { throw 'Offline analysis must not connect to SQL.' }
    }
    It 'produces constrained provisional recommendations for all three targets' {
        $null = Save-ObservedBundle $script:collection
        $recommendations = @(Get-SsaSkuRecommendation -CollectionPath $script:collection -TargetSqlMajorVersion 16)
        @($recommendations | Where-Object Status -EQ Unavailable).Count | Should -Be 0
        @($recommendations.Target | Select-Object -Unique).Count | Should -Be 3
        @($recommendations | Where-Object Target -EQ SqlVm)[0].DiskLayout.Count | Should -Be 4
        foreach ($recommendation in $recommendations) {
            $recommendation.Confidence | Should -Be 'Provisional'
            foreach ($constraint in $recommendation.Constraints) { $constraint.Required | Should -BeLessOrEqual $constraint.Limit }
        }
    }
    It 'never silently sizes a missing capture as a zero workload' {
        $null = Save-TestBundle $script:collection
        $recommendations = @(Get-SsaSkuRecommendation -CollectionPath $script:collection)
        @($recommendations | Where-Object Status -NE Unavailable).Count | Should -Be 0
    }
    It 'reports no fit when headroom pushes demand above all capacities' {
        $null = Save-ObservedBundle $script:collection
        $recommendations = @(Get-SsaSkuRecommendation -CollectionPath $script:collection -HeadroomPercent 500 -StorageGrowthPercent 500)
        # The VM requires six GiB workload memory plus four GiB OS; all remain explicitly constrained.
        foreach ($recommendation in @($recommendations | Where-Object Status -NE Unavailable)) {
            foreach ($constraint in $recommendation.Constraints) { $constraint.Required | Should -BeLessOrEqual $constraint.Limit }
        }
        Mock Get-SsaDemand -ModuleName SimpleSqlAssessment { 1000000.0 }
        @((Get-SsaSkuRecommendation -CollectionPath $script:collection) | Where-Object Status -NE Unavailable).Count | Should -Be 0
    }
    It 'emits all-target HTML/JSON/CSV offline without ever connecting to the source' {
        $null = Save-ObservedBundle $script:collection
        $output = Join-Path $TestDrive 'complete'
        $result = Invoke-SsaAssessment -CollectionPath $script:collection -OutputPath $output -Region eastus -Offline -TargetSqlMajorVersion 16
        $result.Targets.Count | Should -Be 3
        $result.Recommendations.Count | Should -Be 3
        $result.Performance.UsableSeconds | Should -Be 60
        Test-Path (Join-Path $output 'assessment.html') | Should -BeTrue
        Test-Path (Join-Path $output 'csv\findings.csv') | Should -BeTrue
        @($result.PSObject.Properties.Name | Where-Object { $_ -eq 'Definitions' }).Count | Should -Be 0
        Should -Invoke New-SsaSqlConnection -ModuleName SimpleSqlAssessment -Times 0 -Exactly
    }
    It 'supports an explicit static-only report without capture or pricing' {
        $null = Save-TestBundle $script:collection
        $output = Join-Path $TestDrive 'static'
        $result = Invoke-SsaAssessment -CollectionPath $script:collection -OutputPath $output -Region eastus -Offline -SkipPerformance
        $result.Performance.State | Should -Be 'Skipped'
        $result.Recommendations.Count | Should -Be 0
        Should -Invoke Get-SsaPriceEstimate -ModuleName SimpleSqlAssessment -Times 0 -Exactly
        Should -Invoke New-SsaSqlConnection -ModuleName SimpleSqlAssessment -Times 0 -Exactly
    }
    It 'resolves dot output and relative collection paths against the PowerShell location' {
        $working = Join-Path $TestDrive 'relative workflow (1)'
        $bundlePath = Join-Path $working 'source-bundle'
        $null = Save-ObservedBundle $bundlePath
        Push-Location -LiteralPath $working
        try {
            $result = Invoke-SsaAssessment -CollectionPath '.\source-bundle' -OutputPath '.' -Region eastus -Offline -TargetSqlMajorVersion 16
            $result.OutputFiles.OutputPath | Should -Be $working
            Test-Path -LiteralPath (Join-Path $working 'assessment.html') | Should -BeTrue
            $result.Performance.UsableSeconds | Should -Be 60
            $recommendations = @(Get-SsaSkuRecommendation -CollectionPath '.\source-bundle' -TargetSqlMajorVersion 16)
            @($recommendations | Where-Object Status -NE Unavailable).Count | Should -Be 3
        } finally { Pop-Location }
    }
    It 'stops at a collection failure without rules, reports, or missing-property cascades' {
        Mock New-SsaSqlConnection -ModuleName SimpleSqlAssessment {
            $command = [pscustomobject]@{ CommandText=''; CommandTimeout=0 }
            $command | Add-Member ScriptMethod Dispose {}
            $command | Add-Member ScriptMethod ExecuteReader { throw 'Reader must not run after failed login.' }
            $connection = [pscustomobject]@{ State='Closed'; Command=$command }
            $connection | Add-Member ScriptMethod CreateCommand { $this.Command }
            $connection | Add-Member ScriptMethod Open { throw 'Fixture certificate-chain failure.' }
            $connection | Add-Member ScriptMethod Dispose {}
            return $connection
        }
        Mock Invoke-SsaRules -ModuleName SimpleSqlAssessment { throw 'Rules must not run after failed collection.' }
        Mock Export-SsaAssessment -ModuleName SimpleSqlAssessment { throw 'Reports must not run after failed collection.' }
        $original = $ErrorActionPreference
        $failure = $null
        try {
            $ErrorActionPreference = 'Continue'
            try { $null = Invoke-SsaAssessment -SqlInstance fixture -OutputPath (Join-Path $TestDrive 'failed-live') -Region eastus -SkipPerformance }
            catch { $failure = $_ }
        } finally { $ErrorActionPreference = $original }
        $failure | Should -Not -BeNullOrEmpty
        $failure.ToString() | Should -Match 'certificate-chain failure'
        Should -Invoke Invoke-SsaRules -ModuleName SimpleSqlAssessment -Times 0 -Exactly
        Should -Invoke Export-SsaAssessment -ModuleName SimpleSqlAssessment -Times 0 -Exactly
    }
    It 'forwards certificate trust explicitly to live collection without disabling encryption by default' {
        $bundle = New-TestBundle
        Mock New-SsaCollection -ModuleName SimpleSqlAssessment { $bundle }
        $null = Invoke-SsaAssessment -SqlInstance fixture -OutputPath (Join-Path $TestDrive 'trusted-live') -Region eastus -SkipPerformance -TrustServerCertificate
        Should -Invoke New-SsaCollection -ModuleName SimpleSqlAssessment -Times 1 -Exactly -ParameterFilter { $TrustServerCertificate }
    }
    It 'passes the assessment region into MI hardware and storage eligibility checks' {
        $null = Save-ObservedBundle $script:collection
        $result = Invoke-SsaAssessment -CollectionPath $script:collection -OutputPath (Join-Path $TestDrive 'region') -Region westus3 -Offline -TargetSqlMajorVersion 16
        $mi = @($result.Recommendations | Where-Object Target -EQ ManagedInstance)
        $mi.Count | Should -Be 1
        $mi[0].Status | Should -Be Unavailable
        $mi[0].CatalogId | Should -BeNullOrEmpty
    }
    It 'persists and forwards the explicit Preview VM opt-in through the integrated workflow' {
        $null = Save-ObservedBundle $script:collection
        $fixture = & $script:module { Get-SsaCatalog }
        $fixture.Vm[0] | Add-Member NoteProperty Preview $true
        Mock Get-SsaCatalog -ModuleName SimpleSqlAssessment { $fixture }
        $default = Invoke-SsaAssessment -CollectionPath $script:collection -OutputPath (Join-Path $TestDrive 'no-preview') -Region eastus -Offline
        @($default.Recommendations | Where-Object Target -EQ SqlVm)[0].Status | Should -Be Unavailable
        $default.Configuration.IncludePreviewVm | Should -BeFalse
        $enabled = Invoke-SsaAssessment -CollectionPath $script:collection -OutputPath (Join-Path $TestDrive 'preview') -Region eastus -Offline -IncludePreviewVm
        @($enabled.Recommendations | Where-Object Target -EQ SqlVm)[0].Status | Should -Be Provisional
        @($enabled.Recommendations | Where-Object Target -EQ SqlVm)[0].VmPreview | Should -BeTrue
        $enabled.Configuration.IncludePreviewVm | Should -BeTrue
    }
    It 'does not pass rules when definition visibility or encrypted content is incomplete' {
        $bundle = New-TestBundle
        @($bundle.Evidence | Where-Object Kind -EQ Definitions)[0].Status = 'Unavailable'
        $bundle.Definitions = @([pscustomobject]@{Database='App';Object='dbo.Encrypted';Text=$null;Encrypted=$true;Source='Module'})
        $rules = & $script:module {param($b) Invoke-SsaRules $b} $bundle
        @($rules.Evaluations | Where-Object { $_.RuleId -eq 'XpCmdshell' -and $_.Status -eq 'NeedsReview' }).Count | Should -Be 2
        @($rules.Evaluations | Where-Object { $_.RuleId -eq 'XpCmdshell' -and $_.Status -eq 'Pass' }).Count | Should -Be 0
    }
}
