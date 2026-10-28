BeforeAll {
    $root = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
    Import-Module (Join-Path $root 'src\SimpleSqlAssessment\SimpleSqlAssessment.psd1') -Force
    . (Join-Path (Split-Path $PSScriptRoot -Parent) 'TestHelpers.ps1')
    $script:module = Get-Module SimpleSqlAssessment
    $script:catalog = & $script:module { Get-SsaCatalog }
    $script:vmPrices = (Get-Content (Join-Path $root 'src\SimpleSqlAssessment\Catalogs\vm-retail-reference.json') -Raw | ConvertFrom-Json).Items
    function New-VmQuoteInput {
        param($Candidate)
        [pscustomobject]@{
            RecommendationId=$Candidate.Id; CatalogId=$Candidate.Id; Target='SqlVm'; Status='Provisional'
            VCores=$Candidate.VCores; MemoryGB=$Candidate.MemoryGB; VmSize=$Candidate.VmSize
            ServiceTier=$Candidate.ServiceTier; Hardware=$Candidate.Hardware
            SqlEdition='Enterprise'; SqlMajorVersion=17; DataGB=1; LogGB=1; TempdbGB=20
            DiskLayout=@(
                [pscustomobject]@{DiskId='P10-LRS';Role='Os';Count=1},
                [pscustomobject]@{DiskId='P1-LRS';Role='Data';Count=1},
                [pscustomobject]@{DiskId='P1-LRS';Role='Log';Count=1}
            )
        }
    }
}

