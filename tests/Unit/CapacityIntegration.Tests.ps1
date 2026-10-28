BeforeAll {
    $root = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
    Import-Module (Join-Path $root 'src\SimpleSqlAssessment\SimpleSqlAssessment.psd1') -Force
    . (Join-Path (Split-Path $PSScriptRoot -Parent) 'TestHelpers.ps1')
    $script:module = Get-Module SimpleSqlAssessment
    $reference = Get-Content -LiteralPath (Join-Path $root 'src\SimpleSqlAssessment\Catalogs\retail-reference.json') -Raw | ConvertFrom-Json
    $script:prices = @(
        foreach ($item in @($reference.Items | Where-Object serviceName -In @('SQL Database','SQL Managed Instance'))) {
            $row = [ordered]@{}
            foreach ($property in $reference.SharedFields.PSObject.Properties) { $row[$property.Name] = $property.Value }
            foreach ($property in $item.PSObject.Properties) { $row[$property.Name] = $property.Value }
            [pscustomobject]$row
        }
        (Get-Content -LiteralPath (Join-Path $root 'src\SimpleSqlAssessment\Catalogs\vm-retail-reference.json') -Raw | ConvertFrom-Json).Items
    )
}
Describe 'Sizing against the shipped capacity catalogs' {
    BeforeEach {
        $script:collection = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $null = Save-ObservedBundle $script:collection
    }
    It 'produces feasible, explicitly provisional options for all three targets' {
        $items = @(Get-SsaSkuRecommendation -CollectionPath $script:collection -TargetSqlMajorVersion 16)
        foreach ($target in @('SqlDatabase','ManagedInstance','SqlVm')) {
            $options = @($items | Where-Object Target -EQ $target)
            $options.Count | Should -BeGreaterThan 0
            @($options | Where-Object Status -NE Provisional).Count | Should -Be 0
            foreach ($item in $options) {
                foreach ($bound in @($item.Constraints | Where-Object { $null -ne $_.Limit })) { $bound.Required | Should -BeLessOrEqual $bound.Limit }
            }
        }
        $vm = @($items | Where-Object Target -EQ SqlVm)[0]
        $vm.DiskLayout.Count | Should -Be 3
        $vm.TempdbPlacement | Should -Be LocalTemporary
        ($vm.DiskLayout | Where-Object Role -EQ Os).Count | Should -Be 1
    }
    It 'preserves unpublished PaaS bounds as null and explicitly unverified' {
        $items = @(Get-SsaSkuRecommendation -CollectionPath $script:collection)
        foreach ($item in @($items | Where-Object { $_.Target -ne 'SqlVm' })) {
            $bound = $item.Constraints | Where-Object Resource -EQ 'I/O throughput'
            if ($item.Target -eq 'ManagedInstance' -and $item.ServiceTier -eq 'NextGenGeneralPurpose') {
                $bound.Limit | Should -BeGreaterOrEqual 75
            } elseif ($item.Target -eq 'ManagedInstance' -and $item.ServiceTier -eq 'BusinessCritical') {
                $bound.DocumentedUnlimited | Should -BeTrue
            } else {
                $bound.Limit | Should -BeNullOrEmpty
                $item.Reason | Should -BeLike '*Unpublished/unverified*'
            }
        }
    }
    It 'converts observed MiB/s to decimal catalog MB/s at the constraint boundary' {
        $items = @(Get-SsaSkuRecommendation -CollectionPath $script:collection -HeadroomPercent 0)
        $db = @($items | Where-Object Target -EQ SqlDatabase)[0]
        $actual = ($db.Constraints | Where-Object Resource -EQ 'I/O throughput').Required
        [Math]::Abs($actual - (122880.0/1000000)) | Should -BeLessThan 0.000000000001
    }
    It 'rejects the smallest GP configuration when converted log throughput exceeds its published bound' {
        Mock Get-SsaDemand -ModuleName SimpleSqlAssessment { param($Metric) if ($Metric -eq 'LogMBps') { 9.000001 } else { 0.1 } }
        $gp = @(Get-SsaSkuRecommendation -CollectionPath $script:collection -HeadroomPercent 0 | Where-Object { $_.Target -eq 'SqlDatabase' -and $_.ServiceTier -eq 'GeneralPurpose' })[0]
        $gp.Status | Should -Be Provisional
        $gp.VCores | Should -BeGreaterThan 2
    }
    It 'does not publish incomplete VM storage sizing for FILESTREAM evidence' {
        $bundle = New-TestBundle
        Set-TestEvidence $bundle 'FileStream' @([pscustomobject]@{Name='Files'}) 'App'
        $null = Save-TestBundle $script:collection $bundle
        $vm = @(Get-SsaSkuRecommendation -CollectionPath $script:collection | Where-Object Target -EQ SqlVm)[0]
        $vm.Status | Should -Be Unavailable
        $vm.Reason | Should -BeLike '*FILESTREAM*'
    }
    It 'accounts for tempdb capacity and BC shared reserved storage' {
        $null = Save-ObservedBundle -Path $script:collection -TempdbSizeMB (100*1024)
        $items = @(Get-SsaSkuRecommendation -CollectionPath $script:collection)
        foreach ($item in @($items | Where-Object Status -EQ Provisional)) {
            $item.TempdbGB | Should -Be 120
            foreach ($bound in @($item.Constraints | Where-Object { $null -ne $_.Limit })) { $bound.Required | Should -BeLessOrEqual $bound.Limit }
        }
        $bc = @($items | Where-Object { $_.Target -eq 'ManagedInstance' -and $_.ServiceTier -eq 'BusinessCritical' })[0]
        $bc.ReservedStorageGB | Should -BeGreaterOrEqual ($bc.DataGB+$bc.LogGB+$bc.TempdbGB)
    }
    It 'reserves enough SQL Database storage for its proportional log limit' {
        $items = @(Get-SsaSkuRecommendation -CollectionPath $script:collection)
        $gp = @($items | Where-Object { $_.Target -eq 'SqlDatabase' -and $_.ServiceTier -eq 'GeneralPurpose' })[0]
        $gp.ReservedStorageGB | Should -BeGreaterThan $gp.DataGB
        ($gp.Constraints | Where-Object Resource -EQ 'Log storage').Limit | Should -BeGreaterOrEqual $gp.LogGB
    }
    It 'keeps MI GP tempdb log capacity within 120 GiB including growth' {
        $null = Save-ObservedBundle -Path $script:collection -TempdbLogSizeMB (100*1024)
        $mi = @(Get-SsaSkuRecommendation -CollectionPath $script:collection | Where-Object Target -EQ ManagedInstance)
        $gp = @($mi | Where-Object ServiceTier -EQ GeneralPurpose)[0]
        ($gp.Constraints | Where-Object Resource -EQ 'Tempdb log storage').Required | Should -Be 120
        ($gp.Constraints | Where-Object Resource -EQ 'Tempdb log storage').Limit | Should -Be 120
        $null = Save-ObservedBundle -Path $script:collection -TempdbLogSizeMB (101*1024)
        $mi = @(Get-SsaSkuRecommendation -CollectionPath $script:collection | Where-Object Target -EQ ManagedInstance)
        @($mi | Where-Object { $_.ServiceTier -in @('GeneralPurpose','NextGenGeneralPurpose') }).Count | Should -Be 0
        @($mi | Where-Object { $_.ServiceTier -eq 'BusinessCritical' -and $_.Status -eq 'Provisional' }).Count | Should -Be 1
    }
    It 'does not recommend a Standard-edition VM beyond its version-specific SQL CPU limit' {
        Mock Get-SsaDemand -ModuleName SimpleSqlAssessment { param($Metric) if ($Metric -eq 'UsedCores') { 25 } else { 0.1 } }
        $standard = @(Get-SsaSkuRecommendation -CollectionPath $script:collection -TargetSqlMajorVersion 16 -TargetSqlEdition Standard -HeadroomPercent 0 | Where-Object Target -EQ SqlVm)[0]
        $standard.Status | Should -Be Unavailable
        $standard.Reason | Should -BeLike '*Standard edition limit of 24*'
        $enterprise = @(Get-SsaSkuRecommendation -CollectionPath $script:collection -TargetSqlMajorVersion 16 -TargetSqlEdition Enterprise -HeadroomPercent 0 | Where-Object Target -EQ SqlVm)[0]
        $enterprise.Status | Should -Be Provisional
        $standard2025 = @(Get-SsaSkuRecommendation -CollectionPath $script:collection -TargetSqlMajorVersion 17 -TargetSqlEdition Standard -HeadroomPercent 0 | Where-Object Target -EQ SqlVm)[0]
        $standard2025.Status | Should -Be Provisional
        ($standard2025.Constraints | Where-Object Resource -EQ 'SQL edition CPU').Limit | Should -Be 32
    }
    It 'rejects SQL 2025 Standard when CPU demand exceeds 32 virtual cores' {
        Mock Get-SsaDemand -ModuleName SimpleSqlAssessment { param($Metric) if ($Metric -eq 'UsedCores') { 33 } else { 0.1 } }
        $vm = @(Get-SsaSkuRecommendation -CollectionPath $script:collection -TargetSqlMajorVersion 17 -TargetSqlEdition Standard -HeadroomPercent 0 | Where-Object Target -EQ SqlVm)[0]
        $vm.Status | Should -Be Unavailable
        $vm.Reason | Should -BeLike '*Standard edition limit of 32*'
    }
    It 'handles empty database inventories without recommending a zero-workload target' {
        $bundle = New-TestBundle
        $bundle.Databases = @()
        $null = Save-TestBundle $script:collection $bundle
        $items = @(Get-SsaSkuRecommendation -CollectionPath $script:collection)
        @($items | Where-Object Status -NE Unavailable).Count | Should -Be 0
    }
    It 'fits the grown tempdb allocation exactly on local storage without billing a tempdb disk' {
        $null = Save-ObservedBundle -Path $script:collection -TempdbSizeMB (110*1024)
        $vm = @(Get-SsaSkuRecommendation -CollectionPath $script:collection -StorageGrowthPercent 0 | Where-Object Target -EQ SqlVm)[0]
        $vm.CatalogId | Should -Be Standard_E2ads_v7
        $vm.TempdbGB | Should -Be 110
        $vm.TempdbPlacement | Should -Be LocalTemporary
        @($vm.DiskLayout | Where-Object Role -EQ Tempdb).Count | Should -Be 0
        ($vm.Constraints | Where-Object Resource -EQ 'Tempdb storage').Limit | Should -Be 110
        ($vm.Constraints | Where-Object Resource -EQ 'Attached data disks').Required | Should -Be 2
        $quotes = @(Get-SsaPriceEstimate $vm -Region eastus -PriceData $script:prices -SqlHybridBenefit)
        @($quotes | Where-Object Status -NE Complete).Count | Should -Be 0
        foreach ($quote in $quotes) { @($quote.Components | Where-Object Component -EQ TempdbDisk).Count | Should -Be 0 }
    }
    It 'adds managed disks instead of upsizing solely to get more local tempdb capacity' {
        $baseline = @(Get-SsaSkuRecommendation -CollectionPath $script:collection -StorageGrowthPercent 0 | Where-Object Target -EQ SqlVm)[0]
        $null = Save-ObservedBundle -Path $script:collection -TempdbSizeMB (111*1024)
        $vm = @(Get-SsaSkuRecommendation -CollectionPath $script:collection -StorageGrowthPercent 0 | Where-Object Target -EQ SqlVm)[0]
        $vm.CatalogId | Should -Be $baseline.CatalogId
        $vm.CatalogId | Should -Be Standard_E2ads_v7
        $vm.TempdbGB | Should -Be 111
        $vm.TempdbPlacement | Should -Be ManagedDisk
        $vm.Reason | Should -BeLike '*larger VM is not preferred merely*'
        $disk = @($vm.DiskLayout | Where-Object Role -EQ Tempdb)
        $disk.Count | Should -Be 1
        $disk[0].ProvisionedGB | Should -BeGreaterOrEqual 111
        ($vm.Constraints | Where-Object Resource -EQ 'Tempdb storage').Limit | Should -Be $disk[0].ProvisionedGB
        $baselineQuotes = @(Get-SsaPriceEstimate $baseline -Region eastus -PriceData $script:prices -SqlHybridBenefit)
        $quotes = @(Get-SsaPriceEstimate $vm -Region eastus -PriceData $script:prices -SqlHybridBenefit)
        for ($i = 0; $i -lt $quotes.Count; $i++) {
            $quotes[$i].Status | Should -Be Complete
            $tempdbPrice = @($quotes[$i].Components | Where-Object Component -EQ TempdbDisk)
            $tempdbPrice.Count | Should -Be 1
            $tempdbPrice[0].Quantity | Should -Be $disk[0].Count
            $quotes[$i].TotalMonthly - $baselineQuotes[$i].TotalMonthly | Should -Be $tempdbPrice[0].MonthlyCost
        }
    }
    It 'uses the larger local drive when CPU or memory already requires a larger VM' {
        $null = Save-ObservedBundle -Path $script:collection -TempdbSizeMB (200*1024)
        Mock Get-SsaDemand -ModuleName SimpleSqlAssessment { param($Metric) if ($Metric -eq 'MemoryGB') { 40 } else { 0.1 } }
        $vm = @(Get-SsaSkuRecommendation -CollectionPath $script:collection | Where-Object Target -EQ SqlVm)[0]
        $vm.CatalogId | Should -Be Standard_E8-2ads_v7
        $vm.TempdbGB | Should -Be 240
        $vm.TempdbPlacement | Should -Be LocalTemporary
        @($vm.DiskLayout | Where-Object Role -EQ Tempdb).Count | Should -Be 0
        ($vm.Constraints | Where-Object Resource -EQ 'Tempdb storage').Limit | Should -Be 440
    }
}

