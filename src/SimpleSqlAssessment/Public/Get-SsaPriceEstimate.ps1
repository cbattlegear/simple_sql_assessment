function Get-SsaPriceEstimate {
    <#
    .SYNOPSIS
    Estimates public retail PAYG and user-asserted Azure Hybrid Benefit costs.
    .DESCRIPTION
    Region is an Azure ARM region name. CachePath is a directory. Offline never accesses the network.
    Cache entries expire after seven days; stale use requires AllowStaleCache. PriceData is explicit
    Retail Prices API-shaped input for reproducible estimates and never falls back to live prices.
    Monthly storage/disk rates describe a full provisioned month and are not multiplied by compute hours.
    AHB switches assert entitlement; they do not validate licenses. Missing mandatory prices produce
    a null total. VM DiskLayout entries require DiskId, Count and Role (OS, Data, Log, Tempdb).
    Configurable disks also require SizeGB, Iops and ThroughputMBps, and a matching recommendation
    DiskType. Hourly provisioned disk resources use 730 hours independently of compute running hours.
    .EXAMPLE
    $recommendations | Get-SsaPriceEstimate -Region eastus -SqlHybridBenefit -CachePath .\pricing-cache
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, ValueFromPipeline)][object[]]$Recommendation,
        [Parameter(Mandatory)][ValidatePattern('^[a-z][a-z0-9]+$')][string]$Region,
        [ValidatePattern('^[A-Za-z]{3}$')][string]$Currency = 'USD',
        [ValidateRange(0.01, 8784)][decimal]$HoursPerMonth = 730,
        [switch]$SqlHybridBenefit,
        [switch]$WindowsHybridBenefit,
        [string]$CachePath,
        [switch]$Offline,
        [switch]$AllowStaleCache,
        [AllowEmptyCollection()][object[]]$PriceData
    )
    begin { $recommendations = New-Object 'System.Collections.Generic.List[object]' }
    process { foreach ($item in $Recommendation) { $recommendations.Add($item) } }
    end {
        $Currency = $Currency.ToUpperInvariant()
        $catalog = Get-SsaCatalog
        $candidates = @($catalog.SqlDatabase) + @($catalog.ManagedInstance) + @($catalog.Vm)
        $work = New-Object 'System.Collections.Generic.List[object]'
        $queries = New-Object 'System.Collections.Generic.HashSet[string]'
        foreach ($item in $recommendations) {
            $catalogMatches = @($candidates | Where-Object { $_.Id -ceq (Get-SsaValue $item 'CatalogId') })
            $candidate = $null
            if ($catalogMatches.Count -eq 1) { $candidate = $catalogMatches[0] }
            foreach ($scenario in @('Payg', 'Ahb')) {
                $eligible = $scenario -eq 'Payg' -or $SqlHybridBenefit -or ($WindowsHybridBenefit -and (Get-SsaValue $item 'Target') -eq 'SqlVm')
                $ineligibleReason = 'AHB requires explicit applicable -SqlHybridBenefit and/or -WindowsHybridBenefit entitlement assertion.'
                if ($scenario -eq 'Ahb' -and (Get-SsaValue $candidate 'ServiceTier') -eq 'Hyperscale') {
                    $eligible = $false
                    $ineligibleReason = 'Azure Hybrid Benefit is not available for new Hyperscale databases; PAYG already has no SQL software license fee. Legacy existing-database pricing is outside this migration model.'
                }
                $components = @()
                if ($eligible) {
                    $components = Get-SsaPriceComponent -Recommendation $item -Candidate $candidate -Catalog $catalog -Region $Region -Scenario $scenario -SqlHybridBenefit ([bool]$SqlHybridBenefit) -WindowsHybridBenefit ([bool]$WindowsHybridBenefit)
                    foreach ($component in $components) {
                        if ($component.Match) { [void]$queries.Add((Get-SsaComponentFilter $component.Match)) }
                    }
                }
                $work.Add([pscustomobject]@{ Recommendation = $item; Candidate = $candidate; Scenario = $scenario; Eligible = $eligible; IneligibleReason = $ineligibleReason; Components = $components })
            }
        }
        $data = [pscustomobject]@{ Items = @(); RetrievedAt = [datetimeoffset]::UtcNow.ToString('o'); Source = 'ExplicitPriceData'; IsStale = $false; CachePath = $null }
        $fetchError = $null
        if ($PSBoundParameters.ContainsKey('PriceData')) { $data.Items = @($PriceData) }
        elseif ($queries.Count) {
            try {
                $data = Get-SsaRetailPriceData -Region $Region -Currency $Currency -Filters @($queries | Sort-Object) -CachePath $CachePath -Offline:$Offline -AllowStaleCache:$AllowStaleCache
            } catch { $fetchError = $_.Exception.Message; $data.Source = 'Unavailable' }
        }
        $quotes = New-Object 'System.Collections.Generic.List[object]'
        foreach ($entry in $work) {
            $components = New-Object 'System.Collections.Generic.List[object]'
            $errors = New-Object 'System.Collections.Generic.List[string]'
            $known = [decimal]0
            foreach ($part in $entry.Components) {
                $component = [ordered]@{
                    Component = $part.Component; MeterId = $null; Quantity = $null; Unit = $null; Rate = $null
                    MonthlyCost = $null; EffectiveStartDate = $null; RetrievedAt = $data.RetrievedAt
                    Status = 'Unavailable'; PublishedZeroRate = $false; ProductName = $null; SkuName = $null
                    MeterName = $null; ArmSkuName = $null; MeterRegion = $null; IsPrimaryMeterRegion = $null
                    TierMinimumUnits = $null
                }
                try {
                    if ($part.Error) { throw $part.Error }
                    if ($fetchError) { throw $fetchError }
                    $resolved = Resolve-SsaRetailMeter -Items $data.Items -Match $part.Match -Currency $Currency
                    $meter = $resolved.Item
                    $quantity = ConvertTo-SsaBillingQuantity -Amount $part.Amount -Basis $part.Basis -Unit $meter.unitOfMeasure -HoursPerMonth $HoursPerMonth
                    $cost = $resolved.Rate * $quantity
                    $component.MeterId = $meter.meterId; $component.Quantity = $quantity; $component.Unit = $meter.unitOfMeasure
                    $component.Rate = $resolved.Rate; $component.MonthlyCost = $cost
                    $component.EffectiveStartDate = $meter.effectiveStartDate; $component.Status = 'Priced'
                    $component.PublishedZeroRate = $resolved.Rate -eq 0
                    $component.ProductName = $meter.productName; $component.SkuName = $meter.skuName
                    $component.MeterName = $meter.meterName; $component.ArmSkuName = Get-SsaValue $meter 'armSkuName'
                    $component.MeterRegion = $meter.armRegionName; $component.IsPrimaryMeterRegion = Get-SsaValue $meter 'isPrimaryMeterRegion'
                    $component.TierMinimumUnits = $meter.tierMinimumUnits
                    $known += $cost
                } catch { $errors.Add($part.Component + ': ' + $_.Exception.Message) }
                $components.Add([pscustomobject]$component)
            }
            $status = 'Complete'
            $total = $known
            if (-not $entry.Eligible) { $status = 'NotEligible'; $total = $null; $errors.Add($entry.IneligibleReason) }
            elseif ($errors.Count) {
                $status = 'Unavailable'
                if (@($components | Where-Object { $_.Status -eq 'Priced' }).Count) { $status = 'Partial' }
                $total = $null
            } elseif (-not $components.Count) { $status = 'Unavailable'; $total = $null; $errors.Add('No mandatory components could be modeled.') }
            $quotes.Add([pscustomobject][ordered]@{
                RecommendationId = Get-SsaValue $entry.Recommendation 'RecommendationId'; Scenario = $entry.Scenario
                Status = $status; TotalMonthly = $total; Currency = $Currency; Region = $Region; HoursPerMonth = $HoursPerMonth
                Components = $components.ToArray(); Errors = $errors.ToArray(); KnownMonthly = $known
                CatalogId = Get-SsaValue $entry.Recommendation 'CatalogId'; CatalogVersion = $catalog.Version
                SourceUrls = $catalog.SourceUrls; PricingSource = $data.Source; ApiVersion = $script:SsaRetailApiVersion
                RetrievedAt = $data.RetrievedAt; IsStale = $data.IsStale; CachePath = $data.CachePath
                Confidence = 'PublicRetailEstimate'; MappingVersion = '2026.10.27.3'
                DiskType = Get-SsaValue $entry.Recommendation 'DiskType'
                StorageHoursPerMonth = 730
                DiskBillingPolicy = 'Premium SSD v2: provisioned GiB plus IOPS above 3000 and MB/s above 125 per disk. Ultra: all provisioned IOPS/MBps, conservative capacity rounded to published offers because Microsoft capacity documentation conflicts. 730 provisioned hours/month, independently of compute. Ultra reservation surcharge excluded only because Ultra disks are attached.'
                RecommendationStatus = Get-SsaValue $entry.Recommendation 'Status'
                RecommendationConfidence = Get-SsaValue $entry.Recommendation 'Confidence'
                SpecificationSourceUrl = Get-SsaValue $entry.Candidate 'SourceUrl'
                SpecificationSourceRevision = Get-SsaValue $entry.Candidate 'SourceRevision'
                Benefits = [pscustomobject]@{ Sql = ($entry.Eligible -and $entry.Scenario -eq 'Ahb' -and [bool]$SqlHybridBenefit); Windows = ($entry.Eligible -and $entry.Scenario -eq 'Ahb' -and [bool]$WindowsHybridBenefit -and (Get-SsaValue $entry.Recommendation 'Target') -eq 'SqlVm') }
                Assumptions = @('Public retail estimate, not an invoice, license entitlement check, availability check, or performance guarantee.', 'PAYG = base compute + applicable SQL license + storage; Windows is included in the Windows VM compute meter. AHB removes SQL license charges only with asserted entitlement and uses the base VM meter only with separate Windows entitlement. New Hyperscale databases have no SQL software license fee and are not AHB-eligible.', 'PaaS log/tempdb are not separately billed as managed disks. MI reserved storage includes data/log and, on BC, tempdb. Next-gen MI uses the documented GP baseline plus separately billed additional IOPS/month and flexible memory/GB/hour; AHB does not discount these extra resources. GP/BC SQL Database bills configured data capacity (ReservedStorageGB) plus the automatic 30 percent log allowance. Hyperscale bills allocated data with a ten-GiB minimum, no log surcharge, one primary, and no secondary replica.', 'Storage, disks, and additional IOPS remain provisioned for a full month regardless of HoursPerMonth. No paid disk bursting, performance-plus, shared disks, or HA replicas are modeled.', 'Excluded: backup overages/LTR, HA/DR extras, network egress, monitoring, support, tax, negotiated discounts, software assurance acquisition, and other usage-based services.', 'Non-USD prices are reference estimates. Unknown prices are never converted to zero; partial totals remain null.')
            })
        }
        Update-SsaDiskSuggestion $recommendations.ToArray() $quotes.ToArray()
        $quotes.ToArray()
    }
}