Describe 'Complete scoped E-series matrix' {
    It 'contains 62 base sizes and 37 constrained sizes, with only 10 explicit preview candidates' {
        $script:catalog.Version | Should -Be '2026.10.27.3'
        $script:catalog.Vm.Count | Should -Be 99
        @($script:catalog.Vm | Where-Object { $_.Id -eq $_.BaseVmSize }).Count | Should -Be 62
        @($script:catalog.Vm | Where-Object { $_.Id -ne $_.BaseVmSize }).Count | Should -Be 37
        @($script:catalog.Vm | Where-Object Preview).Count | Should -Be 10
        @($script:catalog.Vm | Where-Object { -not $_.Preview }).Count | Should -Be 89
        @($script:catalog.Vm | Select-Object -ExpandProperty Id -Unique).Count | Should -Be 99
        @($script:catalog.Vm | Where-Object { $_.Id -notmatch '^Standard_E\d+(?:-\d+)?(?:i)?(?:a|b)?ds_v[567]$' }).Count | Should -Be 0
    }
    It 'matches every published base resource row for <Hardware>' -ForEach @(
        @{Hardware='Edsv7';Rows='2:16:10:4000:115:1:110;4:32:12:8000:230:1:220;8:64:26:16000:460:1:440;16:128:48:32000:940:2:440;20:160:48:40000:1150:2:550;32:256:64:64000:1885:4:440;48:384:64:96000:2830:6:440;64:512:64:128000:3775:4:880;96:768:64:192000:5665:6:880;128:1024:64:204800:7550:4:1760;192:1536:64:307200:11325:6:1760;248:1888:64:396800:13145:5:2816;372:2832:64:500000:16000:6:3520'},
        @{Hardware='Eadsv7';Rows='2:16:10:4000:118:1:110;4:32:12:8000:234:1:220;8:64:26:16000:468:1:440;16:128:48:32000:936:2:440;32:256:64:64000:1872:4:440;48:384:64:96000:2808:6:440;64:512:64:128000:3744:4:880;96:768:64:192000:5663:6:880;128:1024:64:204800:7488:4:1760;160:1280:64:212000:10344:4:2200'},
        @{Hardware='Edsv6';Rows='2:16:8:3750:106:1:110;4:32:12:6400:212:1:220;8:64:24:12800:424:1:440;16:128:48:25600:848:2:440;20:160:48:32000:1060:2:550;32:256:64:51200:1696:4:440;48:384:64:76800:2544:6:440;64:512:64:102400:3392:4:880;96:768:64:153600:5088:6:880;128:1024:64:204800:6782:4:1760;192:1832:64:260000:12000:6:1760'},
        @{Hardware='Eadsv6';Rows='2:16:4:4000:90:1:110;4:32:8:7600:180:1:220;8:64:16:15200:360:1:440;16:128:32:30400:720:2:440;20:160:32:38000:900:2:550;32:256:32:57600:1440:4:440;48:384:32:86400:2160:6:440;64:512:32:115200:2880:4:880;96:672:32:175000:4320:6:880'},
        @{Hardware='Ebdsv6';Rows='2:16:8:8800:253:1:110;4:32:12:17600:506:1:220;8:64:24:36300:1023:1:440;16:128:48:72600:1980:2:440;32:256:64:143000:4070:4:440;48:384:64:209000:6160:6:440;64:512:64:242000:6600:4:880;96:768:64:286000:8250:6:880;128:1024:64:330000:10000:4:1760;192:1832:64:400000:14000:6:1760'},
        @{Hardware='Ebdsv5';Rows='2:16:4:8000:230:1:75;4:32:8:16000:460:1:150;8:64:16:33000:930:1:300;16:128:32:66000:1800:1:600;32:256:32:130000:3700:1:1200;48:384:32:190000:5600:1:1800;64:512:32:220000:6000:1:2400;96:672:32:260000:7500:1:3600;112:672:64:260000:8000:1:3800'}
    ) {
        $actual = @($script:catalog.Vm | Where-Object { $_.Hardware -eq $Hardware -and $_.Id -eq $_.BaseVmSize })
        $expected = @($Rows.Split(';'))
        $actual.Count | Should -Be $expected.Count
        foreach ($row in $expected) {
            $numbers = @($row.Split(':') | ForEach-Object { [int]$_ })
            $match = @($actual | Where-Object VCores -EQ $numbers[0])
            $match.Count | Should -Be 1
            $item = $match[0]
            $fields = @('VCores','MemoryGB','MaxDataDisks','MaxIops','MaxThroughputMBps','LocalTempDisks','LocalTempDiskGB')
            for ($i=0; $i -lt $fields.Count; $i++) { $item.($fields[$i]) | Should -Be $numbers[$i] }
            $item.LocalTempGB | Should -Be ($numbers[5]*$numbers[6])
            $section = $Hardware.ToLowerInvariant()
            if ($Hardware -eq 'Ebdsv5') { $section = 'ebdsv5-ebsv5' }
            $item.SourceUrl | Should -BeLike "*$section-series"
            $item.RemoteDiskController | Should -Be NVMe
            if ($Hardware -eq 'Ebdsv5') { $item.LocalTempDiskType | Should -Be SSD }
            else { $item.LocalTempDiskType | Should -Be NVMe }
            $item.SqlMajorVersions -join ',' | Should -Be '13,14,15,16,17'
            $item.Notes -join ' ' | Should -Match 'Generation 2'
        }
    }
    It 'includes exactly the published constrained mappings for <Hardware>, not a theoretical cross-product' -ForEach @(
        @{Hardware='Edsv6';Suffix='ds_v6';Rows='4:2;8:2,4;16:4,8;32:8,16;64:16,32;96:24,48;128:32,64'},
        @{Hardware='Eadsv6';Suffix='ads_v6';Rows='4:2;8:2,4;16:4,8;32:8,16;64:16,32;96:24,48'},
        @{Hardware='Eadsv7';Suffix='ads_v7';Rows='4:2;8:2,4;16:4,8;32:8,16;64:16,32;96:24,48;128:32,64'}
    ) {
        $expected = @(
            foreach ($pair in $Rows.Split(';')) {
                $base,$active = $pair.Split(':')
                foreach ($cores in $active.Split(',')) { "Standard_E$base-$cores$Suffix" }
            }
        )
        $actual = @($script:catalog.Vm | Where-Object { $_.Hardware -eq $Hardware -and $_.Id -ne $_.BaseVmSize })
        ($actual.Id | Sort-Object) -join ',' | Should -Be (($expected | Sort-Object) -join ',')
        foreach ($item in $actual) {
            $parent = $script:catalog.Vm | Where-Object Id -EQ $item.BaseVmSize
            foreach ($field in @('MemoryGB','MaxDataDisks','MaxIops','MaxThroughputMBps','LocalTempGB','LocalTempDisks','LocalTempDiskGB','LocalTempDiskType','RemoteDiskController','BaseVCores')) {
                $item.$field | Should -Be $parent.$field
            }
            $item.Id | Should -Match ('-' + $item.VCores + '[a-z]+_v')
            $item.VCores | Should -BeLessThan $parent.VCores
        }
        @($script:catalog.Vm | Where-Object { $_.Hardware -in @('Edsv7','Ebdsv6','Ebdsv5') -and $_.Id -ne $_.BaseVmSize }).Count | Should -Be 0
    }
    It 'matches all 14 published base Premium SSD capacity and sustained performance tiers' {
        $expected = 'P1:4:120:25;P2:8:120:25;P3:16:120:25;P4:32:120:25;P6:64:240:50;P10:128:500:100;P15:256:1100:125;P20:512:2300:150;P30:1024:5000:200;P40:2048:7500:250;P50:4096:7500:250;P60:8192:16000:500;P70:16384:18000:750;P80:32767:20000:900'
        $script:catalog.Disks.Count | Should -Be 14
        foreach ($row in $expected.Split(';')) {
            $tier,$size,$iops,$mbps = $row.Split(':')
            $disk = $script:catalog.Disks | Where-Object Tier -EQ $tier
            $disk.SizeGB | Should -Be ([int]$size)
            $disk.Iops | Should -Be ([int]$iops)
            $disk.ThroughputMBps | Should -Be ([int]$mbps)
        }
    }
}