Describe 'Local tempdb disk-layout boundaries' {
    It 'tries larger disk tiers before rejecting an otherwise feasible VM attachment count' {
        $layout = & $script:module {
            $candidate = [pscustomobject]@{LocalTempGB=150;MaxDataDisks=8}
            Get-SsaDiskLayout $candidate (Get-SsaCatalog) 800 800 1 100 1 1
        }
        @($layout).Count | Should -Be 3
        ($layout | Where-Object Role -NE Os | Measure-Object Count -Sum).Sum | Should -BeLessOrEqual 8
        foreach ($role in @('Data','Log')) {
            ($layout | Where-Object Role -EQ $role).ProvisionedGB | Should -BeGreaterOrEqual 800
        }
    }
    It 'uses managed tempdb disks for <Name> local capacity' -ForEach @(
        @{Name='unknown';Capacity=$null},@{Name='zero';Capacity=0},@{Name='insufficient';Capacity=149}
    ) {
        $layout = & $script:module {
            param($capacity)
            $candidate = [pscustomobject]@{LocalTempGB=$capacity;MaxDataDisks=8}
            Get-SsaDiskLayout $candidate (Get-SsaCatalog) 100 10 150 100 10 1
        } $Capacity
        @($layout | Where-Object Role -EQ Tempdb).Count | Should -Be 1
    }
    It 'does not count local storage as an attached disk' {
        $layout = & $script:module {
            $candidate = [pscustomobject]@{LocalTempGB=150;MaxDataDisks=2}
            Get-SsaDiskLayout $candidate (Get-SsaCatalog) 100 10 150 100 10 1
        }
        @($layout).Count | Should -Be 3
        @($layout | Where-Object Role -EQ Tempdb).Count | Should -Be 0
    }
    It 'rejects an external fallback that exceeds VM attachment limits' {
        $layout = & $script:module {
            $candidate = [pscustomobject]@{LocalTempGB=149;MaxDataDisks=2}
            Get-SsaDiskLayout $candidate (Get-SsaCatalog) 100 10 150 100 10 1
        }
        $layout | Should -BeNullOrEmpty
    }
}
