BeforeAll {
    $root = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
    Import-Module (Join-Path $root 'src\SimpleSqlAssessment\SimpleSqlAssessment.psd1') -Force
    . (Join-Path (Split-Path $PSScriptRoot -Parent) 'TestHelpers.ps1')
    $script:module = Get-Module SimpleSqlAssessment
    $script:catalog = & $script:module { Get-SsaCatalog }
}

Describe 'Complete provisioned SQL Database hardware sizes' {
    It 'matches the published core and memory rows for <Prefix>' -ForEach @(
        @{
            Prefix='GP_Gen5';Tier='GeneralPurpose';Hardware='Gen5'
            Cores=@(2,4,6,8,10,12,14,16,18,20,24,32,40,80,128)
            Memory=@(10.4,20.8,31.1,41.5,51.9,62.3,72.7,83,93.4,103.8,124.6,166.1,207.6,415.2,625)
        },
        @{
            Prefix='BC_Gen5';Tier='BusinessCritical';Hardware='Gen5'
            Cores=@(2,4,6,8,10,12,14,16,18,20,24,32,40,80,128)
            Memory=@(10.4,20.8,31.1,41.5,51.9,62.3,72.7,83,93.4,103.8,124.6,166.1,207.6,415.2,625)
        },
        @{
            Prefix='HS_Gen5';Tier='Hyperscale';Hardware='Gen5'
            Cores=@(2,4,6,8,10,12,14,16,18,20,24,32,40,80)
            Memory=@(10.4,20.8,31.1,41.5,51.9,62.3,72.7,83,93.4,103.8,124.6,166.1,207.6,415.2)
        },
        @{
            Prefix='HS_PRMS';Tier='Hyperscale';Hardware='Premium-series'
            Cores=@(2,4,6,8,10,12,14,16,18,20,24,32,40,64,80,128,160,192)
            Memory=@(10.4,20.8,31.1,41.5,51.9,62.3,72.7,83,93.4,103.8,124.6,166.1,207.6,332.2,415.2,625,830.4,843.7)
        },
        @{
            Prefix='HS_MOPRMS';Tier='Hyperscale';Hardware='Premium-series-memory-optimized'
            Cores=@(2,4,6,8,10,12,14,16,18,20,24,32,40,64,80)
            Memory=@(20.8,41.5,62.3,83,103.8,124.6,145.3,166.1,186.9,207.6,249.1,332.2,415.2,664.4,830.5)
        }
    ) {
        $items = @($script:catalog.SqlDatabase | Where-Object { $_.ServiceTier -eq $Tier -and $_.Hardware -eq $Hardware } | Sort-Object VCores)
        $items.Count | Should -Be $Cores.Count
        ($items.VCores -join ',') | Should -Be ($Cores -join ',')
        for ($index = 0; $index -lt $Cores.Count; $index++) {
            $items[$index].Id | Should -Be ($Prefix+'_'+$Cores[$index])
            $items[$index].MemoryGB | Should -Be $Memory[$index]
            $items[$index].SourceUrl | Should -Match '#.+provisioned-compute'
            $items[$index].ComputeProduct | Should -Not -BeNullOrEmpty
            $items[$index].ComputeArmSku | Should -Not -BeNullOrEmpty
            $items[$index].ComputeModel | Should -Be Provisioned
        }
    }
    It 'does not add DC-series, retired hardware, serverless, pools, or undocumented core sizes' {
        $items = @($script:catalog.SqlDatabase)
        $items.Count | Should -Be 77
        @($items | Where-Object { $_.Id -match 'DC|Gen4|Fsv2|Serverless|Pool' }).Count | Should -Be 0
        @($items | Where-Object Id -In @('GP_Gen5_64','BC_Gen5_64','HS_Gen5_64','HS_Gen5_128','HS_MOPRMS_128')).Count | Should -Be 0
    }
    It 'preserves tier-specific tempdb limits even where the documented memory is equal' {
        $gp = $script:catalog.SqlDatabase | Where-Object Id -EQ GP_Gen5_14
        $bc = $script:catalog.SqlDatabase | Where-Object Id -EQ BC_Gen5_14
        $gp.MemoryGB | Should -Be 72.7
        $bc.MemoryGB | Should -Be 72.7
        $gp.MaxTempdbGB | Should -Be 384
        $bc.MaxTempdbGB | Should -Be 448
        $gp.MaxIops | Should -Be 4480
        $bc.MaxIops | Should -Be 56000
    }
    It 'uses published high-core ceilings rather than extrapolating per-core limits' {
        ($script:catalog.SqlDatabase | Where-Object Id -EQ GP_Gen5_128).MaxIops | Should -Be 16000
        ($script:catalog.SqlDatabase | Where-Object Id -EQ BC_Gen5_128).MaxIops | Should -Be 327680
        ($script:catalog.SqlDatabase | Where-Object Id -EQ HS_Gen5_80).MaxLocalIops | Should -Be 204800
        $largest = $script:catalog.SqlDatabase | Where-Object Id -EQ HS_PRMS_192
        $largest.MemoryGB | Should -Be 843.7
        $largest.MaxTempdbGB | Should -Be 4096
        $largest.MaxLocalIops | Should -Be 816000
        $largest.MaxLogMBps | Should -Be 157.2864
    }
    It 'keeps Hyperscale local IOPS separate from unknown end-to-end IOPS on every hardware size' {
        foreach ($item in @($script:catalog.SqlDatabase | Where-Object ServiceTier -EQ Hyperscale)) {
            $item.MaxLocalIops | Should -BeGreaterThan 0
            $item.MaxIops | Should -BeNullOrEmpty
            $item.MaxLogGB | Should -BeNullOrEmpty
            $item.MaxThroughputMBps | Should -BeNullOrEmpty
            $item.MaxDataGB | Should -Be 131072
        }
    }
}

