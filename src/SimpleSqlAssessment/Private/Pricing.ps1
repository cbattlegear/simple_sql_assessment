$script:SsaRetailApiVersion = '2023-01-01-preview'

function Write-SsaRetailCache {
    param([string]$Path, $Value)
    $fullPath = [IO.Path]::GetFullPath($Path)
    $token = [guid]::NewGuid().ToString('N')
    $staged = $fullPath + '.' + $token + '.new'
    $backup = $fullPath + '.' + $token + '.previous'
    try {
        Write-SsaJson -Path $staged -Value $Value
        # A concrete backup path avoids the PS/.NET null-string binding difference in File.Replace.
        if ([IO.File]::Exists($fullPath)) { [IO.File]::Replace($staged, $fullPath, $backup) }
        else { [IO.File]::Move($staged, $fullPath) }
    } finally {
        foreach ($file in @($staged, $backup)) {
            if ([IO.File]::Exists($file)) { [IO.File]::Delete($file) }
        }
    }
}

function Assert-SsaRetailUri {
    param([string]$Uri)
    $parsed = $null
    if (-not [uri]::TryCreate($Uri, [UriKind]::Absolute, [ref]$parsed) -or
        $parsed.Scheme -cne 'https' -or $parsed.Host -cne 'prices.azure.com' -or
        $parsed.Port -ne 443 -or $parsed.AbsolutePath.TrimEnd('/') -cne '/api/retail/prices' -or
        $parsed.UserInfo -or $parsed.Fragment) { throw 'Unsafe retail API pagination URL.' }
}

function Invoke-SsaRetailRequest {
    param([Parameter(Mandatory)][string]$Uri)
    Assert-SsaRetailUri $Uri
    for ($attempt = 0; $attempt -lt 4; $attempt++) {
        try {
            return Invoke-RestMethod -Uri $Uri -Method Get -TimeoutSec 45 -MaximumRedirection 0 -ErrorAction Stop
        } catch {
            $response = Get-SsaValue $_.Exception 'Response'
            $status = [int](Get-SsaValue $response 'StatusCode' 0)
            if ($attempt -eq 3 -or ($status -ne 429 -and ($status -lt 500 -or $status -gt 599))) { throw }
            $delay = [math]::Pow(2, $attempt)
            $headers = Get-SsaValue $response 'Headers'
            $retryAfter = $null
            if ($headers) {
                try { $retryAfter = [string]$headers['Retry-After'] } catch { $retryAfter = $null }
                if (-not $retryAfter) { $retryAfter = [string](Get-SsaValue $headers 'RetryAfter') }
            }
            if ($retryAfter) {
                $seconds = 0
                $date = [datetimeoffset]::MinValue
                if ([int]::TryParse($retryAfter, [ref]$seconds)) { $delay = [math]::Max(0, $seconds) }
                elseif ([datetimeoffset]::TryParse($retryAfter, [ref]$date)) { $delay = [math]::Max(0, [math]::Ceiling(($date - [datetimeoffset]::UtcNow).TotalSeconds)) }
                else { throw 'Invalid Retry-After response; refusing an unbounded retry.' }
            }
            if ($delay -gt 120) { throw 'Retry-After exceeds the bounded 120-second retry budget; retry the pricing refresh later.' }
            Start-Sleep -Seconds ([int]$delay)
        }
    }
}

function Get-SsaRetailPageItem {
    param([Parameter(Mandatory)][string]$Uri)
    $seen = New-Object 'System.Collections.Generic.HashSet[string]'
    $items = New-Object 'System.Collections.Generic.List[object]'
    while ($Uri) {
        Assert-SsaRetailUri $Uri
        if ($seen.Count -ge 100 -or -not $seen.Add($Uri)) { throw 'Retail API pagination loop or 100-page safety limit reached.' }
        $page = Invoke-SsaRetailRequest $Uri
        if ($null -eq $page.PSObject.Properties['Items'] -or $null -eq $page.PSObject.Properties['NextPageLink'] -or
            $null -eq $page.Items -or $page.Items -is [string] -or -not ($page.Items -is [System.Collections.IEnumerable])) {
            throw 'Invalid retail API response: Items and NextPageLink are required.'
        }
        foreach ($item in @($page.Items)) { $items.Add($item) }
        $Uri = [string]$page.NextPageLink
    }
    return ,$items.ToArray()
}

