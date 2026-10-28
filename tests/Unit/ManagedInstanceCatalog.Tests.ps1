BeforeAll {
    $root = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
    Import-Module (Join-Path $root 'src\SimpleSqlAssessment\SimpleSqlAssessment.psd1') -Force
    . (Join-Path (Split-Path $PSScriptRoot -Parent) 'TestHelpers.ps1')
    $script:module = Get-Module SimpleSqlAssessment
    $script:catalog = & $script:module { Get-SsaCatalog }
}

Describe 'Complete standalone Managed Instance catalog' {
    It 'contains exactly the complete 104 base configurations and 66 documented flexible-memory alternatives' {
        $items = @($script:catalog.ManagedInstance)
        $items.Count | Should -Be 170
        @($items | Where-Object AdditionalMemoryGB -EQ 0).Count | Should -Be 104
        @($items | Where-Object AdditionalMemoryGB -GT 0).Count | Should -Be 66
        @($items.Id | Select-Object -Unique).Count | Should -Be 170
        @($items | Where-Object { $_.VCores -eq 2 -or $_.Id -match 'Pool|DC|Gen4' }).Count | Should -Be 0
    }
    It 'contains every supported base core size for <Tier> <Hardware>' -ForEach @(
        @{Tier='GeneralPurpose';Hardware='Gen5';Cores=@(4,8,16,24,32,40,64,80)},
        @{Tier='GeneralPurpose';Hardware='Premium-series';Cores=@(4,8,16,24,32,40,64,80)},
        @{Tier='GeneralPurpose';Hardware='Premium-series-memory-optimized';Cores=@(4,8,16,24,32,40,64,80)},
        @{Tier='NextGenGeneralPurpose';Hardware='Gen5';Cores=@(4,8,16,24,32,40,64,80)},
        @{Tier='NextGenGeneralPurpose';Hardware='Premium-series';Cores=@(4,6,8,10,12,16,20,24,32,40,48,56,64,80,96,128)},
        @{Tier='NextGenGeneralPurpose';Hardware='Premium-series-memory-optimized';Cores=@(4,6,8,10,12,16,20,24,32,40,48,56,64,80,96,128)},
        @{Tier='BusinessCritical';Hardware='Gen5';Cores=@(4,8,16,24,32,40,64,80)},
        @{Tier='BusinessCritical';Hardware='Premium-series';Cores=@(4,6,8,10,12,16,20,24,32,40,48,56,64,80,96,128)},
        @{Tier='BusinessCritical';Hardware='Premium-series-memory-optimized';Cores=@(4,6,8,10,12,16,20,24,32,40,48,56,64,80,96,128)}
    ) {
        $items = @($script:catalog.ManagedInstance | Where-Object { $_.ServiceTier -eq $Tier -and $_.Hardware -eq $Hardware -and $_.AdditionalMemoryGB -eq 0 } | Sort-Object VCores)
        ($items.VCores -join ',') | Should -Be ($Cores -join ',')
        foreach ($item in $items) {
            $item.Id | Should -Be ('MI_'+$Tier+'_'+$Hardware+'_'+$item.VCores)
            $item.ComputeProduct | Should -Not -BeNullOrEmpty
            $item.ComputeArmSku | Should -Not -BeNullOrEmpty
            $item.SourceUrl | Should -Match '#number-of-vcores'
        }
    }
    It 'preserves documented memory ratios and caps without integer rounding' {
        ($script:catalog.ManagedInstance | Where-Object Id -EQ MI_GeneralPurpose_Gen5_24).MemoryGB | Should -Be 122.4
        ($script:catalog.ManagedInstance | Where-Object Id -EQ MI_GeneralPurpose_Gen5_80).MemoryGB | Should -Be 408
        ($script:catalog.ManagedInstance | Where-Object Id -EQ MI_BusinessCritical_Premium-series_96).MemoryGB | Should -Be 560
        ($script:catalog.ManagedInstance | Where-Object Id -EQ MI_BusinessCritical_Premium-series_128).MemoryGB | Should -Be 560
        ($script:catalog.ManagedInstance | Where-Object Id -EQ MI_NextGenGeneralPurpose_Premium-series-memory-optimized_56).MemoryGB | Should -Be 761.6
        ($script:catalog.ManagedInstance | Where-Object Id -EQ MI_NextGenGeneralPurpose_Premium-series-memory-optimized_128).MemoryGB | Should -Be 870.4
    }
    It 'contains exactly every published API memory value, not arbitrary ratio extrapolations' {
        $expected = @{
            4=@(28,32,40,48);6=@(42,48,60,72);8=@(56,64,80,96);10=@(70,80,100,120)
            12=@(84,96,120,144);16=@(112,128,160,192);20=@(140,160,200,240);24=@(168,192,240,288)
            32=@(224,256,320,384);40=@(280,320,400,480);48=@(336,384,480);56=@(392,448)
            64=@(448);80=@(560);96=@(560);128=@(560)
        }
        foreach ($tier in @('NextGenGeneralPurpose','BusinessCritical')) {
            foreach ($cores in $expected.Keys) {
                $items = @($script:catalog.ManagedInstance | Where-Object { $_.ServiceTier -eq $tier -and $_.Hardware -eq 'Premium-series' -and $_.VCores -eq $cores } | Sort-Object MemoryGB)
                ($items.MemoryGB -join ',') | Should -Be ($expected[$cores] -join ',')
            }
        }
        @($script:catalog.ManagedInstance | Where-Object { $_.AdditionalMemoryGB -gt 0 -and ($_.Hardware -ne 'Premium-series' -or $_.ServiceTier -eq 'GeneralPurpose') }).Count | Should -Be 0
    }
    It 'preserves core-dependent storage steps and both published regional storage ceilings' {
        ($script:catalog.ManagedInstance | Where-Object Id -EQ MI_BusinessCritical_Gen5_24).MaxDataGB | Should -Be 2048
        ($script:catalog.ManagedInstance | Where-Object Id -EQ MI_BusinessCritical_Premium-series_6).MaxDataGB | Should -Be 1024
        ($script:catalog.ManagedInstance | Where-Object Id -EQ MI_BusinessCritical_Premium-series_20).MaxDataGB | Should -Be 4096
        ($script:catalog.ManagedInstance | Where-Object Id -EQ MI_BusinessCritical_Premium-series-memory-optimized_48).MaxDataGB | Should -Be 12288
        ($script:catalog.ManagedInstance | Where-Object Id -EQ MI_BusinessCritical_Premium-series-memory-optimized_32).RegionalMaxDataGB | Should -Be 8192
        ($script:catalog.ManagedInstance | Where-Object Id -EQ MI_BusinessCritical_Premium-series_64).RegionalMaxDataGB | Should -Be 16384
        ($script:catalog.ManagedInstance | Where-Object Id -EQ MI_NextGenGeneralPurpose_Premium-series_128).MaxDataGB | Should -Be 32768
    }
    It 'uses the documented IOPS and throughput caps, including high-core saturation' {
        ($script:catalog.ManagedInstance | Where-Object Id -EQ MI_NextGenGeneralPurpose_Premium-series_6).MaxIops | Should -Be 9600
        ($script:catalog.ManagedInstance | Where-Object Id -EQ MI_NextGenGeneralPurpose_Premium-series_10).MaxThroughputMBps | Should -Be 367
        ($script:catalog.ManagedInstance | Where-Object Id -EQ MI_NextGenGeneralPurpose_Premium-series_48).MaxThroughputMBps | Should -Be 1152
        ($script:catalog.ManagedInstance | Where-Object Id -EQ MI_NextGenGeneralPurpose_Premium-series_128).MaxIops | Should -Be 80000
        ($script:catalog.ManagedInstance | Where-Object Id -EQ MI_NextGenGeneralPurpose_Premium-series_128).MaxThroughputMBps | Should -Be 1200
        ($script:catalog.ManagedInstance | Where-Object Id -EQ MI_BusinessCritical_Premium-series_96).MaxIops | Should -Be 320000
        ($script:catalog.ManagedInstance | Where-Object Id -EQ MI_BusinessCritical_Premium-series_128).ThroughputUnbounded | Should -BeTrue
    }
}