Describe 'Sizing with expanded SQL Database sizes' {
    BeforeEach {
        $script:collection = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $null = Save-ObservedBundle $script:collection
    }
    It 'selects the intermediate or large <Cores>-core GP and BC size instead of skipping it' -ForEach @(
        @{Cores=6},@{Cores=10},@{Cores=12},@{Cores=14},@{Cores=18},
        @{Cores=20},@{Cores=24},@{Cores=40},@{Cores=80},@{Cores=128}
    ) {
        Mock Get-SsaDemand -ModuleName SimpleSqlAssessment { $Cores - 0.1 } -ParameterFilter { $Metric -eq 'UsedCores' }
        $items = @(Get-SsaSkuRecommendation -CollectionPath $script:collection -HeadroomPercent 0 |
            Where-Object { $_.Target -eq 'SqlDatabase' -and $_.ServiceTier -in @('GeneralPurpose','BusinessCritical') })
        $items.Count | Should -Be 2
        foreach ($item in $items) {
            $item.Status | Should -Be Provisional
            $item.VCores | Should -Be $Cores
        }
    }
    It 'uses memory-optimized Hyperscale when its separately documented memory avoids more cores' {
        Mock Get-SsaDemand -ModuleName SimpleSqlAssessment { 18 } -ParameterFilter { $Metric -eq 'MemoryGB' }
        $items = @(Get-SsaSkuRecommendation -CollectionPath $script:collection -HeadroomPercent 0 | Where-Object Target -EQ SqlDatabase)
        ($items | Where-Object ServiceTier -EQ GeneralPurpose).CatalogId | Should -Be GP_Gen5_4
        ($items | Where-Object ServiceTier -EQ BusinessCritical).CatalogId | Should -Be BC_Gen5_4
        $hs = $items | Where-Object ServiceTier -EQ Hyperscale
        $hs.CatalogId | Should -Be HS_MOPRMS_2
        $hs.MemoryGB | Should -Be 20.8
    }
    It 'can fit a 190-core workload on the documented 192-core premium Hyperscale size' {
        Mock Get-SsaDemand -ModuleName SimpleSqlAssessment { 190 } -ParameterFilter { $Metric -eq 'UsedCores' }
        $db = @(Get-SsaSkuRecommendation -CollectionPath $script:collection -HeadroomPercent 0 | Where-Object Target -EQ SqlDatabase)
        $db.Count | Should -Be 1
        $db[0].Status | Should -Be Provisional
        $db[0].CatalogId | Should -Be HS_PRMS_192
    }
    It 'keeps sizing unavailable above every documented provisioned core size' {
        Mock Get-SsaDemand -ModuleName SimpleSqlAssessment { 193 } -ParameterFilter { $Metric -eq 'UsedCores' }
        $db = @(Get-SsaSkuRecommendation -CollectionPath $script:collection -HeadroomPercent 0 | Where-Object Target -EQ SqlDatabase)[0]
        $db.Status | Should -Be Unavailable
    }
}