function Get-SsaRetailPriceData {
    param([string]$Region, [string]$Currency, [string[]]$Filters, [string]$CachePath, [switch]$Offline, [switch]$AllowStaleCache)
    if (-not $CachePath) { $CachePath = Join-Path (Get-Location).Path '.ssa-pricing-cache' }
    $file = Join-Path $CachePath ($Region + '-' + $Currency + '-' + $script:SsaRetailApiVersion + '.json')
    $cache = $null
    $cacheError = $null
    $stale = $false
    if ([IO.File]::Exists($file)) {
        try {
            $cache = Read-SsaJson $file
            if ((Get-SsaValue $cache 'SchemaVersion') -cne '1.0' -or
                (Get-SsaValue $cache 'Region') -cne $Region -or (Get-SsaValue $cache 'Currency') -cne $Currency -or
                (Get-SsaValue $cache 'ApiVersion') -cne $script:SsaRetailApiVersion -or
                $null -eq $cache.PSObject.Properties['Filters'] -or $null -eq $cache.PSObject.Properties['Items'] -or
                $null -eq $cache.Filters -or $null -eq $cache.Items) {
                throw 'Pricing cache identity/schema mismatch.'
            }
            $retrieved = [datetimeoffset]::Parse([string]$cache.RetrievedAt, [Globalization.CultureInfo]::InvariantCulture)
            if ($retrieved -gt [datetimeoffset]::UtcNow.AddMinutes(5)) { throw 'Pricing cache retrieval time is in the future.' }
            $stale = $retrieved -lt [datetimeoffset]::UtcNow.AddDays(-7)
            foreach ($filter in $Filters) {
                if (@($cache.Filters) -cnotcontains $filter) { throw 'Pricing cache does not cover the required exact meter queries.' }
            }
            foreach ($item in @($cache.Items)) {
                if ((Get-SsaValue $item 'currencyCode') -cne $Currency -or
                    @($Region, 'Global', '') -cnotcontains [string](Get-SsaValue $item 'armRegionName')) { throw 'Pricing cache contains a foreign currency/region.' }
            }
        } catch { $cacheError = $_.Exception.Message; $cache = $null }
    }
    if ($cache -and (-not $stale -or ($Offline -and $AllowStaleCache))) {
        return [pscustomobject]@{ Items = @($cache.Items); RetrievedAt = $cache.RetrievedAt; Source = 'Cache'; IsStale = $stale; CachePath = $file }
    }
    if ($Offline) {
        if ($cacheError) { throw $cacheError }
        if ($cache -and $stale) { throw 'Pricing cache is older than seven days; explicitly use -AllowStaleCache for offline use.' }
        throw "No usable offline pricing cache for $Region/$Currency."
    }
    try {
        $all = New-Object 'System.Collections.Generic.List[object]'
        foreach ($filter in $Filters) {
            $uri = 'https://prices.azure.com/api/retail/prices?api-version=' + $script:SsaRetailApiVersion +
                '&currencyCode=' + [uri]::EscapeDataString("'" + $Currency + "'") + '&$filter=' + [uri]::EscapeDataString($filter)
            foreach ($item in (Get-SsaRetailPageItem $uri)) { $all.Add($item) }
        }
        $now = [datetimeoffset]::UtcNow.ToString('o')
        $newCache = [pscustomobject]@{
            SchemaVersion = '1.0'; ApiVersion = $script:SsaRetailApiVersion; Region = $Region; Currency = $Currency
            RetrievedAt = $now; Filters = @($Filters); Items = $all.ToArray()
        }
        Write-SsaRetailCache -Path $file -Value $newCache
        return [pscustomobject]@{ Items = $all.ToArray(); RetrievedAt = $now; Source = 'RetailApi'; IsStale = $false; CachePath = $file }
    } catch {
        if ($cache -and $AllowStaleCache) {
            Write-Warning ('Retail refresh failed; explicitly permitted cached prices are being used: ' + $_.Exception.Message)
            return [pscustomobject]@{ Items = @($cache.Items); RetrievedAt = $cache.RetrievedAt; Source = 'CacheAfterRefreshFailure'; IsStale = $stale; CachePath = $file }
        }
        throw
    }
}