Describe 'Sizing across all standalone MI configurations' {
    BeforeEach {
        $script:collection = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $null = Save-ObservedBundle $script:collection
    }
    It 'selects the documented <Cores>-core NG/BC size instead of rounding to the old subset' -ForEach @(
        @{Cores=4},@{Cores=6},@{Cores=8},@{Cores=10},@{Cores=12},@{Cores=16},@{Cores=20},@{Cores=24},
        @{Cores=32},@{Cores=40},@{Cores=48},@{Cores=56},@{Cores=64},@{Cores=80},@{Cores=96},@{Cores=128}
    ) {
        Mock Get-SsaDemand -ModuleName SimpleSqlAssessment { $Cores - 0.1 } -ParameterFilter { $Metric -eq 'UsedCores' }
        $items = @(Get-SsaSkuRecommendation -CollectionPath $script:collection -HeadroomPercent 0 -Region eastus |
            Where-Object { $_.Target -eq 'ManagedInstance' -and $_.ServiceTier -in @('NextGenGeneralPurpose','BusinessCritical') })
        $items.Count | Should -Be 2
        foreach ($item in $items) {
            $item.Status | Should -Be Provisional
            $item.VCores | Should -Be $Cores
        }
    }
    It 'selects exact flexible memory instead of unnecessarily increasing the core count' {
        Mock Get-SsaDemand -ModuleName SimpleSqlAssessment { 34 } -ParameterFilter { $Metric -eq 'MemoryGB' }
        $items = @(Get-SsaSkuRecommendation -CollectionPath $script:collection -HeadroomPercent 0 -Region eastus |
            Where-Object { $_.Target -eq 'ManagedInstance' -and $_.ServiceTier -in @('NextGenGeneralPurpose','BusinessCritical') })
        $items.Count | Should -Be 2
        foreach ($item in $items) {
            $item.Hardware | Should -Be Premium-series
            $item.VCores | Should -Be 4
            $item.MemoryGB | Should -Be 40
            $item.AdditionalMemoryGB | Should -Be 12
        }
    }
    It 'provisions additional next-gen IOPS rather than ignoring I/O or unnecessarily growing storage' {
        Mock Get-SsaDemand -ModuleName SimpleSqlAssessment { 10000 } -ParameterFilter { $Metric -eq 'Iops' }
        $ng = Get-SsaSkuRecommendation -CollectionPath $script:collection -HeadroomPercent 0 -Region eastus |
            Where-Object { $_.Target -eq 'ManagedInstance' -and $_.ServiceTier -eq 'NextGenGeneralPurpose' }
        $ng.VCores | Should -Be 8
        $ng.ReservedStorageGB | Should -Be 32
        $ng.IncludedIops | Should -Be 300
        $ng.ProvisionedIops | Should -Be 10000
        $ng.AdditionalIops | Should -Be 9700
        ($ng.Constraints | Where-Object Resource -EQ 'I/O operations').Limit | Should -Be 10000
    }
    It 'also provisions IOPS for required throughput, respecting the guaranteed throughput floor' {
        $allocation = & $script:module {
            $candidate = (Get-SsaCatalog).ManagedInstance | Where-Object Id -EQ MI_NextGenGeneralPurpose_Gen5_4
            Get-SsaManagedInstanceIoAllocation $candidate 32 100 120
        }
        $allocation.ProvisionedIops | Should -Be 3600
        $allocation.AdditionalIops | Should -Be 3300
        $allocation.ThroughputMBps | Should -Be 120
        $floor = & $script:module {
            $candidate = (Get-SsaCatalog).ManagedInstance | Where-Object Id -EQ MI_NextGenGeneralPurpose_Gen5_4
            Get-SsaManagedInstanceIoAllocation $candidate 32 100 75
        }
        $floor.ProvisionedIops | Should -Be 300
        $floor.ThroughputMBps | Should -Be 75
    }
    It 'does not provision remote IOPS for local GP/next-gen tempdb activity' {
        Mock Get-SsaDemand -ModuleName SimpleSqlAssessment {
            param($Metric, [switch]$ExcludeTempdb)
            if ($Metric -eq 'Iops') {
                if ($ExcludeTempdb) { return 10 }
                return 500000
            }
            return 0.1
        }
        $mi = @(Get-SsaSkuRecommendation -CollectionPath $script:collection -HeadroomPercent 0 -Region eastus | Where-Object Target -EQ ManagedInstance)
        $ng = $mi | Where-Object ServiceTier -EQ NextGenGeneralPurpose
        $ng.VCores | Should -Be 4
        $ng.ProvisionedIops | Should -Be 300
        $ng.AdditionalIops | Should -Be 0
        ($ng.Constraints | Where-Object Resource -EQ 'I/O operations').Required | Should -Be 10
        @($mi | Where-Object ServiceTier -EQ BusinessCritical).Count | Should -Be 0
    }
    It 'checks observed file counts rather than recommending classic GP beyond 280 database files' {
        $analysis = & $script:module { param($path) Get-SsaPerformanceAnalysis $path (Read-SsaBundle $path) } $script:collection
        $analysis.FileInventory = @(1..281 | ForEach-Object { [pscustomobject]@{DatabaseId=5;Database='App';FileId=$_;Type='ROWS';SizeGB=1} })
        Mock Get-SsaPerformanceAnalysis -ModuleName SimpleSqlAssessment { $analysis }
        $mi = @(Get-SsaSkuRecommendation -CollectionPath $script:collection -Region eastus | Where-Object Target -EQ ManagedInstance)
        @($mi | Where-Object ServiceTier -EQ GeneralPurpose).Count | Should -Be 0
        @($mi | Where-Object ServiceTier -EQ NextGenGeneralPurpose).Count | Should -Be 1
        @($mi | Where-Object ServiceTier -EQ BusinessCritical).Count | Should -Be 1
    }
    It 'includes the larger regional storage configuration only where the published regional matrix supports it' {
        $bundle = New-TestBundle
        $bundle.Databases[0].DataMB = 14000*1024
        $null = Save-ObservedBundle $script:collection $bundle
        $east = @(Get-SsaSkuRecommendation -CollectionPath $script:collection -StorageGrowthPercent 0 -Region eastus |
            Where-Object { $_.Target -eq 'ManagedInstance' -and $_.ServiceTier -eq 'BusinessCritical' })
        $east.Count | Should -Be 1
        $east[0].CatalogId | Should -Be MI_BusinessCritical_Premium-series_64
        ($east[0].Constraints | Where-Object Resource -EQ 'Reserved storage').Limit | Should -Be 16384
        $west = @(Get-SsaSkuRecommendation -CollectionPath $script:collection -StorageGrowthPercent 0 -Region westus3 |
            Where-Object { $_.Target -eq 'ManagedInstance' -and $_.ServiceTier -eq 'BusinessCritical' })
        $west.Count | Should -Be 0
        $unknown = Get-SsaSkuRecommendation -CollectionPath $script:collection -StorageGrowthPercent 0 |
            Where-Object { $_.Target -eq 'ManagedInstance' -and $_.ServiceTier -eq 'BusinessCritical' }
        $unknown.Reason | Should -Match 'specify -Region'
    }
    It 'does not mistake a source log file above 2 TiB for a valid aggregate MI allocation' {
        $analysis = & $script:module { param($path) Get-SsaPerformanceAnalysis $path (Read-SsaBundle $path) } $script:collection
        $analysis.FileInventory = @([pscustomobject]@{DatabaseId=5;Database='App';FileId=2;Type='LOG';SizeGB=2049})
        Mock Get-SsaPerformanceAnalysis -ModuleName SimpleSqlAssessment { $analysis }
        $mi = @(Get-SsaSkuRecommendation -CollectionPath $script:collection -StorageGrowthPercent 0 | Where-Object Target -EQ ManagedInstance)
        $mi.Count | Should -Be 1
        $mi[0].Status | Should -Be Unavailable
    }
    It 'does not invent a 129-core MI size when the complete matrix has no CPU fit' {
        Mock Get-SsaDemand -ModuleName SimpleSqlAssessment { 129 } -ParameterFilter { $Metric -eq 'UsedCores' }
        $mi = @(Get-SsaSkuRecommendation -CollectionPath $script:collection -HeadroomPercent 0 | Where-Object Target -EQ ManagedInstance)
        $mi.Count | Should -Be 1
        $mi[0].Status | Should -Be Unavailable
    }
}