Describe 'Complete exact E-series retail mapping' {
    It 'prices Windows and base compute for all 99 SKUs, with active-core SQL licensing and no core multiplier on VM compute' {
        $inputs = @($script:catalog.Vm | ForEach-Object { New-VmQuoteInput $_ })
        $quotes = @(Get-SsaPriceEstimate $inputs -Region eastus -PriceData $script:vmPrices -SqlHybridBenefit -WindowsHybridBenefit)
        $quotes.Count | Should -Be 198
        @($quotes | Where-Object Status -NE Complete).Count | Should -Be 0
        foreach ($candidate in $script:catalog.Vm) {
            $pair = @($quotes | Where-Object CatalogId -EQ $candidate.Id)
            foreach ($quote in $pair) {
                $quote.MappingVersion | Should -Be '2026.10.27.3'
                $compute = $quote.Components | Where-Object Component -In @('Compute','ComputeAndWindows')
                $compute.Quantity | Should -Be 730
                $compute.ArmSkuName | Should -Be $candidate.Id
                $compute.SkuName | Should -Be $candidate.ComputeSku
                $compute.MeterName | Should -Be $candidate.ComputeMeter
                if ($quote.Scenario -eq 'Payg') {
                    $compute.ProductName | Should -Be $candidate.WindowsProduct
                    $license = $quote.Components | Where-Object Component -EQ SqlLicense
                    $license.Quantity | Should -Be (730*[Math]::Max(4,$candidate.VCores))
                    $license.Rate | Should -Be 0.375
                    $license.MeterId | Should -Be '2154b23d-7112-5923-ab92-92c013cd0b7f'
                } else {
                    $compute.ProductName | Should -Be $candidate.ComputeProduct
                    @($quote.Components | Where-Object Component -EQ SqlLicense).Count | Should -Be 0
                }
            }
        }
    }
    It 'keeps Ebdsv5 ARM SKU names distinct from display-formatted meter names and rejects missing exact identities' {
        $candidate = $script:catalog.Vm | Where-Object Id -EQ Standard_E112ibds_v5
        $candidate.ComputeSku | Should -Be Standard_E112ibds_v5
        $candidate.ComputeMeter | Should -Be 'E112ibds v5'
        $prices = @($script:vmPrices | Where-Object { $_.armSkuName -ne $candidate.Id -or $_.skuName -ne $candidate.ComputeSku })
        $quote = @(Get-SsaPriceEstimate (New-VmQuoteInput $candidate) -Region eastus -PriceData $prices)[0]
        $quote.Status | Should -Be Partial
        $quote.TotalMonthly | Should -BeNullOrEmpty
        $quote.Errors -join ' ' | Should -Match 'Missing exact retail meter'
    }
    It 'keeps Ebdsv5 SQL and Windows benefits independent: SQL <SqlAhb>, Windows <WindowsAhb>' -ForEach @(
        @{SqlAhb=$true;WindowsAhb=$false;Compute='ComputeAndWindows';SqlCharges=0},
        @{SqlAhb=$false;WindowsAhb=$true;Compute='Compute';SqlCharges=1}
    ) {
        $candidate = $script:catalog.Vm | Where-Object Id -EQ Standard_E4bds_v5
        $quote = @(Get-SsaPriceEstimate (New-VmQuoteInput $candidate) -Region eastus -PriceData $script:vmPrices -SqlHybridBenefit:$SqlAhb -WindowsHybridBenefit:$WindowsAhb | Where-Object Scenario -EQ Ahb)[0]
        $quote.Status | Should -Be Complete
        @($quote.Components | Where-Object Component -EQ $Compute).Count | Should -Be 1
        @($quote.Components | Where-Object Component -EQ SqlLicense).Count | Should -Be $SqlCharges
    }
    It 'bills constrained VM compute at its published unchanged parent rate, but only active cores for SQL' {
        $inputs = @($script:catalog.Vm | Where-Object Id -In @('Standard_E32ads_v7','Standard_E32-8ads_v7') | ForEach-Object { New-VmQuoteInput $_ })
        $quotes = @(Get-SsaPriceEstimate $inputs -Region eastus -PriceData $script:vmPrices | Where-Object Scenario -EQ Payg)
        $base = $quotes | Where-Object CatalogId -EQ Standard_E32ads_v7
        $active = $quotes | Where-Object CatalogId -EQ Standard_E32-8ads_v7
        ($active.Components | Where-Object Component -EQ ComputeAndWindows).MonthlyCost | Should -Be ($base.Components | Where-Object Component -EQ ComputeAndWindows).MonthlyCost
        ($active.Components | Where-Object Component -EQ SqlLicense).MonthlyCost | Should -Be (($base.Components | Where-Object Component -EQ SqlLicense).MonthlyCost/4)
    }
    It 'does not substitute a parent, old-generation or different-family meter when an exact VM identity is missing' {
        $candidate = $script:catalog.Vm | Where-Object Id -EQ Standard_E32-8ads_v7
        $prices = @($script:vmPrices | Where-Object armSkuName -NE $candidate.Id)
        $quote = @(Get-SsaPriceEstimate (New-VmQuoteInput $candidate) -Region eastus -PriceData $prices)[0]
        $quote.Status | Should -Be Partial
        $quote.TotalMonthly | Should -BeNullOrEmpty
        $quote.Errors -join ' ' | Should -Match 'Missing exact retail meter'
    }
    It 'prices every Premium SSD tier without fabricating a missing rate' {
        $candidate = $script:catalog.Vm | Where-Object Id -EQ Standard_E2ds_v7
        $inputs = @(
            foreach ($disk in $script:catalog.Disks) {
                $input = New-VmQuoteInput $candidate
                $input.RecommendationId = $disk.Id
                $input.DiskLayout[1].DiskId = $disk.Id
                $input
            }
        )
        $quotes = @(Get-SsaPriceEstimate $inputs -Region eastus -PriceData $script:vmPrices)
        @($quotes | Where-Object Scenario -EQ Payg | Where-Object Status -NE Complete).Count | Should -Be 0
        foreach ($quote in @($quotes | Where-Object Scenario -EQ Payg)) {
            ($quote.Components | Where-Object Component -EQ DataDisk).Quantity | Should -Be 1
        }
    }
}

