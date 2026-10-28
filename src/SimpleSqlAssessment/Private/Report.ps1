function ConvertTo-SsaReportValue {
    param($Value, [int]$Depth = 0)
    if ($Depth -gt 50) { throw 'Assessment exceeds the supported report nesting depth (50).' }
    if ($null -eq $Value) { return $null }
    if ($Value -is [string] -or $Value -is [ValueType]) { return $Value }
    if ($Value -is [System.Collections.IDictionary] -or $Value -is [pscustomobject]) {
        $safe = [ordered]@{}
        $names = @()
        if ($Value -is [System.Collections.IDictionary]) { $names = @($Value.Keys) }
        else { $names = @($Value.PSObject.Properties | ForEach-Object { $_.Name }) }
        foreach ($name in $names) {
            # Presentation exports are not a collection bundle; never copy executable SQL or secrets.
            if ([string]$name -match '^(Definitions?|DefinitionText|Module(Definitions?|Text)|Sql(Definitions?|Text)|QueryText|Command(Text)?|JobSteps?|JobStep(Text|Command)|StepCommand|Credentials?|Passwords?|AccessToken|ConnectionString|RawSamples)$') { continue }
            $child = $null
            if ($Value -is [System.Collections.IDictionary]) { $child = $Value[$name] }
            else { $child = $Value.PSObject.Properties[$name].Value }
            $safe[[string]$name] = ConvertTo-SsaReportValue -Value $child -Depth ($Depth + 1)
        }
        return [pscustomobject]$safe
    }
    if ($Value -is [System.Collections.IEnumerable]) {
        $items = New-Object 'System.Collections.Generic.List[object]'
        foreach ($item in $Value) { $items.Add((ConvertTo-SsaReportValue -Value $item -Depth ($Depth + 1))) }
        return ,$items.ToArray()
    }
    return [string]$Value
}

function Publish-SsaReportFile {
    param([string]$PendingPath, [string]$Path)
    if ([IO.File]::Exists($Path)) { [IO.File]::Replace($PendingPath, $Path, [System.Management.Automation.Language.NullString]::Value) }
    else { [IO.File]::Move($PendingPath, $Path) }
}

function Write-SsaReportJson {
    param([string]$Path, $Value)
    $pendingPath = $Path + '.' + [guid]::NewGuid().ToString('N') + '.tmp'
    try {
        Write-SsaJson -Path $pendingPath -Value $Value
        Publish-SsaReportFile -PendingPath $pendingPath -Path $Path
    } finally {
        if ([IO.File]::Exists($pendingPath)) { [IO.File]::Delete($pendingPath) }
    }
}

function Write-SsaReportText {
    param([Parameter(Mandatory)][string]$Path, [AllowEmptyString()][string]$Text)
    $fullPath = [IO.Path]::GetFullPath($Path)
    [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($fullPath))
    $pendingPath = $fullPath + '.' + [guid]::NewGuid().ToString('N') + '.tmp'
    try {
        [IO.File]::WriteAllText($pendingPath, $Text, (New-Object Text.UTF8Encoding($false)))
        Publish-SsaReportFile -PendingPath $pendingPath -Path $fullPath
    } finally {
        if ([IO.File]::Exists($pendingPath)) { [IO.File]::Delete($pendingPath) }
    }
}

function ConvertTo-SsaCsvCell {
    param($Value)
    if ($null -eq $Value) { return '' }
    if ($Value -is [string]) {
        # Protect formulas even when hidden behind whitespace or control characters.
        if ($Value -match '^[\s\p{Cc}\p{Cf}]*[=+\-@]' -or $Value -match '^[\t\r\n]') { return "'" + $Value }
        return $Value
    }
    if ($Value -is [ValueType]) { return [Convert]::ToString($Value, [Globalization.CultureInfo]::InvariantCulture) }
    $text = ConvertTo-Json -InputObject $Value -Depth 60 -Compress
    return $text
}

function Write-SsaReportCsv {
    param([string]$Path, [object[]]$Rows, [string[]]$Columns)
    $lines = New-Object 'System.Collections.Generic.List[string]'
    $lines.Add((($Columns | ForEach-Object { '"' + $_.Replace('"', '""') + '"' }) -join ','))
    foreach ($row in $Rows) {
        if ($null -eq $row) { continue }
        $cells = foreach ($column in $Columns) {
            $cellValue = $null
            if ($row -is [System.Collections.IDictionary]) { $cellValue = $row[$column] }
            elseif ($null -ne $row.PSObject.Properties[$column]) { $cellValue = $row.PSObject.Properties[$column].Value }
            $cell = [string](ConvertTo-SsaCsvCell -Value $cellValue)
            '"' + $cell.Replace('"', '""') + '"'
        }
        $lines.Add(($cells -join ','))
    }
    Write-SsaReportText -Path $Path -Text (($lines -join "`r`n") + "`r`n")
}