function New-SsaMeterComponent {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Creates an in-memory billing descriptor only.')]
    param([string]$Component, [string]$Service, [string]$Product, [string]$Sku, [string]$Meter,
        [string]$Unit, [AllowNull()][string]$ArmSku, [string]$MeterRegion, [decimal]$Amount, [string]$Basis,
        [decimal]$TierMinimumUnits = 0, [bool]$RequireEmptyArmSku = $false)
    [pscustomobject]@{
        Component = $Component; Amount = $Amount; Basis = $Basis; Error = $null
        Match = [pscustomobject]@{
            serviceName = $Service; productName = $Product; skuName = $Sku; meterName = $Meter
            unitOfMeasure = $Unit; armSkuName = $ArmSku; armRegionName = $MeterRegion
            ExpectedTierMinimumUnits = $TierMinimumUnits; RequireEmptyArmSku = $RequireEmptyArmSku
        }
    }
}

function New-SsaUnpricedComponent {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Creates an in-memory unavailable-component descriptor only.')]
    param([string]$Component, [string]$Message)
    [pscustomobject]@{ Component = $Component; Amount = $null; Basis = $null; Error = $Message; Match = $null }
}

function ConvertTo-SsaBillingQuantity {
    param([decimal]$Amount, [string]$Basis, [string]$Unit, [decimal]$HoursPerMonth)
    if ($Amount -lt 0 -or $HoursPerMonth -le 0) { throw 'Billing amounts must be nonnegative and hours positive.' }
    switch -CaseSensitive ($Basis + '|' + $Unit) {
        'Hour|1 Hour' { return $Amount * $HoursPerMonth }
        'Hour|100 Hours' { return $Amount * $HoursPerMonth / 100 }
        'GBMonth|1 GB/Month' { return $Amount }
        'GBHour|1 GB/Hour' { return $Amount * $HoursPerMonth }
        'IopsMonth|1 IOPS/Month' { return $Amount }
        'Month|1/Month' { return $Amount }
        'Month|1 Month' { return $Amount }
        'ProvisionedMonth|1/Hour' { return $Amount * 730 }
        'ProvisionedMonth|1 GiB/Hour' { return $Amount * 730 }
        default { throw "Unsupported billing conversion: $Basis / $Unit." }
    }
}

function Get-SsaComponentFilter {
    param($Match)
    $parts = @("priceType eq 'Consumption'")
    foreach ($name in @('serviceName', 'productName', 'skuName', 'meterName', 'armRegionName')) {
        $value = ([string]$Match.$name).Replace("'", "''")
        $parts += $name + " eq '" + $value + "'"
    }
    # armSkuName can be blank for legitimate global SQL licenses.
    if ($Match.armSkuName) { $parts += "armSkuName eq '" + $Match.armSkuName.Replace("'", "''") + "'" }
    return $parts -join ' and '
}

