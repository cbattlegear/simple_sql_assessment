$modulePath = Join-Path $PSScriptRoot '..\..\src\SimpleSqlAssessment\SimpleSqlAssessment.psd1'
Import-Module $modulePath -Force

InModuleScope SimpleSqlAssessment {
    Describe 'Source-backed catalog and exact retail pricing' {
        BeforeAll {
            function Get-ReferencePrices {
                $reference = Read-SsaJson (Join-Path $script:SsaModuleRoot 'Catalogs\retail-reference.json')
                @(
                    foreach ($item in @($reference.Items | Where-Object serviceName -In @('SQL Database','SQL Managed Instance'))) {
                        $row = [ordered]@{}
                        foreach ($property in $reference.SharedFields.PSObject.Properties) { $row[$property.Name] = $property.Value }
                        foreach ($property in $item.PSObject.Properties) { $row[$property.Name] = $property.Value }
                        [pscustomobject]$row
                    }
                    (Read-SsaJson (Join-Path $script:SsaModuleRoot 'Catalogs\vm-retail-reference.json')).Items
                )
            }
            function New-PriceRecommendation {
                param([string]$Id = 'GP_Gen5_2')
                $catalog = Get-SsaCatalog
                $candidate = @(@($catalog.SqlDatabase) + @($catalog.ManagedInstance) + @($catalog.Vm) | Where-Object { $_.Id -eq $Id })[0]
                [pscustomobject]@{
                    RecommendationId = 'fixture-' + $Id; CatalogId = $Id; Target = $candidate.Target
                    Status = 'Recommended'; ServiceTier = $candidate.ServiceTier; Hardware = $candidate.Hardware
                    VCores = $candidate.VCores; MemoryGB = $candidate.MemoryGB; VmSize = $candidate.VmSize
                    DataGB = 100; LogGB = 10; TempdbGB = 20; SqlEdition = 'Standard'; SqlMajorVersion = 16
                    ProvisionedIops = $(if ($candidate.ServiceTier -eq 'NextGenGeneralPurpose') { 384 } else { $null })
                    DiskLayout = @(
                        [pscustomobject]@{ DiskId = 'P10-LRS'; Count = 1; Role = 'OS' },
                        [pscustomobject]@{ DiskId = 'P30-LRS'; Count = 1; Role = 'Data' },
                        [pscustomobject]@{ DiskId = 'P10-LRS'; Count = 1; Role = 'Log' }
                    )
                }
            }
            function New-PriceCache {
                param($Recommendation, [datetimeoffset]$RetrievedAt = [datetimeoffset]::UtcNow, [string]$Region = 'eastus', [string]$Currency = 'USD')
                $catalog = Get-SsaCatalog
                $candidate = @(@($catalog.SqlDatabase) + @($catalog.ManagedInstance) + @($catalog.Vm) | Where-Object { $_.Id -eq $Recommendation.CatalogId })[0]
                $parts = Get-SsaPriceComponent $Recommendation $candidate $catalog eastus Payg $false $false
                $filters = @($parts | Where-Object { $_.Match } | ForEach-Object { Get-SsaComponentFilter $_.Match } | Sort-Object -Unique)
                $envelope = [pscustomobject]@{
                    SchemaVersion = '1.0'; Region = $Region; Currency = $Currency; ApiVersion = $script:SsaRetailApiVersion
                    RetrievedAt = $RetrievedAt.ToString('o'); Filters = $filters; Items = @(Get-ReferencePrices)
                }
                $file = Join-Path $script:PriceTestCache ('eastus-USD-' + $script:SsaRetailApiVersion + '.json')
                Write-SsaRetailCache $file $envelope
                return $file
            }
            $script:PriceTestCache = Join-Path $script:SsaModuleRoot ('Catalogs\.pricing-tests-' + [guid]::NewGuid().ToString('N'))
        }
        BeforeEach {
            $prices = @(Get-ReferencePrices)
            $recommendation = New-PriceRecommendation
            Mock Invoke-RestMethod { throw 'Unit tests must not make HTTP requests.' }
        }
        AfterAll {
            if (Test-Path -LiteralPath $script:PriceTestCache) { Remove-Item -LiteralPath $script:PriceTestCache -Recurse -Force }
        }

        It 'returns a versioned all-target catalog with unique source-backed IDs' {
            $catalog = Get-SsaCatalog
            $catalog.Version | Should -Be '2026.10.27.3'
            $catalog.SqlDatabase.Count | Should -Be 77
            $catalog.ManagedInstance.Count | Should -Be 170
            $catalog.Vm.Count | Should -Be 99
            $all = @($catalog.SqlDatabase) + @($catalog.ManagedInstance) + @($catalog.Vm)
            @($all | Select-Object -ExpandProperty Id -Unique).Count | Should -Be $all.Count
            @($all | Where-Object { -not $_.SourceUrl -or -not $_.SourceRevision }).Count | Should -Be 0
            @($all | Where-Object CatalogVersion -NE $catalog.Version).Count | Should -Be 0
            $catalog.Disks.Count | Should -Be 14
            ($catalog.Disks | Where-Object Tier -EQ P10).SizeGB | Should -Be 128
            ($catalog.Disks | Where-Object Tier -EQ P10).Iops | Should -Be 500
            ($catalog.Disks | Where-Object Tier -EQ P10).ThroughputMBps | Should -Be 100
            $catalog.Vm[0].MaxDataDisks | Should -Be 10
        }
        It 'converts SQL MiB/s to decimal MB/s and preserves unknown throughput' {
            $candidate = (Get-SsaCatalog).SqlDatabase | Where-Object Id -eq GP_Gen5_2
            $candidate.MaxLogMBps | Should -Be 9.437184
            $candidate.MaxThroughputMBps | Should -BeNullOrEmpty
        }
        It 'does not mistake Hyperscale local IOPS for total data IOPS' {
            $candidate = (Get-SsaCatalog).SqlDatabase | Where-Object Id -eq HS_Gen5_2
            $candidate.MaxIops | Should -BeNullOrEmpty
            $candidate.MaxLocalIops | Should -Be 8000
        }
        It 'prices every documented provisioned SQL Database size using the correct hardware meter and core quantity' {
            $catalog = Get-SsaCatalog
            $items = @($catalog.SqlDatabase | ForEach-Object { New-PriceRecommendation $_.Id })
            $quotes = @(Get-SsaPriceEstimate $items -Region eastus -PriceData $prices -SqlHybridBenefit)
            $quotes.Count | Should -Be 154
            $payg = @($quotes | Where-Object Scenario -EQ Payg)
            $payg.Count | Should -Be 77
            @($payg | Where-Object Status -NE Complete).Count | Should -Be 0
            foreach ($candidate in $catalog.SqlDatabase) {
                $quote = $payg | Where-Object CatalogId -EQ $candidate.Id
                $compute = $quote.Components | Where-Object Component -EQ Compute
                $compute.Quantity | Should -Be (730*$candidate.VCores)
                $compute.ArmSkuName | Should -Be $candidate.ComputeArmSku
            }
            foreach ($entry in @(
                @{Id='HS_PRMS_192';Arm='SQLDB_HyperScale_Compute_Premium';Rate=[decimal]'0.18266'},
                @{Id='HS_MOPRMS_80';Arm='SQLDB_HyperScale_Compute_Premium_Memory_Optimized';Rate=[decimal]'0.255724'}
            )) {
                $quote = $payg | Where-Object CatalogId -EQ $entry.Id
                $compute = $quote.Components | Where-Object Component -EQ Compute
                $compute.ArmSkuName | Should -Be $entry.Arm
                $compute.Rate | Should -Be $entry.Rate
                @($quote.Components | Where-Object Component -EQ SqlLicense).Count | Should -Be 0
            }
            @($quotes | Where-Object { $_.Scenario -eq 'Ahb' -and $_.Status -eq 'Complete' }).Count | Should -Be 30
            @($quotes | Where-Object { $_.Scenario -eq 'Ahb' -and $_.Status -eq 'NotEligible' }).Count | Should -Be 47
            Should -Invoke Invoke-RestMethod -Times 0 -Exactly
        }
        It 'never substitutes a Gen5 meter for missing premium hardware prices or mappings' {
            $prices = @($prices | Where-Object { $_.productName -notmatch 'Premium Series.*Compute' })
            $quote = @(Get-SsaPriceEstimate (New-PriceRecommendation HS_PRMS_4) -Region eastus -PriceData $prices)[0]
            $quote.Status | Should -Be Partial
            $quote.TotalMonthly | Should -BeNullOrEmpty
            $quote.Errors -join ' ' | Should -Match 'Premium Series Compute'
            $catalog = Get-SsaCatalog
            $candidate = $catalog.SqlDatabase | Where-Object Id -EQ HS_PRMS_4
            $candidate.ComputeProduct = $null
            $parts = Get-SsaPriceComponent (New-PriceRecommendation HS_PRMS_4) $candidate $catalog eastus Payg $false $false
            $parts[0].Error | Should -Match 'no Gen5 substitute'
        }
        It 'uses next-gen documented database counts and memory-optimized BC storage' {
            $catalog = Get-SsaCatalog
            ($catalog.ManagedInstance | Where-Object Id -eq MI_NextGenGeneralPurpose_Gen5_32).MaxDatabases | Should -Be 500
            ($catalog.ManagedInstance | Where-Object Id -eq MI_BusinessCritical_Premium-series-memory-optimized_64).MaxDataGB | Should -Be 16384
        }
        It 'retains fractional MI memory capacity rather than rounding it to integer GiB' {
            $catalog = Get-SsaCatalog
            ($catalog.ManagedInstance | Where-Object Id -eq MI_GeneralPurpose_Gen5_4).MemoryGB | Should -Be 20.4
            ($catalog.ManagedInstance | Where-Object Id -eq MI_GeneralPurpose_Gen5_16).MemoryGB | Should -Be 81.6
            ($catalog.ManagedInstance | Where-Object Id -eq MI_GeneralPurpose_Gen5_64).MemoryGB | Should -Be 326.4
        }
        It 'converts per-hour and hundred-hour billing quantities correctly' {
            ConvertTo-SsaBillingQuantity 2 Hour '1 Hour' 730 | Should -Be 1460
            ConvertTo-SsaBillingQuantity 2 Hour '100 Hours' 730 | Should -Be 14.6
        }
        It 'does not multiply full-month disk or storage quantities by running hours' {
            ConvertTo-SsaBillingQuantity 2 Month '1/Month' 100 | Should -Be 2
            ConvertTo-SsaBillingQuantity 100 GBMonth '1 GB/Month' 100 | Should -Be 100
            { ConvertTo-SsaBillingQuantity 1 Hour '1M' 730 } | Should -Throw '*Unsupported billing conversion*'
        }
        It 'uses invariant decimal pricing under a non-English current culture' {
            $previous = [Threading.Thread]::CurrentThread.CurrentCulture
            try {
                [Threading.Thread]::CurrentThread.CurrentCulture = [Globalization.CultureInfo]::GetCultureInfo('de-DE')
                $quote = @(Get-SsaPriceEstimate $recommendation -Region eastus -PriceData $prices)[0]
                $quote.Status | Should -Be Complete
                $quote.TotalMonthly | Should -Be ([decimal]'0.152217' * 1460 + [decimal]'0.099966' * 1460 + [decimal]'14.95')
            } finally { [Threading.Thread]::CurrentThread.CurrentCulture = $previous }
        }
        It 'requires the ARM region and rejects filter injection' {
            @((Get-Command Get-SsaPriceEstimate).Parameters.Region.Attributes | Where-Object { $_ -is [System.Management.Automation.ParameterAttribute] -and $_.Mandatory }).Count | Should -BeGreaterThan 0
            { Get-SsaPriceEstimate $recommendation -Region "eastus' or true" -PriceData $prices } | Should -Throw
        }
        It 'prices GP PAYG base compute plus separate license and reserved data with its billable log allowance' {
            $quotes = @(Get-SsaPriceEstimate $recommendation -Region eastus -PriceData $prices -SqlHybridBenefit)
            $quotes.Count | Should -Be 2
            $quotes[0].Status | Should -Be Complete
            $quotes[0].TotalMonthly | Should -Be ([decimal]'0.152217' * 2 * 730 + [decimal]'0.099966' * 2 * 730 + [decimal]'0.115' * 130)
            $quotes[0].Components.Count | Should -Be 3
            ($quotes[0].Components | Where-Object Component -eq Compute).Quantity | Should -Be 1460
            ($quotes[0].Components | Where-Object Component -eq Storage).Quantity | Should -Be 130
            $quotes[1].TotalMonthly | Should -Be ([decimal]'0.152217' * 2 * 730 + [decimal]'0.115' * 130)
            $quotes[0].TotalMonthly - $quotes[1].TotalMonthly | Should -Be ([decimal]'0.099966' * 1460)
            Should -Invoke Invoke-RestMethod -Times 0 -Exactly
        }
        It 'supports pipeline arrays without losing recommendations' {
            $quotes = @(@($recommendation, (New-PriceRecommendation BC_Gen5_4)) | Get-SsaPriceEstimate -Region eastus -PriceData $prices)
            $quotes.Count | Should -Be 4
            @($quotes | Where-Object Status -eq Complete).Count | Should -Be 2
        }
        It 'prices Business Critical and Hyperscale from separate exact products' {
            foreach ($id in @('BC_Gen5_4', 'HS_Gen5_4')) {
                $quote = @(Get-SsaPriceEstimate (New-PriceRecommendation $id) -Region eastus -SqlHybridBenefit -PriceData $prices)[0]
                $quote.Status | Should -Be Complete
                @($quote.Components | Where-Object Component -match 'Disk|Log|Tempdb').Count | Should -Be 0
            }
        }
        It 'charges GP and BC storage above the configured data cap for the automatic 30 percent log allowance' {
            foreach ($id in @('GP_Gen5_2','BC_Gen5_4')) {
                $item = New-PriceRecommendation $id
                $item | Add-Member NoteProperty ReservedStorageGB 400
                $quote = @(Get-SsaPriceEstimate $item -Region eastus -PriceData $prices)[0]
                $quote.Status | Should -Be Complete
                ($quote.Components | Where-Object Component -eq Storage).Quantity | Should -Be 520
            }
        }
        It 'enforces proportional log capacity before pricing an explicit data reservation' {
            $recommendation.LogGB = 50
            $recommendation | Add-Member NoteProperty ReservedStorageGB 100
            $quote = @(Get-SsaPriceEstimate $recommendation -Region eastus -PriceData $prices)[0]
            $quote.Status | Should -Be Partial
            $quote.TotalMonthly | Should -BeNullOrEmpty
            $quote.Errors -join ' ' | Should -Match ReservedStorageGB
        }
        It 'does not require a license meter or offer AHB for a new Hyperscale database' {
            $prices = @($prices | Where-Object { $_.productName -notmatch 'SQL License' })
            $quotes = @(Get-SsaPriceEstimate (New-PriceRecommendation HS_Gen5_4) -Region eastus -SqlHybridBenefit -PriceData $prices)
            $quotes[0].Status | Should -Be Complete
            $quotes[0].Components.Count | Should -Be 2
            ($quotes[0].Components | Where-Object Component -eq Storage).Quantity | Should -Be 100
            $quotes[1].Status | Should -Be NotEligible
            $quotes[1].Benefits.Sql | Should -BeFalse
            $quotes[1].Errors -join ' ' | Should -Match 'new Hyperscale'
        }
        It 'enforces the ten-GiB Hyperscale billing minimum without a GP or BC log surcharge' {
            $item = New-PriceRecommendation HS_Gen5_4
            $item.DataGB = 1
            $quote = @(Get-SsaPriceEstimate $item -Region eastus -PriceData $prices)[0]
            $quote.Status | Should -Be Complete
            ($quote.Components | Where-Object Component -eq Storage).Quantity | Should -Be 10
        }
        It 'prices all three classic MI hardware configurations in both tiers' {
            foreach ($hardware in @('Gen5', 'Premium-series', 'Premium-series-memory-optimized')) {
                foreach ($tier in @('GeneralPurpose', 'BusinessCritical')) {
                    $quote = @(Get-SsaPriceEstimate (New-PriceRecommendation ('MI_' + $tier + '_' + $hardware + '_4')) -Region eastus -SqlHybridBenefit -PriceData $prices)[0]
                    $quote.Status | Should -Be Complete
                    $quantity = 128
                    if ($tier -eq 'BusinessCritical') { $quantity = 160 }
                    ($quote.Components | Where-Object Component -eq Storage).Quantity | Should -Be $quantity
                }
            }
        }
        It 'prices next-gen MI at the verified GP baseline when its provisioned IOPS are included' {
            $quotes = @(Get-SsaPriceEstimate (New-PriceRecommendation MI_NextGenGeneralPurpose_Gen5_4) -Region eastus -PriceData $prices -SqlHybridBenefit)
            @($quotes | Where-Object Status -NE Complete).Count | Should -Be 0
            @($quotes[0].Components | Where-Object Component -EQ AdditionalIops).Count | Should -Be 0
            ($quotes[0].Components | Where-Object Component -EQ Compute).ArmSkuName | Should -Be SQLMI_GP_Compute_Gen5
            $baseline = @(Get-SsaPriceEstimate (New-PriceRecommendation MI_GeneralPurpose_Gen5_4) -Region eastus -PriceData $prices -SqlHybridBenefit)
            $quotes[0].TotalMonthly | Should -Be $baseline[0].TotalMonthly
            $quotes[1].TotalMonthly | Should -Be $baseline[1].TotalMonthly
        }
        It 'prices all 170 MI core and flexible-memory configurations with exact meters' {
            $catalog = Get-SsaCatalog
            $items = @($catalog.ManagedInstance | ForEach-Object { New-PriceRecommendation $_.Id })
            $quotes = @(Get-SsaPriceEstimate $items -Region eastus -PriceData $prices -SqlHybridBenefit)
            $quotes.Count | Should -Be 340
            @($quotes | Where-Object Status -NE Complete).Count | Should -Be 0
            foreach ($candidate in $catalog.ManagedInstance) {
                $quote = $quotes | Where-Object { $_.CatalogId -eq $candidate.Id -and $_.Scenario -eq 'Payg' }
                ($quote.Components | Where-Object Component -EQ Compute).Quantity | Should -Be (730*$candidate.VCores)
                ($quote.Components | Where-Object Component -EQ Compute).ArmSkuName | Should -Be $candidate.ComputeArmSku
                $extra = @($quote.Components | Where-Object Component -EQ AdditionalMemory)
                if ($candidate.AdditionalMemoryGB -gt 0) {
                    $extra.Count | Should -Be 1
                    $extra[0].Quantity | Should -Be (730*$candidate.AdditionalMemoryGB)
                } else { $extra.Count | Should -Be 0 }
            }
            Should -Invoke Invoke-RestMethod -Times 0 -Exactly
        }
        It 'charges only provisioned next-gen IOPS above the storage-included amount, for a full month' {
            $item = New-PriceRecommendation MI_NextGenGeneralPurpose_Gen5_4
            $item | Add-Member NoteProperty ReservedStorageGB 1024
            $item.ProvisionedIops = 6400
            $quotes = @(Get-SsaPriceEstimate $item -Region eastus -PriceData $prices -SqlHybridBenefit -HoursPerMonth 100)
            foreach ($quote in $quotes) {
                $quote.Status | Should -Be Complete
                $extra = $quote.Components | Where-Object Component -EQ AdditionalIops
                $extra.Quantity | Should -Be 3328
                $extra.Unit | Should -Be '1 IOPS/Month'
                $extra.MonthlyCost | Should -Be (3328*[decimal]'0.038')
            }
        }
        It 'never assumes missing next-gen IOPS are included or accepts IOPS beyond its core cap' {
            foreach ($amount in @($null,0,383,6401,500.5)) {
                $item = New-PriceRecommendation MI_NextGenGeneralPurpose_Gen5_4
                $item.ProvisionedIops = $amount
                $quote = @(Get-SsaPriceEstimate $item -Region eastus -PriceData $prices)[0]
                $quote.Status | Should -Be Partial
                $quote.TotalMonthly | Should -BeNullOrEmpty
                $quote.Errors -join ' ' | Should -Match ProvisionedIops
            }
        }
        It 'charges documented extra memory in both scenarios without giving an AHB discount on memory' {
            foreach ($tier in @('NextGenGeneralPurpose','BusinessCritical')) {
                $item = New-PriceRecommendation ('MI_'+$tier+'_Premium-series_4_Memory40')
                $quotes = @(Get-SsaPriceEstimate $item -Region eastus -PriceData $prices -SqlHybridBenefit)
                $extra = $quotes[0].Components | Where-Object Component -EQ AdditionalMemory
                $extra.Quantity | Should -Be 8760
                $extra.Unit | Should -Be '1 GB/Hour'
                $expected = [decimal]'0.010603'
                if ($tier -eq 'BusinessCritical') { $expected = [decimal]'0.021206' }
                $extra.Rate | Should -Be $expected
                ($quotes[1].Components | Where-Object Component -EQ AdditionalMemory).MonthlyCost | Should -Be $extra.MonthlyCost
            }
        }
        It 'leaves quotes incomplete if an extra-resource meter is missing instead of omitting the charge' {
            $prices = @($prices | Where-Object { $_.meterName -notmatch 'Additional Memory|Additional IOPS' })
            $item = New-PriceRecommendation MI_NextGenGeneralPurpose_Premium-series_4_Memory40
            $item.ProvisionedIops = 6400
            $quote = @(Get-SsaPriceEstimate $item -Region eastus -PriceData $prices)[0]
            $quote.Status | Should -Be Partial
            $quote.TotalMonthly | Should -BeNullOrEmpty
            $quote.Errors -join ' ' | Should -Match AdditionalMemory
            $quote.Errors -join ' ' | Should -Match AdditionalIops
        }
        It 'rejects memory that does not match the selected fixed or flexible-memory catalog configuration' {
            $item = New-PriceRecommendation MI_BusinessCritical_Premium-series_4_Memory40
            $item.MemoryGB = 48
            $quote = @(Get-SsaPriceEstimate $item -Region eastus -PriceData $prices)[0]
            $quote.Status | Should -Be Unavailable
            $quote.Errors -join ' ' | Should -Match MemoryGB
        }
        It 'enforces MI regional hardware and storage caps in explicit quotes too' {
            $item = New-PriceRecommendation MI_BusinessCritical_Premium-series_64
            $item | Add-Member NoteProperty ReservedStorageGB 8192
            $supported = @(Get-SsaPriceEstimate $item -Region eastus -PriceData $prices)[0]
            $supported.Status | Should -Be Complete
            $limited = @(Get-SsaPriceEstimate $item -Region westus3 -PriceData $prices)[0]
            $limited.TotalMonthly | Should -BeNullOrEmpty
            $limited.Errors -join ' ' | Should -Match selected-region
            $hardware = @(Get-SsaPriceEstimate (New-PriceRecommendation MI_BusinessCritical_Premium-series-memory-optimized_4) -Region westus3 -PriceData $prices)[0]
            $hardware.Status | Should -Be Unavailable
            $hardware.Errors -join ' ' | Should -Match 'not listed as supported'
        }
        It 'requires an explicit applicable AHB assertion, not source edition inference' {
            $quotes = @(Get-SsaPriceEstimate $recommendation -Region eastus -PriceData $prices)
            $quotes[1].Status | Should -Be NotEligible
            $quotes[1].TotalMonthly | Should -BeNullOrEmpty
            $quotes = @(Get-SsaPriceEstimate $recommendation -Region eastus -WindowsHybridBenefit -PriceData $prices)
            $quotes[1].Status | Should -Be NotEligible
        }
        It 'never falls back to live prices for explicit empty PriceData' {
            $quotes = @(Get-SsaPriceEstimate $recommendation -Region eastus -PriceData @())
            $quotes[0].Status | Should -Be Unavailable
            $quotes[0].TotalMonthly | Should -BeNullOrEmpty
            Should -Invoke Invoke-RestMethod -Times 0 -Exactly
        }
        It 'makes a missing mandatory license Partial rather than zero or Complete' {
            $prices = @($prices | Where-Object { $_.productName -notmatch 'SQL License' })
            $quotes = @(Get-SsaPriceEstimate $recommendation -Region eastus -SqlHybridBenefit -PriceData $prices)
            $quotes[0].Status | Should -Be Partial
            $quotes[0].TotalMonthly | Should -BeNullOrEmpty
            $quotes[0].KnownMonthly | Should -BeGreaterThan 0
            $quotes[1].Status | Should -Be Complete
        }
        It 'rejects ambiguous exact current meters, even when rates are equal' {
            $duplicate = $prices[0] | ConvertTo-Json | ConvertFrom-Json
            $duplicate.meterId = 'another-meter'
            $quote = @(Get-SsaPriceEstimate $recommendation -Region eastus -PriceData @($prices + $duplicate))[0]
            $quote.Status | Should -Be Partial
            $quote.Errors -join ' ' | Should -Match Ambiguous
        }
        It 'retains a legitimate published zero rate distinctly from missing data' {
            $prices[0].retailPrice = 0
            $quote = @(Get-SsaPriceEstimate $recommendation -Region eastus -PriceData $prices)[0]
            $quote.Status | Should -Be Complete
            ($quote.Components | Where-Object Component -eq Compute).PublishedZeroRate | Should -BeTrue
            ($quote.Components | Where-Object Component -eq Compute).MonthlyCost | Should -Be 0
        }
        It 'permits a complete zero total only when every mandatory published rate is zero' {
            foreach ($meter in $prices) { $meter.retailPrice = 0 }
            $quote = @(Get-SsaPriceEstimate $recommendation -Region eastus -PriceData $prices)[0]
            $quote.Status | Should -Be Complete
            $quote.TotalMonthly | Should -Be 0
            @($quote.Components | Where-Object PublishedZeroRate -eq $false).Count | Should -Be 0
        }
        It 'rejects null, negative, NaN and tiered mandatory rates' {
            foreach ($bad in @($null, -1, 'NaN')) {
                $prices = @(Get-ReferencePrices)
                $prices[0].retailPrice = $bad
                $quote = @(Get-SsaPriceEstimate $recommendation -Region eastus -PriceData $prices)[0]
                $quote.Status | Should -Be Partial
                $quote.TotalMonthly | Should -BeNullOrEmpty
            }
            $prices = @(Get-ReferencePrices)
            $prices[0].tierMinimumUnits = 100
            @(Get-SsaPriceEstimate $recommendation -Region eastus -PriceData $prices)[0].Status | Should -Be Partial
        }
        It 'does not match wrong currency, region, DevTest, SKU, ARM SKU, unit, or meter' {
            foreach ($name in @('currencyCode', 'armRegionName', 'type', 'skuName', 'armSkuName', 'unitOfMeasure', 'meterName')) {
                $prices = @(Get-ReferencePrices)
                $prices[0].$name = 'wrong'
                $quote = @(Get-SsaPriceEstimate $recommendation -Region eastus -PriceData $prices)[0]
                $quote.Status | Should -Be Partial
                $quote.TotalMonthly | Should -BeNullOrEmpty
            }
        }
        It 'uses the latest effective rate and refuses a future-only rate' {
            $old = $prices[0] | ConvertTo-Json | ConvertFrom-Json
            $old.effectiveStartDate = '2020-01-01T00:00:00Z'
            $old.retailPrice = 99
            @(Get-SsaPriceEstimate $recommendation -Region eastus -PriceData @($prices + $old))[0].Status | Should -Be Complete
            $prices[0].effectiveStartDate = '2099-01-01T00:00:00Z'
            @(Get-SsaPriceEstimate $recommendation -Region eastus -PriceData $prices)[0].Status | Should -Be Partial
        }
        It 'rejects a mismatched catalog identity and missing capacities' {
            $recommendation.VCores = 999
            @(Get-SsaPriceEstimate $recommendation -Region eastus -PriceData $prices)[0].Status | Should -Be Unavailable
            $recommendation = New-PriceRecommendation
            $recommendation.DataGB = $null
            @(Get-SsaPriceEstimate $recommendation -Region eastus -PriceData $prices)[0].Status | Should -Be Unavailable
        }
        It 'prices Windows VM compute, active-core SQL licensing, and OS/data/log disks' {
            $vm = New-PriceRecommendation Standard_E4ads_v7
            $quotes = @(Get-SsaPriceEstimate $vm -Region eastus -PriceData $prices -SqlHybridBenefit)
            $quotes[0].Status | Should -Be Complete
            $quotes[0].TotalMonthly | Should -Be ([decimal]'0.474' * 730 + [decimal]'0.4' * 730 + [decimal]'19.71' * 2 + [decimal]'135.17')
            $quotes[0].Components.Count | Should -Be 5
            $quotes[1].TotalMonthly | Should -Be ([decimal]'0.474' * 730 + [decimal]'19.71' * 2 + [decimal]'135.17')
        }
        It 'keeps SQL and Windows Hybrid Benefit independent for VMs' {
            $vm = New-PriceRecommendation Standard_E4ads_v7
            $windowsOnly = @(Get-SsaPriceEstimate $vm -Region eastus -PriceData $prices -WindowsHybridBenefit)[1]
            $windowsOnly.TotalMonthly | Should -Be ([decimal]'0.29' * 730 + [decimal]'0.4' * 730 + [decimal]'19.71' * 2 + [decimal]'135.17')
            $both = @(Get-SsaPriceEstimate $vm -Region eastus -PriceData $prices -WindowsHybridBenefit -SqlHybridBenefit)[1]
            $both.TotalMonthly | Should -Be ([decimal]'0.29' * 730 + [decimal]'19.71' * 2 + [decimal]'135.17')
            $both.Benefits.Sql | Should -BeTrue
            $both.Benefits.Windows | Should -BeTrue
        }
        It 'uses the exact Edsv7 ARM-formatted retail identity and per-core Enterprise licensing' {
            $vm = New-PriceRecommendation Standard_E4ds_v7
            $vm.SqlEdition = 'Enterprise'
            $quote = @(Get-SsaPriceEstimate $vm -Region eastus -PriceData $prices)[0]
            $quote.Status | Should -Be Complete
            ($quote.Components | Where-Object Component -eq ComputeAndWindows).SkuName | Should -Be Standard_E4ds_v7
            ($quote.Components | Where-Object Component -eq SqlLicense).Rate | Should -Be 0.375
            ($quote.Components | Where-Object Component -eq SqlLicense).Quantity | Should -Be 2920
        }
        It 'accepts the sizing DiskLayout contract and preserves provisional confidence' {
            $vm = New-PriceRecommendation Standard_E4ads_v7
            $vm.Status = 'Provisional'
            $vm | Add-Member NoteProperty Confidence 'Conservative'
            $vm.DiskLayout[0].Role = 'Os'
            $vm.DiskLayout[0] | Add-Member NoteProperty SizeGB 128
            $quote = @(Get-SsaPriceEstimate $vm -Region eastus -PriceData $prices)[0]
            $quote.Status | Should -Be Complete
            $quote.RecommendationStatus | Should -Be Provisional
            $quote.RecommendationConfidence | Should -Be Conservative
            $vm.DiskLayout[0].SizeGB = 1024
            @(Get-SsaPriceEstimate $vm -Region eastus -PriceData $prices)[0].TotalMonthly | Should -BeNullOrEmpty
        }
        It 'does not quote unsupported SQL targets or silently omit mandatory VM disks' {
            $vm = New-PriceRecommendation Standard_E4ads_v7
            $vm.SqlMajorVersion = 11
            @(Get-SsaPriceEstimate $vm -Region eastus -PriceData $prices)[0].Status | Should -Be Unavailable
            $vm.SqlMajorVersion = 16
            $vm.DiskLayout = @()
            $quote = @(Get-SsaPriceEstimate $vm -Region eastus -PriceData $prices)[0]
            $quote.Status | Should -Be Partial
            $quote.TotalMonthly | Should -BeNullOrEmpty
            $quote.Errors -join ' ' | Should -Match 'OS'
        }
        It 'refuses undersized, excessive, or unsupported paid disk layouts' {
            foreach ($mode in @('Capacity', 'DiskCount', 'Bursting', 'Tempdb')) {
                $vm = New-PriceRecommendation Standard_E4ads_v7
                if ($mode -eq 'Capacity') { $vm.DataGB = 2000 }
                if ($mode -eq 'DiskCount') { $vm.DiskLayout[1].Count = 12 }
                if ($mode -eq 'Bursting') { $vm.DiskLayout[1] | Add-Member BurstingEnabled $true }
                if ($mode -eq 'Tempdb') { $vm.TempdbGB = 1000 }
                $quote = @(Get-SsaPriceEstimate $vm -Region eastus -PriceData $prices)[0]
                $quote.Status | Should -Be Partial
                $quote.TotalMonthly | Should -BeNullOrEmpty
            }
        }
        It 'uses a fresh identity-validated offline cache without HTTP' {
            [void](New-PriceCache $recommendation)
            $quote = @(Get-SsaPriceEstimate $recommendation -Region eastus -CachePath $script:PriceTestCache -Offline)[0]
            $quote.Status | Should -Be Complete
            $quote.PricingSource | Should -Be Cache
            $quote.IsStale | Should -BeFalse
            Should -Invoke Invoke-RestMethod -Times 0 -Exactly
        }
        It 'refreshes an existing stale cache atomically and can then reuse it offline' {
            [void](New-PriceCache $recommendation -RetrievedAt ([datetimeoffset]::UtcNow.AddDays(-10)))
            Mock Get-SsaRetailPageItem {
                $query = [uri]::UnescapeDataString($Uri)
                @(
                    Get-ReferencePrices | Where-Object {
                        $query.Contains("productName eq '$($_.productName)'") -and
                        $query.Contains("skuName eq '$($_.skuName)'") -and
                        $query.Contains("meterName eq '$($_.meterName)'") -and
                        $query.Contains("armRegionName eq '$($_.armRegionName)'")
                    }
                )
            }
            $quote = @(Get-SsaPriceEstimate $recommendation -Region eastus -CachePath $script:PriceTestCache)[0]
            $quote.Status | Should -Be Complete
            $quote.PricingSource | Should -Be RetailApi
            $quote.IsStale | Should -BeFalse
            $offline = @(Get-SsaPriceEstimate $recommendation -Region eastus -CachePath $script:PriceTestCache -Offline)[0]
            $offline.PricingSource | Should -Be Cache
            @((Get-ChildItem -LiteralPath $script:PriceTestCache) | Where-Object Name -match '\.new$|\.previous$').Count | Should -Be 0
        }
        It 'only uses stale cache after online failure with explicit permission' {
            [void](New-PriceCache $recommendation -RetrievedAt ([datetimeoffset]::UtcNow.AddDays(-10)))
            $quote = @(Get-SsaPriceEstimate $recommendation -Region eastus -CachePath $script:PriceTestCache)[0]
            $quote.Status | Should -Be Unavailable
            $quote = @(Get-SsaPriceEstimate $recommendation -Region eastus -CachePath $script:PriceTestCache -AllowStaleCache -WarningAction SilentlyContinue)[0]
            $quote.Status | Should -Be Complete
            $quote.PricingSource | Should -Be CacheAfterRefreshFailure
            $quote.IsStale | Should -BeTrue
        }
        It 'requires explicit stale-cache permission offline and exposes staleness' {
            [void](New-PriceCache $recommendation -RetrievedAt ([datetimeoffset]::UtcNow.AddDays(-10)))
            $quote = @(Get-SsaPriceEstimate $recommendation -Region eastus -CachePath $script:PriceTestCache -Offline)[0]
            $quote.Status | Should -Be Unavailable
            $quote.Errors -join ' ' | Should -Match 'seven days'
            $quote = @(Get-SsaPriceEstimate $recommendation -Region eastus -CachePath $script:PriceTestCache -Offline -AllowStaleCache)[0]
            $quote.Status | Should -Be Complete
            $quote.IsStale | Should -BeTrue
            Should -Invoke Invoke-RestMethod -Times 0 -Exactly
        }
        It 'rejects cache region/currency/version, missing query coverage, foreign rows, and future timestamps' {
            foreach ($mode in @('Region', 'Currency', 'ApiVersion', 'Filters', 'ForeignRow', 'RetrievedAt')) {
                $file = New-PriceCache $recommendation
                $envelope = Read-SsaJson $file
                switch ($mode) {
                    Region { $envelope.Region = 'westus' }
                    Currency { $envelope.Currency = 'EUR' }
                    ApiVersion { $envelope.ApiVersion = 'unrecognized' }
                    Filters { $envelope.Filters = @('not the required queries') }
                    ForeignRow { $envelope.Items[0].currencyCode = 'EUR' }
                    RetrievedAt { $envelope.RetrievedAt = [datetimeoffset]::UtcNow.AddDays(2).ToString('o') }
                }
                Write-SsaRetailCache $file $envelope
                $quote = @(Get-SsaPriceEstimate $recommendation -Region eastus -CachePath $script:PriceTestCache -Offline -AllowStaleCache)[0]
                $quote.Status | Should -Be Unavailable
            }
        }
        It 'rejects corrupt or absent offline cache without network fallback' {
            $file = New-PriceCache $recommendation
            [IO.File]::WriteAllText($file, '{invalid')
            @(Get-SsaPriceEstimate $recommendation -Region eastus -CachePath $script:PriceTestCache -Offline)[0].Status | Should -Be Unavailable
            Remove-Item -LiteralPath $file
            @(Get-SsaPriceEstimate $recommendation -Region eastus -CachePath $script:PriceTestCache -Offline)[0].Status | Should -Be Unavailable
            Should -Invoke Invoke-RestMethod -Times 0 -Exactly
        }
        It 'follows valid pagination including a legitimately empty last page' {
            Mock Invoke-SsaRetailRequest {
                if ($Uri -match 'skip=') { return [pscustomobject]@{ Items = @(); NextPageLink = $null } }
                [pscustomobject]@{ Items = @([pscustomobject]@{ meterId = 'first' }); NextPageLink = 'https://prices.azure.com:443/api/retail/prices?$skip=1000' }
            }
            $items = Get-SsaRetailPageItem 'https://prices.azure.com/api/retail/prices?api-version=2023-01-01-preview'
            @($items).Count | Should -Be 1
            Should -Invoke Invoke-SsaRetailRequest -Times 2 -Exactly
        }
        It 'refuses pagination loops, foreign hosts, non-HTTPS, ports, and user information' {
            Mock Invoke-SsaRetailRequest { [pscustomobject]@{ Items = @(); NextPageLink = $Uri } }
            { Get-SsaRetailPageItem 'https://prices.azure.com/api/retail/prices' } | Should -Throw '*loop*'
            foreach ($uri in @('https://evil.example/api/retail/prices', 'http://prices.azure.com/api/retail/prices', 'https://prices.azure.com:8443/api/retail/prices', 'https://user@prices.azure.com/api/retail/prices')) {
                { Assert-SsaRetailUri $uri } | Should -Throw '*Unsafe*'
            }
        }
        It 'rejects malformed retail response envelopes' {
            Mock Invoke-SsaRetailRequest { [pscustomobject]@{ unrelated = @() } }
            { Get-SsaRetailPageItem 'https://prices.azure.com/api/retail/prices' } | Should -Throw '*Invalid retail API response*'
        }
        It 'retries throttling honoring Retry-After without real sleeping' {
            $script:RetryCount = 0
            Mock Start-Sleep {}
            Mock Invoke-RestMethod {
                $script:RetryCount++
                if ($script:RetryCount -eq 1) {
                    $exception = New-Object System.Exception('throttled')
                    $exception | Add-Member NoteProperty Response ([pscustomobject]@{ StatusCode = 429; Headers = @{ 'Retry-After' = '3' } })
                    throw $exception
                }
                [pscustomobject]@{ Items = @(); NextPageLink = $null }
            }
            $null = Invoke-SsaRetailRequest 'https://prices.azure.com/api/retail/prices'
            Should -Invoke Invoke-RestMethod -Times 2 -Exactly
            Should -Invoke Start-Sleep -Times 1 -Exactly -ParameterFilter { $Seconds -eq 3 }
        }
        It 'bounds server-error retries and never retries nontransient errors' {
            Mock Start-Sleep {}
            Mock Invoke-RestMethod {
                $exception = New-Object System.Exception('server error')
                $exception | Add-Member NoteProperty Response ([pscustomobject]@{ StatusCode = 503; Headers = @{} })
                throw $exception
            }
            { Invoke-SsaRetailRequest 'https://prices.azure.com/api/retail/prices' } | Should -Throw '*server error*'
            Should -Invoke Invoke-RestMethod -Times 4 -Exactly
            Should -Invoke Start-Sleep -Times 3 -Exactly
        }
        It 'does not retry a nontransient HTTP error' {
            Mock Start-Sleep {}
            Mock Invoke-RestMethod {
                $exception = New-Object System.Exception('bad request')
                $exception | Add-Member NoteProperty Response ([pscustomobject]@{ StatusCode = 400; Headers = @{} })
                throw $exception
            }
            { Invoke-SsaRetailRequest 'https://prices.azure.com/api/retail/prices' } | Should -Throw '*bad request*'
            Should -Invoke Invoke-RestMethod -Times 1 -Exactly
            Should -Invoke Start-Sleep -Times 0 -Exactly
        }
        It 'refuses excessive Retry-After instead of silently ignoring the requested delay' {
            Mock Start-Sleep {}
            Mock Invoke-RestMethod {
                $exception = New-Object System.Exception('throttled')
                $exception | Add-Member NoteProperty Response ([pscustomobject]@{ StatusCode = 429; Headers = @{ 'Retry-After' = '121' } })
                throw $exception
            }
            { Invoke-SsaRetailRequest 'https://prices.azure.com/api/retail/prices' } | Should -Throw '*120-second*'
            Should -Invoke Start-Sleep -Times 0 -Exactly
        }
    }
}