function Get-SsaCostComponentRows {
    param($Assessment)
    $recommendations = @(Get-SsaValue -Object $Assessment -Name Recommendations -Default @())
    foreach ($quote in @(Get-SsaValue -Object $Assessment -Name Prices -Default @())) {
        if ($null -eq $quote) { continue }
        $id = Get-SsaValue -Object $quote -Name RecommendationId
        $recommendation = $recommendations | Where-Object { (Get-SsaValue -Object $_ -Name RecommendationId) -eq $id } | Select-Object -First 1
        $components = @(Get-SsaValue -Object $quote -Name Components -Default @())
        # Retain unavailable/partial quotes even when they have no component rows.
        if (-not $components.Count) { $components = @($null) }
        foreach ($component in $components) {
            $row = [ordered]@{
                RecommendationId = $id
                Target = Get-SsaValue -Object $recommendation -Name Target
                Database = Get-SsaValue -Object $recommendation -Name Database
                Scenario = Get-SsaValue -Object $quote -Name Scenario
                Status = Get-SsaValue -Object $quote -Name Status
                TotalMonthly = Get-SsaValue -Object $quote -Name TotalMonthly
                Currency = Get-SsaValue -Object $quote -Name Currency
                Region = Get-SsaValue -Object $quote -Name Region
                HoursPerMonth = Get-SsaValue -Object $quote -Name HoursPerMonth
            }
            foreach ($field in @('Component', 'MeterId', 'Quantity', 'Unit', 'Rate', 'TierMinimumUnits', 'MonthlyCost', 'EffectiveStartDate', 'RetrievedAt')) {
                $row[$field] = Get-SsaValue -Object $component -Name $field
            }
            $row['Errors'] = $null
            if ($null -ne $quote.PSObject.Properties['Errors']) { $row['Errors'] = $quote.PSObject.Properties['Errors'].Value }
            [pscustomobject]$row
        }
    }
}