Describe 'E-series sizing policy integration' {
    BeforeEach {
        $script:collection = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $null = Save-ObservedBundle $script:collection
    }
    It 'prefers newer E-series when active cores and memory tie and marks the scoped coverage' {
        $vm = @(Get-SsaSkuRecommendation $script:collection | Where-Object Target -EQ SqlVm)[0]
        $vm.CatalogId | Should -Be Standard_E2ads_v7
        $vm.VmGeneration | Should -Be 7
        $vm.VmPreview | Should -BeFalse
        $vm.Reason | Should -Match 'Generation 2 NVMe-compatible'
        $vm.Reason | Should -Not -Match 'catalog coverage is incomplete'
    }
    It 'can choose generally available Ebdsv5 for I/O demand and distinguishes local SSD from remote NVMe' {
        Mock Get-SsaDemand -ModuleName SimpleSqlAssessment { param($Metric) if ($Metric -eq 'HostIops') { 6500 } else { 0.1 } }
        $vm = @(Get-SsaSkuRecommendation $script:collection -HeadroomPercent 0 | Where-Object Target -EQ SqlVm)[0]
        $vm.CatalogId | Should -Be Standard_E2bds_v5
        $vm.VmGeneration | Should -Be 5
        $vm.VmPreview | Should -BeFalse
        $vm.LocalTempDiskType | Should -Be SSD
        $vm.RemoteDiskController | Should -Be NVMe
        $vm.LocalTempGB | Should -Be 75
        $vm.Reason | Should -Match 'NVMe remote disk controller'
        $vm.Reason | Should -Match 'not the lower SCSI profile'
        $vm.Reason | Should -Not -Match 'Initialize/format raw'
    }
    It 'keeps the selected Ebdsv5 at its exact tempdb boundary: <TempdbGB> GiB uses <Placement>' -ForEach @(
        @{TempdbGB=75;Placement='LocalTemporary'},@{TempdbGB=76;Placement='ManagedDisk'}
    ) {
        $null = Save-ObservedBundle $script:collection -TempdbSizeMB ($TempdbGB*1024)
        Mock Get-SsaDemand -ModuleName SimpleSqlAssessment { param($Metric) if ($Metric -eq 'HostIops') { 6500 } else { 0.1 } }
        $vm = @(Get-SsaSkuRecommendation $script:collection -HeadroomPercent 0 -StorageGrowthPercent 0 | Where-Object Target -EQ SqlVm)[0]
        $vm.CatalogId | Should -Be Standard_E2bds_v5
        $vm.TempdbPlacement | Should -Be $Placement
        if ($Placement -eq 'ManagedDisk') { @($vm.DiskLayout | Where-Object Role -EQ Tempdb).Count | Should -BeGreaterThan 0 }
        else { @($vm.DiskLayout | Where-Object Role -EQ Tempdb).Count | Should -Be 0 }
    }
    It 'uses constrained active cores for memory-heavy SQL instead of unnecessary SQL license cores' {
        Mock Get-SsaDemand -ModuleName SimpleSqlAssessment { param($Metric) if ($Metric -eq 'MemoryGB') { 240 } else { 0.1 } }
        $vm = @(Get-SsaSkuRecommendation $script:collection -HeadroomPercent 0 | Where-Object Target -EQ SqlVm)[0]
        $vm.CatalogId | Should -Be Standard_E32-8ads_v7
        $vm.VCores | Should -Be 8
        $vm.BaseVCores | Should -Be 32
        $vm.MemoryGB | Should -Be 256
        $vm.LocalTempGB | Should -Be 1760
    }
    It 'can select the largest Intel size and explicitly reports a genuine scoped CPU no-fit beyond it' {
        Mock Get-SsaDemand -ModuleName SimpleSqlAssessment { param($Metric) if ($Metric -eq 'UsedCores') { 372 } else { 0.1 } }
        $vm = @(Get-SsaSkuRecommendation $script:collection -HeadroomPercent 0 -TargetSqlEdition Enterprise | Where-Object Target -EQ SqlVm)[0]
        $vm.CatalogId | Should -Be Standard_E372ids_v7
        Mock Get-SsaDemand -ModuleName SimpleSqlAssessment { param($Metric) if ($Metric -eq 'UsedCores') { 373 } else { 0.1 } }
        $vm = @(Get-SsaSkuRecommendation $script:collection -HeadroomPercent 0 -TargetSqlEdition Enterprise | Where-Object Target -EQ SqlVm)[0]
        $vm.Status | Should -Be Unavailable
        $vm.Reason | Should -Match 'not an Azure-wide no-fit'
    }
    It 'does not count local SQL tempdb file I/O against the VM remote cap' {
        Mock Get-SsaDemand -ModuleName SimpleSqlAssessment {
            param($Metric,$Database,[switch]$ExcludeTempdb)
            if ($Metric -eq 'Iops' -and -not $ExcludeTempdb) { return 100000 }
            if ($Metric -eq 'ThroughputMBps' -and -not $ExcludeTempdb) { return 1000 }
            return 0.1
        }
        $vm = @(Get-SsaSkuRecommendation $script:collection -HeadroomPercent 0 | Where-Object Target -EQ SqlVm)[0]
        $vm.VCores | Should -Be 2
        $vm.TempdbPlacement | Should -Be LocalTemporary
        ($vm.Constraints | Where-Object Resource -EQ 'I/O operations').Required | Should -Be 0.1
        $vm.Reason | Should -Match 'steady-state local writes'
    }
    It 'retains a conservative host I/O bound rather than silently dropping unattributed OS and non-SQL I/O' {
        Mock Get-SsaDemand -ModuleName SimpleSqlAssessment { param($Metric) if ($Metric -eq 'HostIops') { 9000 } else { 0.1 } }
        $vm = @(Get-SsaSkuRecommendation $script:collection -HeadroomPercent 0 | Where-Object Target -EQ SqlVm)[0]
        ($vm.Constraints | Where-Object Resource -EQ 'I/O operations').Required | Should -Be 9000
        ($vm.Constraints | Where-Object Resource -EQ 'I/O operations').Limit | Should -BeGreaterOrEqual 9000
    }
    It 'excludes Ebdsv6 Preview by default and admits it only with explicit opt-in' {
        Mock Get-SsaDemand -ModuleName SimpleSqlAssessment { param($Metric) if ($Metric -eq 'HostIops') { 65000 } else { 0.1 } }
        $default = @(Get-SsaSkuRecommendation $script:collection -HeadroomPercent 0 | Where-Object Target -EQ SqlVm)[0]
        $default.Hardware | Should -Not -Be Ebdsv6
        $preview = @(Get-SsaSkuRecommendation $script:collection -HeadroomPercent 0 -IncludePreviewVm | Where-Object Target -EQ SqlVm)[0]
        $preview.Hardware | Should -Be Ebdsv6
        $preview.VmPreview | Should -BeTrue
        $preview.Reason | Should -Match 'PREVIEW'
        $default.CatalogId | Should -Be Standard_E16bds_v5
        $preview.CatalogId | Should -Be Standard_E16bds_v6
        $preview.VCores | Should -Be $default.VCores
        $preview.MemoryGB | Should -Be $default.MemoryGB
    }
    It 'uses all local devices for tempdb instead of incorrectly checking one NVMe device' {
        $null = Save-ObservedBundle $script:collection -TempdbSizeMB (1000*1024)
        Mock Get-SsaDemand -ModuleName SimpleSqlAssessment { param($Metric) if ($Metric -eq 'MemoryGB') { 240 } else { 0.1 } }
        $vm = @(Get-SsaSkuRecommendation $script:collection -HeadroomPercent 0 | Where-Object Target -EQ SqlVm)[0]
        $vm.CatalogId | Should -Be Standard_E32-8ads_v7
        $vm.TempdbGB | Should -Be 1200
        $vm.LocalTempDisks | Should -Be 4
        $vm.LocalTempDiskGB | Should -Be 440
        $vm.LocalTempGB | Should -Be 1760
        $vm.TempdbPlacement | Should -Be LocalTemporary
    }
}