function Resolve-SsaRetailMeter {
    param([object[]]$Items, $Match, [string]$Currency)
    $meterMatches = @(
        foreach ($item in $Items) {
            $equal = (Get-SsaValue $item 'currencyCode') -ceq $Currency -and (Get-SsaValue $item 'type') -ceq 'Consumption'
            foreach ($name in @('serviceName', 'productName', 'skuName', 'meterName', 'unitOfMeasure', 'armRegionName')) {
                if ((Get-SsaValue $item $name) -cne $Match.$name) { $equal = $false }
            }
            if ($Match.armSkuName -and (Get-SsaValue $item 'armSkuName') -cne $Match.armSkuName) { $equal = $false }
            if ((Get-SsaValue $Match 'RequireEmptyArmSku' $false) -and (Get-SsaValue $item 'armSkuName') -cne '') { $equal = $false }
            if ((Get-SsaValue $Match 'ExpectedTierMinimumUnits' 0) -ne 0 -and
                (Get-SsaValue $item 'tierMinimumUnits') -ne $Match.ExpectedTierMinimumUnits) { $equal = $false }
            if ((Get-SsaValue $Match 'ExpectedTierMinimumUnits' 0) -eq 0 -and
                (Get-SsaValue $item 'productName') -eq 'Azure Premium SSD v2' -and (Get-SsaValue $item 'tierMinimumUnits') -ne 0) { $equal = $false }
            if ($equal) { $item }
        }
    )
    if (-not $meterMatches.Count) { throw "Missing exact retail meter: $($Match.productName) / $($Match.skuName) / $($Match.meterName) / $($Match.armRegionName)." }
    $eligible = @(
        foreach ($item in $meterMatches) {
            $rate = [decimal]0
            if ($null -eq (Get-SsaValue $item 'retailPrice') -or
                -not [decimal]::TryParse([string]$item.retailPrice, [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$rate) -or $rate -lt 0) {
                throw 'Exact retail meter has a missing, negative, or invalid rate.'
            }
            if ($null -eq (Get-SsaValue $item 'tierMinimumUnits') -or [decimal]$item.tierMinimumUnits -ne (Get-SsaValue $Match 'ExpectedTierMinimumUnits' 0)) { throw 'Tiered/invalid retail rate is not supported by this mapping.' }
            if (-not (Get-SsaValue $item 'meterId')) { throw 'Exact retail meter has no meterId.' }
            $effective = [datetimeoffset]::MinValue
            if (-not [datetimeoffset]::TryParse([string](Get-SsaValue $item 'effectiveStartDate'), [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::AssumeUniversal, [ref]$effective)) {
                throw 'Exact retail meter has no valid effective start date.'
            }
            if ($effective -le [datetimeoffset]::UtcNow) { [pscustomobject]@{ Item = $item; Rate = $rate; Effective = $effective } }
        }
    )
    if (-not $eligible.Count) { throw 'Exact retail meter is not yet effective.' }
    $latest = ($eligible | Sort-Object Effective -Descending | Select-Object -First 1).Effective
    $current = @($eligible | Where-Object { $_.Effective -eq $latest })
    if ($current.Count -ne 1) { throw "Ambiguous exact retail meter: $($current.Count) current matches; no arbitrary rate selected." }
    return $current[0]
}

function Get-SsaPriceComponent {
    param($Recommendation, $Candidate, $Catalog, [string]$Region, [string]$Scenario, [bool]$SqlHybridBenefit, [bool]$WindowsHybridBenefit)
    $sqlAhb = $Scenario -eq 'Ahb' -and $SqlHybridBenefit
    $windowsAhb = $Scenario -eq 'Ahb' -and $WindowsHybridBenefit
    $parts = New-Object 'System.Collections.Generic.List[object]'
    if (-not $Candidate) {
        $parts.Add((New-SsaUnpricedComponent Configuration 'CatalogId is missing or is outside the supported target catalog.'))
        return ,$parts.ToArray()
    }
    foreach ($field in @('Target', 'VCores', 'MemoryGB', 'ServiceTier', 'Hardware', 'VmSize')) {
        $value = Get-SsaValue $Recommendation $field
        if ($null -ne $value -and [string]$value -cne [string]$Candidate.$field) {
            $parts.Add((New-SsaUnpricedComponent Configuration "Recommendation $field does not match CatalogId."))
            return ,$parts.ToArray()
        }
    }
    if ((Get-SsaValue $Recommendation 'Status') -in @('NoFit', 'Unavailable', 'NotRecommended', 'Error', 'Unsupported')) {
        $parts.Add((New-SsaUnpricedComponent Configuration 'Recommendation is not a priceable configuration.'))
        return ,$parts.ToArray()
    }
    foreach ($field in @('DataGB', 'LogGB', 'TempdbGB')) {
        $value = Get-SsaValue $Recommendation $field
        $number = [decimal]0
        if ($null -eq $value -or -not [decimal]::TryParse([string]$value, [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$number) -or $number -lt 0) {
            $parts.Add((New-SsaUnpricedComponent Configuration "Recommendation requires a nonnegative $field; missing capacity is not zero."))
            return ,$parts.ToArray()
        }
    }
    if ($Candidate.Target -ne 'SqlVm') {
        $label = @{ GeneralPurpose = 'General Purpose'; NextGenGeneralPurpose = 'General Purpose'; BusinessCritical = 'Business Critical'; Hyperscale = 'Hyperscale' }[$Candidate.ServiceTier]
        $service = 'SQL Database'
        $stem = 'SQL Database Single/Elastic Pool '
        $license = $stem + $label + ' - SQL License'
        $storage = $stem + $label + ' - Storage'
        $storageSku = $label
        $storageMeter = $label + ' Data Stored'
        $storageAmount = [math]::Max([decimal]1, [math]::Ceiling([decimal]$Recommendation.DataGB))
        $storageLimit = $Candidate.MaxDataGB
        if ($Candidate.Target -eq 'ManagedInstance') {
            $capacity = Get-SsaManagedInstanceCapacity $Candidate $Region
            if (-not $capacity) {
                $parts.Add((New-SsaUnpricedComponent Configuration 'This MI hardware is not listed as supported in the selected region.'))
                return ,$parts.ToArray()
            }
            $storageLimit = $capacity.MaxDataGB
            $service = 'SQL Managed Instance'
            $stem = 'SQL Managed Instance ' + $label
            $compute = Get-SsaValue $Candidate 'ComputeProduct'
            $arm = Get-SsaValue $Candidate 'ComputeArmSku'
            if (-not $compute -or -not $arm) {
                $parts.Add((New-SsaUnpricedComponent Compute 'The MI tier/hardware has no verified exact compute-meter mapping.'))
                return ,$parts.ToArray()
            }
            $license = $stem + ' - SQL License'
            $storage = $stem + ' - Storage'
            $requiredStorage = [decimal]$Recommendation.DataGB + [decimal]$Recommendation.LogGB
            if ($Candidate.ServiceTier -eq 'BusinessCritical') { $requiredStorage += [decimal]$Recommendation.TempdbGB }
            $storageAmount = [math]::Max(32, [math]::Ceiling($requiredStorage / 32) * 32)
        } elseif ($Candidate.ServiceTier -eq 'Hyperscale') {
            $storage = 'SQL Database SingleDB Hyperscale - Storage'
        } elseif ($null -ne $Candidate.MaxLogGB -and $Candidate.MaxLogGB -gt 0) {
            $storageAmount = [math]::Ceiling([math]::Max($storageAmount, [decimal]$Recommendation.LogGB * $Candidate.MaxDataGB / $Candidate.MaxLogGB))
        }
        $specifiedStorage = Get-SsaValue $Recommendation 'ReservedStorageGB'
        if ($null -ne $specifiedStorage) {
            if ([decimal]$specifiedStorage -lt $storageAmount -or ($Candidate.Target -eq 'ManagedInstance' -and [decimal]$specifiedStorage % 32 -ne 0)) {
                $parts.Add((New-SsaUnpricedComponent Storage 'ReservedStorageGB is below required storage or is not an MI 32-GiB increment.'))
            } else { $storageAmount = [decimal]$specifiedStorage }
        }
        if ($storageAmount -gt $storageLimit) { $parts.Add((New-SsaUnpricedComponent Capacity 'Reserved storage exceeds the tier/hardware/core or selected-region limit.')) }
        if ($Candidate.Target -eq 'ManagedInstance') {
            $extraMemory = [decimal](Get-SsaValue $Candidate 'AdditionalMemoryGB' 0)
            if ($extraMemory -gt 0) {
                $sku = 'Addl Memory'; $memoryArm = 'Addl Memory'
                if ($Candidate.ServiceTier -eq 'BusinessCritical') { $sku = 'Addl Mm'; $memoryArm = 'Additional Memory' }
                $parts.Add((New-SsaMeterComponent AdditionalMemory $service $compute $sku ($sku + ' Additional Memory') '1 GB/Hour' $memoryArm $Region $extraMemory GBHour))
            }
            if ($Candidate.ServiceTier -eq 'NextGenGeneralPurpose') {
                $included = [math]::Min([decimal]$Candidate.MaxIops, [math]::Max([decimal]300, 3 * $storageAmount))
                $provisioned = Get-SsaValue $Recommendation 'ProvisionedIops'
                $number = [decimal]0
                if ($null -eq $provisioned -or -not [decimal]::TryParse([string]$provisioned, [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$number) -or
                    $number % 1 -ne 0 -or $number -lt $included -or $number -gt $Candidate.MaxIops) {
                    $parts.Add((New-SsaUnpricedComponent AdditionalIops 'Next-gen MI requires an integer ProvisionedIops at least equal to included IOPS and no greater than the selected core-size cap. Missing IOPS is not free IOPS.'))
                } else {
                    $additional = $number - $included
                    if ($additional -gt 0) {
                        $parts.Add((New-SsaMeterComponent AdditionalIops $service $storage 'Additional IOPS' 'Additional IOPS' '1 IOPS/Month' 'Additional IOPS' $Region $additional IopsMonth))
                    }
                }
            }
        }
        if ($Candidate.Target -eq 'SqlDatabase') {
            $compute = Get-SsaValue $Candidate 'ComputeProduct'
            $arm = Get-SsaValue $Candidate 'ComputeArmSku'
            if (-not $compute -or -not $arm) {
                $parts.Add((New-SsaUnpricedComponent Compute 'The SQL Database tier/hardware has no verified exact compute-meter mapping; no Gen5 substitute is allowed.'))
                return ,$parts.ToArray()
            }
            if ($Candidate.ServiceTier -eq 'Hyperscale') { $storageAmount = [math]::Max([decimal]10, $storageAmount) }
            else { $storageAmount *= [decimal]'1.3' }
        }
        $parts.Add((New-SsaMeterComponent Compute $service $compute 'vCore' 'vCore' '1 Hour' $arm $Region $Candidate.VCores Hour))
        if (-not $sqlAhb -and $Candidate.ServiceTier -ne 'Hyperscale') { $parts.Add((New-SsaMeterComponent SqlLicense $service $license 'vCore' 'vCore' '1 Hour' '' 'Global' $Candidate.VCores Hour)) }
        $parts.Add((New-SsaMeterComponent Storage $service $storage $storageSku $storageMeter '1 GB/Month' '' $Region $storageAmount GBMonth))
    } else {
        if (@($Candidate.SupportedEditions) -cnotcontains [string](Get-SsaValue $Recommendation 'SqlEdition') -or
            @($Candidate.SqlMajorVersions) -notcontains (Get-SsaValue $Recommendation 'SqlMajorVersion')) {
            $parts.Add((New-SsaUnpricedComponent SqlConfiguration 'Select an explicitly supported SQL edition and major version; no automatic upgrade or downgrade is priced.'))
            return ,$parts.ToArray()
        }
        $product = Get-SsaValue $Candidate 'ComputeProduct'
        $vmSku = Get-SsaValue $Candidate 'ComputeSku'
        $vmMeter = Get-SsaValue $Candidate 'ComputeMeter'
        $arm = Get-SsaValue $Candidate 'ComputeArmSku'
        $component = 'Compute'
        if (-not $windowsAhb) { $product = Get-SsaValue $Candidate 'WindowsProduct'; $component = 'ComputeAndWindows' }
        if (-not $product -or -not $vmSku -or -not $vmMeter -or -not $arm) {
            $parts.Add((New-SsaUnpricedComponent Compute 'The VM has no verified exact product/SKU/meter/ARM mapping; no older generation, parent, or alternate-family rate is substituted.'))
            return ,$parts.ToArray()
        }
        $parts.Add((New-SsaMeterComponent $component 'Virtual Machines' $product $vmSku $vmMeter '1 Hour' $arm $Region 1 Hour))
        if (-not $sqlAhb) {
            $parts.Add((New-SsaMeterComponent SqlLicense 'Virtual Machines Licenses' ('SQL Server ' + $Recommendation.SqlEdition) '1 vCore' '1 vCore License' '1 Hour' '' '' ([Math]::Max(4,$Candidate.VCores)) Hour))
        }
        $layout = @(Get-SsaValue $Recommendation 'DiskLayout' @())
        $capacities = @{ OS = [decimal]0; Data = [decimal]0; Log = [decimal]0; Tempdb = [decimal]0 }
        $counts = @{ OS = 0; Data = 0; Log = 0; Tempdb = 0 }
        $diskType = Get-SsaValue $Recommendation 'DiskType' 'PremiumSSD'
        foreach ($entry in $layout) {
            $id = [string](Get-SsaValue $entry 'DiskId')
            $role = [string](Get-SsaValue $entry 'Role' (Get-SsaValue $entry 'Purpose'))
            $disk = @($Catalog.Disks | Where-Object { $_.Id -ceq $id })
            $profiles = @(Get-SsaValue $Catalog 'DiskProfiles' @() | Where-Object { $_.Id -ceq $id -and $_.Configurable })
            $count = [decimal]0
            if (($disk.Count + $profiles.Count) -ne 1 -or -not $capacities.ContainsKey($role) -or
                -not [decimal]::TryParse([string](Get-SsaValue $entry 'Count'), [ref]$count) -or $count -lt 1 -or $count % 1 -ne 0 -or
                (Get-SsaValue $entry 'BurstingEnabled' $false) -or (Get-SsaValue $entry 'PerformancePlus' $false) -or (Get-SsaValue $entry 'Shared' $false)) {
                $parts.Add((New-SsaUnpricedComponent DiskLayout 'Each disk requires a catalog DiskId, OS/Data/Log/Tempdb Role, positive integer Count, and base nonshared/nonburst performance.'))
                continue
            }
            if ($profiles.Count) {
                $profile = $profiles[0]
                try {
                    if ($diskType -ne $profile.Id -or -not (Get-SsaValue $Candidate 'MaxAdvancedIops') -or -not (Get-SsaValue $Candidate 'MaxAdvancedThroughputMBps')) { throw 'Disk type must match an explicit recommendation profile and a documented advanced VM storage envelope.' }
                    Assert-SsaConfigurableDisk $entry $profile $Region
                    $capacity = [decimal]$entry.SizeGB
                    if ($id -eq 'UltraSSD') { $capacity = @($profile.BillingSizesGB | Where-Object { $_ -ge $entry.SizeGB })[0] }
                    if ($null -ne (Get-SsaValue $entry 'BilledSizeGB') -and $entry.BilledSizeGB -ne $capacity) { throw 'Billed disk capacity does not match the documented billing policy.' }
                    $capacities[$role] += [decimal]$entry.SizeGB*$count
                    $counts[$role] += $count
                    $parts.Add((New-SsaMeterComponent ($role+'DiskCapacity') Storage $profile.Product $profile.Sku ($profile.MeterPrefix+' Provisioned Capacity') '1 GiB/Hour' '' $Region ($capacity*$count) ProvisionedMonth -RequireEmptyArmSku $true))
                    $extraIops = [math]::Max(0,$entry.Iops-$profile.IncludedIops)*$count
                    $extraThroughput = [math]::Max(0,$entry.ThroughputMBps-$profile.IncludedThroughputMBps)*$count
                    if ($extraIops -gt 0) {
                        $parts.Add((New-SsaMeterComponent ($role+'DiskIops') Storage $profile.Product $profile.Sku ($profile.MeterPrefix+' Provisioned IOPS') '1/Hour' '' $Region $extraIops ProvisionedMonth -TierMinimumUnits $profile.IncludedIops -RequireEmptyArmSku $true))
                    }
                    if ($extraThroughput -gt 0) {
                        $parts.Add((New-SsaMeterComponent ($role+'DiskThroughput') Storage $profile.Product $profile.Sku ($profile.MeterPrefix+' Provisioned Throughput (MBps)') '1/Hour' '' $Region $extraThroughput ProvisionedMonth -TierMinimumUnits $profile.IncludedThroughputMBps -RequireEmptyArmSku $true))
                    }
                } catch { $parts.Add((New-SsaUnpricedComponent DiskLayout $_.Exception.Message)) }
                continue
            }
            if ($role -ne 'OS' -and $diskType -ne 'PremiumSSD') {
                $parts.Add((New-SsaUnpricedComponent DiskLayout 'All non-OS roles must match the recommendation disk type.'))
                continue
            }
            $specifiedSize = Get-SsaValue $entry 'SizeGB'
            if ($null -ne $specifiedSize -and [decimal]$specifiedSize -ne [decimal]$disk[0].SizeGB) {
                $parts.Add((New-SsaUnpricedComponent DiskLayout 'DiskLayout SizeGB does not match the catalog disk tier.'))
                continue
            }
            $capacities[$role] += $disk[0].SizeGB * $count
            $counts[$role] += $count
            $sku = $disk[0].Tier + ' LRS'
            $parts.Add((New-SsaMeterComponent ($role + 'Disk') Storage 'Premium SSD Managed Disks' $sku ($sku + ' Disk') '1/Month' '' $Region $count Month))
        }
        if ($counts.OS -ne 1 -or $capacities.OS -lt 128 -or $counts.Data -lt 1 -or $counts.Log -lt 1 -or
            $capacities.Data -lt [decimal]$Recommendation.DataGB -or $capacities.Log -lt [decimal]$Recommendation.LogGB -or
            ($counts.Data + $counts.Log + $counts.Tempdb) -gt $Candidate.MaxDataDisks) {
            $parts.Add((New-SsaUnpricedComponent DiskLayout 'A feasible explicit OS (one disk >=128 GiB), data, and log disk layout is mandatory; capacity and VM data-disk count limits must be met.'))
        }
        if (($capacities.Tempdb -gt 0 -and $capacities.Tempdb -lt [decimal]$Recommendation.TempdbGB) -or
            ($capacities.Tempdb -eq 0 -and [decimal]$Recommendation.TempdbGB -gt $Candidate.LocalTempGB)) {
            $parts.Add((New-SsaUnpricedComponent Tempdb 'Tempdb exceeds available local temporary capacity and no sufficient managed tempdb disk is specified.'))
        }
    }
    return ,$parts.ToArray()
}