function Get-SsaReportHtmlModel {
    param($Assessment)
    $performance = Get-SsaValue -Object $Assessment -Name Performance
    $series = @(Get-SsaValue -Object $performance -Name Series -Default @())
    if ($series.Count -le 2000) { return $Assessment }

    $selected = New-Object 'System.Collections.Generic.HashSet[int]'
    [void]$selected.Add(0)
    [void]$selected.Add($series.Count - 1)
    $metrics = @('CpuPercent', 'MemoryGB', 'Iops', 'ThroughputMBps', 'LogMBps')
    $bucketSize = [int][Math]::Ceiling($series.Count / 100.0)
    $previousValues = @{}
    $times = New-Object 'long[]' $series.Count
    $intervals = New-Object 'System.Collections.Generic.List[double]'
    $minima = @{}
    $maxima = @{}
    for ($i = 0; $i -lt $series.Count; $i++) {
        if ($i % $bucketSize -eq 0) { $minima = @{}; $maxima = @{} }
        $time = [datetimeoffset]::MinValue
        if ([datetimeoffset]::TryParse([string](Get-SsaValue -Object $series[$i] -Name Timestamp), [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::AssumeUniversal, [ref]$time)) {
            $times[$i] = $time.UtcDateTime.Ticks
            if ($i -gt 0 -and $times[$i - 1] -gt 0 -and $times[$i] -gt $times[$i - 1]) {
                $intervals.Add(($times[$i] - $times[$i - 1]) / 10000000.0)
            }
        }
        foreach ($metric in $metrics) {
            $reading = Get-SsaValue -Object $series[$i] -Name $metric
            $valid = $null -ne $reading -and $reading -is [ValueType] -and $reading -isnot [bool]
            if ($previousValues.ContainsKey($metric) -and $previousValues[$metric] -ne $valid) {
                [void]$selected.Add($i - 1)
                [void]$selected.Add($i)
            }
            $previousValues[$metric] = $valid
            if (-not $valid) { continue }
            if (-not $minima.ContainsKey($metric) -or $reading -lt $minima[$metric].Value) { $minima[$metric] = @{ Index = $i; Value = $reading } }
            if (-not $maxima.ContainsKey($metric) -or $reading -gt $maxima[$metric].Value) { $maxima[$metric] = @{ Index = $i; Value = $reading } }
        }
        if (($i + 1) % $bucketSize -eq 0 -or $i -eq $series.Count - 1) {
            foreach ($metric in $metrics) {
                if ($minima.ContainsKey($metric)) { [void]$selected.Add($minima[$metric].Index) }
                if ($maxima.ContainsKey($metric)) { [void]$selected.Add($maxima[$metric].Index) }
            }
        }
    }
    $threshold = [double]::PositiveInfinity
    if ($intervals.Count) {
        $sortedIntervals = $intervals.ToArray()
        [Array]::Sort($sortedIntervals)
        $threshold = $sortedIntervals[[int][Math]::Floor(($sortedIntervals.Count - 1) / 2.0)] * 1.5
    }
    $sampleInterval = Get-SsaValue -Object $performance -Name SampleIntervalSeconds
    if ($sampleInterval -is [ValueType] -and $sampleInterval -gt 0) { $threshold = $sampleInterval * 1.5 }
    $gapTimes = New-Object 'System.Collections.Generic.List[object]'
    foreach ($gap in @(Get-SsaValue -Object $performance -Name Gaps -Default @())) {
        $start = [datetimeoffset]::MinValue
        $end = [datetimeoffset]::MinValue
        $startValue = Get-SsaValue -Object $gap -Name Start -Default (Get-SsaValue -Object $gap -Name StartTime -Default (Get-SsaValue -Object $gap -Name StartedAt))
        $endValue = Get-SsaValue -Object $gap -Name End -Default (Get-SsaValue -Object $gap -Name EndTime -Default (Get-SsaValue -Object $gap -Name EndedAt))
        if ([datetimeoffset]::TryParse([string]$startValue, [ref]$start) -and [datetimeoffset]::TryParse([string]$endValue, [ref]$end)) {
            $gapTimes.Add(@{ Start = $start.UtcDateTime.Ticks; End = $end.UtcDateTime.Ticks })
        }
    }
    $discontinuities = New-Object 'System.Collections.Generic.List[object]'
    for ($i = 1; $i -lt $series.Count; $i++) {
        if ($times[$i - 1] -le 0 -or $times[$i] -le 0) { continue }
        $boundary = (($times[$i] - $times[$i - 1]) / 10000000.0) -gt $threshold
        foreach ($gap in $gapTimes) {
            if ($times[$i - 1] -lt $gap.End -and $times[$i] -gt $gap.Start) { $boundary = $true; break }
        }
        if ($boundary) {
            [void]$selected.Add($i - 1)
            [void]$selected.Add($i)
            $discontinuities.Add([pscustomobject]@{
                Start = Get-SsaValue -Object $series[$i - 1] -Name Timestamp
                End = Get-SsaValue -Object $series[$i] -Name Timestamp
            })
        }
    }
    $sampled = @($selected | Sort-Object | ForEach-Object { $series[$_] })
    $htmlModel = [ordered]@{}
    foreach ($property in $Assessment.PSObject.Properties) { $htmlModel[$property.Name] = $property.Value }
    $htmlPerformance = [ordered]@{}
    foreach ($property in $performance.PSObject.Properties) { $htmlPerformance[$property.Name] = $property.Value }
    $htmlPerformance['Series'] = $sampled
    $htmlPerformance['ReportSeries'] = [pscustomobject]@{
        InputCount = $series.Count; IncludedCount = $sampled.Count
        Discontinuities = $discontinuities.ToArray()
        Method = 'Time-order buckets preserving metric extrema, missing-value transitions, and gap boundaries. JSON retains the supplied normalized series.'
    }
    $htmlModel['Performance'] = [pscustomobject]$htmlPerformance
    return [pscustomobject]$htmlModel
}

function New-SsaReportHtml {
    param($Assessment)
    $root = Join-Path $script:SsaModuleRoot 'Reports'
    $html = [IO.File]::ReadAllText((Join-Path $root 'assessment.html'))
    $css = [IO.File]::ReadAllText((Join-Path $root 'report.css'))
    $javascript = [IO.File]::ReadAllText((Join-Path $root 'report.js'))
    $json = ConvertTo-Json -InputObject (Get-SsaReportHtmlModel -Assessment $Assessment) -Depth 60 -Compress
    # A JSON script element is still parsed as raw HTML text: neutralize every tag opener.
    $json = $json.Replace('&', '\u0026').Replace('<', '\u003c').Replace('>', '\u003e').Replace([string][char]0x2028, '\u2028').Replace([string][char]0x2029, '\u2029')
    return $html.Replace('/*__SSA_STYLES__*/', $css).Replace('/*__SSA_SCRIPT__*/', $javascript).Replace('__SSA_DATA__', $json)
}
