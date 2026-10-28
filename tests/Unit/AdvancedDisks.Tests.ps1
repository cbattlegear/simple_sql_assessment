BeforeAll {
    $root = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
    Import-Module (Join-Path $root 'src\SimpleSqlAssessment\SimpleSqlAssessment.psd1') -Force
    . (Join-Path (Split-Path $PSScriptRoot -Parent) 'TestHelpers.ps1')
    $script:module = Get-Module SimpleSqlAssessment
    $script:catalog = & $script:module { Get-SsaCatalog }
    $script:prices = (Get-Content (Join-Path $root 'src\SimpleSqlAssessment\Catalogs\vm-retail-reference.json') -Raw | ConvertFrom-Json).Items
    $script:collection = Join-Path $TestDrive 'advanced'
    $null = Save-ObservedBundle $script:collection
    $script:recommendations = @(Get-SsaSkuRecommendation -CollectionPath $script:collection -Region eastus | Where-Object Target -EQ SqlVm)
    function Get-DiskRec([string]$Type) {
        ($script:recommendations | Where-Object DiskType -EQ $Type | ConvertTo-Json -Depth 50) | ConvertFrom-Json
    }
}
Describe 'Full configurable storage allocation and exact pricing' {
    It 'returns independently sized options for all three types, with Premium SSD OS and local tempdb' {
        $script:recommendations.Count | Should -Be 3
        ($script:recommendations.DiskType -join ',') | Should -Be 'PremiumSSD,PremiumSSDv2,UltraSSD'
        foreach ($rec in $script:recommendations) {
            $rec.Status | Should -Be Provisional
            ($rec.DiskLayout | Where-Object Role -EQ Os).DiskId | Should -Be 'P10-LRS'
            @($rec.DiskLayout | Where-Object Role -EQ Tempdb).Count | Should -Be 0
        }
    }
    It 'retains separate advanced envelopes on every base and constrained VM' {
        @($script:catalog.Vm | Where-Object { -not $_.MaxAdvancedIops -or -not $_.MaxAdvancedThroughputMBps }).Count | Should -Be 0
        foreach ($vm in @($script:catalog.Vm | Where-Object { $_.Id -ne $_.BaseVmSize })) {
            $parent = $script:catalog.Vm | Where-Object Id -EQ $vm.BaseVmSize
            $vm.MaxAdvancedIops | Should -Be $parent.MaxAdvancedIops
            $vm.MaxAdvancedThroughputMBps | Should -Be $parent.MaxAdvancedThroughputMBps
        }
        $largest = $script:catalog.Vm | Where-Object Id -EQ Standard_E112ibds_v5
        $largest.MaxIops | Should -Be 260000
        $largest.MaxAdvancedIops | Should -Be 400000
        $largest.MaxAdvancedThroughputMBps | Should -Be 10000
    }
    It 'allocates the full size/performance boundary <Type>/<Size>/<Io>/<Mbps>' -ForEach @(
        @{Type='PremiumSSDv2';Size=1;Io=3000;Mbps=125},
        @{Type='PremiumSSDv2';Size=8;Io=4000;Mbps=1000},
        @{Type='PremiumSSDv2';Size=160;Io=80000;Mbps=2000},
        @{Type='PremiumSSDv2';Size=65536;Io=80000;Mbps=2000},
        @{Type='UltraSSD';Size=4;Io=100;Mbps=1},
        @{Type='UltraSSD';Size=400;Io=400000;Mbps=10000},
        @{Type='UltraSSD';Size=65536;Io=400000;Mbps=10000}
    ) {
        $profile = $script:catalog.DiskProfiles | Where-Object Id -EQ $Type
        $entry = & $script:module {param($p,$s,$i,$m) Get-SsaConfigurableDisk $p $s $i $m 1 Data} $profile $Size $Io $Mbps
        $entry.SizeGB | Should -Be $Size
        $entry.Iops | Should -Be $Io
        $entry.ThroughputMBps | Should -Be $Mbps
        { & $script:module {param($e,$p) Assert-SsaConfigurableDisk $e $p eastus} $entry $profile } | Should -Not -Throw
    }
    It 'rejects invalid provisioned <Field>=<Value>' -ForEach @(
        @{Field='SizeGB';Value=0},@{Field='SizeGB';Value=65537},@{Field='SizeGB';Value=1.5},
        @{Field='Iops';Value=2999},@{Field='Iops';Value=80001},
        @{Field='ThroughputMBps';Value=124},@{Field='ThroughputMBps';Value=2001},
        @{Field='Count';Value=0},@{Field='Count';Value=1.5},
        @{Field='Caching';Value='ReadOnly'},@{Field='Role';Value='OS'},@{Field='Redundancy';Value='ZRS'}
    ) {
        $rec = Get-DiskRec PremiumSSDv2
        $disk = @($rec.DiskLayout | Where-Object Role -EQ Data)[0]
        $disk.$Field = $Value
        $q = @($rec | Get-SsaPriceEstimate -Region eastus -PriceData $script:prices)[0]
        $q.Status | Should -Not -Be Complete
        $q.TotalMonthly | Should -BeNullOrEmpty
    }
    It 'rejects same-disk capacity/IOPS and throughput/IOPS coupling violations' {
        $profile = $script:catalog.DiskProfiles | Where-Object Id -EQ PremiumSSDv2
        foreach ($entry in @(
            [pscustomobject]@{Role='Data';Count=1;SizeGB=7;Iops=4000;ThroughputMBps=125},
            [pscustomobject]@{Role='Data';Count=1;SizeGB=100;Iops=3000;ThroughputMBps=751}
        )) {
            { & $script:module {param($e,$p) Assert-SsaConfigurableDisk $e $p eastus} $entry $profile } | Should -Throw '*coupling*'
        }
    }
    It 'creates multiple advanced disks when capacity exceeds one disk and respects attachment limits' {
        $result = & $script:module {
            $c=Get-SsaCatalog; $vm=[pscustomobject]@{MaxDataDisks=3;LocalTempGB=100}
            Get-SsaDiskLayout $vm $c 100000 10 1 1 1 1 $null UltraSSD
        }
        ($result | Where-Object Role -EQ Data).Count | Should -Be 2
        $none = & $script:module {
            $c=Get-SsaCatalog; $vm=[pscustomobject]@{MaxDataDisks=2;LocalTempGB=100}
            Get-SsaDiskLayout $vm $c 100000 10 1 1 1 1 $null UltraSSD
        }
        $none | Should -BeNullOrEmpty
    }
    It 'uses the enhanced E112ibds_v5 limits in actual candidate selection, not just catalog display' {
        $analysis = & $script:module {param($p) Get-SsaPerformanceAnalysis $p (Read-SsaBundle $p)} $script:collection
        foreach ($sample in $analysis.Samples) { $sample.HostIops=300000 }
        $isolated = $script:catalog.PSObject.Copy()
        $isolated.Vm = @($script:catalog.Vm | Where-Object Id -EQ Standard_E112ibds_v5)
        Mock Get-SsaPerformanceAnalysis -ModuleName SimpleSqlAssessment { $analysis }
        Mock Get-SsaCatalog -ModuleName SimpleSqlAssessment { $isolated }
        $items=@(Get-SsaSkuRecommendation $script:collection -HeadroomPercent 0 -Region eastus | Where-Object Target -EQ SqlVm)
        ($items | Where-Object DiskType -EQ PremiumSSD).Status | Should -Be Unavailable
        foreach ($type in @('PremiumSSDv2','UltraSSD')) {
            $item=$items | Where-Object DiskType -EQ $type
            $item.CatalogId | Should -Be Standard_E112ibds_v5
            ($item.Constraints | Where-Object Resource -EQ 'I/O operations').Limit | Should -Be 400000
            ($item.Constraints | Where-Object Resource -EQ 'I/O operations').Required | Should -Be 300000
        }
    }
    It 'keeps managed tempdb on the same VM for each advanced type when local capacity is exceeded' {
        $large=Join-Path $TestDrive 'tempdb-fallback'
        $null=Save-ObservedBundle $large -TempdbSizeMB (111*1024)
        $items=@(Get-SsaSkuRecommendation $large -StorageGrowthPercent 0 -Region eastus | Where-Object Target -EQ SqlVm)
        foreach ($type in @('PremiumSSDv2','UltraSSD')) {
            $baseline=$script:recommendations | Where-Object DiskType -EQ $type
            $rec=$items | Where-Object DiskType -EQ $type
            $rec.VmSize | Should -Be $baseline.VmSize
            $rec.TempdbPlacement | Should -Be ManagedDisk
            ($rec.DiskLayout | Where-Object Role -EQ Tempdb).DiskType | Should -Be $type
        }
    }
    It 'prices all three options completely and suggests exactly one per eligible scenario' {
        $quotes = @($script:recommendations | Get-SsaPriceEstimate -Region eastus -PriceData $script:prices -SqlHybridBenefit -WindowsHybridBenefit)
        $quotes.Count | Should -Be 6
        @($quotes | Where-Object Status -NE Complete).Count | Should -Be 0
        foreach ($scenario in @('Payg','Ahb')) {
            @($quotes | Where-Object { $_.Scenario -eq $scenario -and $_.IsSuggested }).Count | Should -Be 1
            ($quotes | Where-Object { $_.Scenario -eq $scenario -and $_.IsSuggested }).DiskType | Should -Be PremiumSSDv2
        }
    }
    It 'selects the exact paid v2 tiers, subtracting included performance once per disk' {
        $rec = Get-DiskRec PremiumSSDv2
        $data = $rec.DiskLayout | Where-Object Role -EQ Data
        $data.SizeGB=100; $data.Iops=20000; $data.ThroughputMBps=500; $data.Count=2
        $data.BilledSizeGB=100
        $q = @($rec | Get-SsaPriceEstimate -Region eastus -PriceData $script:prices)[0]
        $q.Status | Should -Be Complete
        ($q.Components | Where-Object Component -EQ DataDiskIops).Quantity | Should -Be (17000*2*730)
        ($q.Components | Where-Object Component -EQ DataDiskIops).Rate | Should -Be 0.000007
        ($q.Components | Where-Object Component -EQ DataDiskThroughput).Quantity | Should -Be (375*2*730)
        ($q.Components | Where-Object Component -EQ DataDiskThroughput).Rate | Should -Be 0.000055
        $missing = @($script:prices | Where-Object { -not ($_.productName -eq 'Azure Premium SSD v2' -and $_.tierMinimumUnits -eq 3000) })
        $partial = @($rec | Get-SsaPriceEstimate -Region eastus -PriceData $missing)[0]
        $partial.TotalMonthly | Should -BeNullOrEmpty
        $partial.Status | Should -Be Partial
    }
    It 'keeps provisioned advanced disk charges unchanged when compute runs fewer hours' {
        foreach ($type in @('PremiumSSDv2','UltraSSD')) {
            $rec = Get-DiskRec $type
            $full=@($rec | Get-SsaPriceEstimate -Region eastus -PriceData $script:prices)[0]
            $short=@($rec | Get-SsaPriceEstimate -Region eastus -PriceData $script:prices -HoursPerMonth 100)[0]
            foreach ($part in @($full.Components | Where-Object Component -Match Disk)) {
                ($short.Components | Where-Object Component -EQ $part.Component).MonthlyCost | Should -Be $part.MonthlyCost
            }
            $short.TotalMonthly | Should -BeLessThan $full.TotalMonthly
        }
    }
    It 'reports all alternatives even when a disk type is unavailable in the requested region' {
        $items=@(Get-SsaSkuRecommendation -CollectionPath $script:collection -Region westindia | Where-Object Target -EQ SqlVm)
        $items.Count | Should -Be 3
        ($items | Where-Object DiskType -EQ PremiumSSD).Status | Should -Be Provisional
        ($items | Where-Object DiskType -EQ PremiumSSDv2).Status | Should -Be Unavailable
        ($items | Where-Object DiskType -EQ UltraSSD).Status | Should -Be Unavailable
    }
    It 'preserves all disk quotes and suggestion evidence in HTML, JSON and CSV' {
        $r=[pscustomobject]@{Recommendations=$script:recommendations;Prices=@($script:recommendations | Get-SsaPriceEstimate -Region eastus -PriceData $script:prices)}
        $out=Export-SsaAssessment $r (Join-Path $TestDrive 'advanced-report')
        $json=Get-Content $out.JsonPath -Raw | ConvertFrom-Json
        @($json.Recommendations | Where-Object DiskType).Count | Should -Be 3
        @(Import-Csv $out.CsvFiles.'disk-alternatives').Count | Should -Be 6
        (Get-Content $out.HtmlPath -Raw) | Should -Match 'VM disk alternatives'
        @($json.Prices | Where-Object { $_.IsSuggested }).Count | Should -Be 1
    }
}
Describe 'Latency and correlated queue suggestions' {
    It 'round-trips an absent queue array without manufacturing an empty-object observation' {
        $a=New-TestRawSample 0; $b=New-TestRawSample 30
        $sample=& $script:module {param($x,$y) ConvertTo-SsaRateSample $x $y 30} $a $b
        $roundtrip=$sample | ConvertTo-Json -Depth 20 | ConvertFrom-Json
        @($roundtrip.DiskPressure).Count | Should -Be 0
        $roundtrip.DiskPressure=@([pscustomobject]@{})
        $assessment=& $script:module {param($s) Get-SsaStorageAssessment @($s)} $roundtrip
        $assessment.SqlVolumeQueueLength | Should -BeNullOrEmpty
        $assessment.QueueObservedSeconds | Should -Be 0
    }
    It 'derives interval latency, never cumulative average, and excludes tempdb' {
        $a=New-TestRawSample 0; $b=New-TestRawSample 30
        $b.Files[0].ReadStallMs=4500; $b.Files[0].WriteStallMs=1500
        $sample=& $script:module {param($x,$y) ConvertTo-SsaRateSample $x $y 30} $a $b
        $sample.FileIoLatency[0].ReadLatencyMs | Should -Be 15
        $assessment=& $script:module {param($s) Get-SsaStorageAssessment @($s)} $sample
        $assessment.SqlFileLatencyMs | Should -Be 15
        $assessment.Policy | Should -Be SubmillisecondPreferred
        $assessment.SqlVolumeQueueLength | Should -BeNullOrEmpty
    }
    It 'does not up-sell solely for queue depth or unrelated-volume queues' {
        $sample=[pscustomobject]@{
            UsableSeconds=30; FileIoLatency=@([pscustomobject]@{DatabaseId=5;Volume='C:\';ReadLatencyMs=7;WriteLatencyMs=$null})
            DiskPressure=@([pscustomobject]@{Volume='D:';AvgQueueLength=10})
        }
        $assessment=& $script:module {param($s) Get-SsaStorageAssessment @($s)} $sample
        $assessment.Policy | Should -Be GeneralSsd
        $sample.DiskPressure[0].Volume='c:'
        $assessment=& $script:module {param($s) Get-SsaStorageAssessment @($s)} $sample
        $assessment.Policy | Should -Be SubmillisecondPreferred
        $sample.FileIoLatency[0].ReadLatencyMs=2
        $assessment=& $script:module {param($s) Get-SsaStorageAssessment @($s)} $sample
        $assessment.Policy | Should -Be GeneralSsd
    }
    It 'leaves missing evidence and incomplete prices explicitly unsuggested' {
        $rec=Get-DiskRec PremiumSSDv2
        $rec.StorageAssessment.Policy='InsufficientEvidence'
        $q=@($rec | Get-SsaPriceEstimate -Region eastus -PriceData $script:prices)[0]
        $q.IsSuggested | Should -BeFalse
        $q.SuggestionReason | Should -Match 'insufficient'
        $rec.StorageAssessment.Policy='SubmillisecondPreferred'
        $q=@($rec | Get-SsaPriceEstimate -Region eastus -PriceData @())[0]
        $q.IsSuggested | Should -BeFalse
        $q.TotalMonthly | Should -BeNullOrEmpty
    }
    It 'includes slow tempdb only when managed disks must serve tempdb' {
        $sample=[pscustomobject]@{
            UsableSeconds=30; DiskPressure=@()
            FileIoLatency=@(
                [pscustomobject]@{DatabaseId=5;Volume='C:\';ReadLatencyMs=7;WriteLatencyMs=$null},
                [pscustomobject]@{DatabaseId=2;Volume='D:\';ReadLatencyMs=50;WriteLatencyMs=50}
            )
        }
        $local=& $script:module {param($s) Get-SsaStorageAssessment @($s)} $sample
        $external=& $script:module {param($s) Get-SsaStorageAssessment @($s) -IncludeTempdb} $sample
        $local.Policy | Should -Be GeneralSsd
        $external.Policy | Should -Be SubmillisecondPreferred
        $external.IncludesManagedTempdb | Should -BeTrue
    }
}
