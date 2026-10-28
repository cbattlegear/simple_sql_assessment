function Update-SsaTargetSummary {
    param($Assessment)
    $summaries = @()
    foreach ($target in @('SqlDatabase','ManagedInstance','SqlVm')) {
        $findings = @($Assessment.Findings | Where-Object { $_.Target -eq $target })
        $blockers = @($findings | Where-Object { $_.Category -eq 'Issue' }).Count
        $warnings = @($findings | Where-Object { $_.Category -eq 'Warning' }).Count
        $reviews = @($Assessment.RuleEvaluations | Where-Object { $_.Target -eq $target -and $_.Status -in @('NeedsReview','Error') }).Count
        $compatibility = 'Ready'
        if ($blockers) { $compatibility = 'NotReady' }
        elseif ($reviews) { $compatibility = 'Unknown' }
        elseif ($warnings) { $compatibility = 'ReadyWithWarnings' }
        $recommendations = @($Assessment.Recommendations | Where-Object { $_.Target -eq $target })
        $sizing = $Assessment.Performance.State
        if ($recommendations.Count) {
            $sizing = 'Provisional'
            foreach ($scope in @($recommendations | Group-Object Database)) {
                if (-not @($scope.Group | Where-Object Status -NE Unavailable).Count) { $sizing = 'Unavailable' }
            }
        }
        $totals = @{}
        foreach ($scenario in @('Payg','Ahb')) {
            $total = 0.0; $complete = $recommendations.Count -gt 0
            foreach ($group in @($recommendations | Group-Object Database)) {
                $ids = @($group.Group | ForEach-Object { $_.RecommendationId })
                $quotes = @($Assessment.Prices | Where-Object { $_.RecommendationId -in $ids -and $_.Scenario -eq $scenario -and $_.Status -eq 'Complete' -and $null -ne $_.TotalMonthly } | Sort-Object TotalMonthly)
                if (-not $quotes.Count) { $complete = $false; break }
                $total += $quotes[0].TotalMonthly
            }
            $totals[$scenario] = $null
            if ($complete) { $totals[$scenario] = [Math]::Round($total,2) }
        }
        $summaries += [pscustomobject]@{ Target = $target; Compatibility = $compatibility; BlockerCount = $blockers; WarningCount = $warnings; ReviewCount = $reviews; SizingStatus = $sizing; MonthlyPayg = $totals.Payg; MonthlyAhb = $totals.Ahb }
    }
    $Assessment.Targets = $summaries
}

function Invoke-SsaAssessment {
    [CmdletBinding(DefaultParameterSetName = 'Live')]
    param(
        [Parameter(Mandatory,ParameterSetName='Live')][string]$SqlInstance,
        [Parameter(Mandatory,ParameterSetName='Bundle')][string]$CollectionPath,
        [Parameter(Mandatory)][string]$OutputPath,
        [Parameter(Mandatory)][ValidatePattern('^[a-z0-9]+$')][string]$Region,
        [ValidatePattern('^[A-Z]{3}$')][string]$Currency = 'USD',
        [ValidateRange(1,8784)][double]$HoursPerMonth = 730,
        [pscredential]$Credential, [switch]$TrustServerCertificate,
        [switch]$SkipPerformance, [switch]$Offline,
        [timespan]$Duration = ([timespan]::FromDays(7)),
        [ValidateRange(1,3600)][double]$SampleIntervalSeconds = 30,
        [ValidateRange(1,100)][double]$Percentile = 95,
        [ValidateRange(0,500)][double]$HeadroomPercent = 20,
        [ValidateRange(0,500)][double]$StorageGrowthPercent = 20,
        [int]$TargetSqlMajorVersion = 0,
        [ValidateSet('Standard','Enterprise')][string]$TargetSqlEdition,
        [switch]$IncludePreviewVm,
        [switch]$SqlHybridBenefit, [switch]$WindowsHybridBenefit,
        [switch]$AllowStaleCache
    )
    if ($Offline -and $PSCmdlet.ParameterSetName -eq 'Live') { throw '-Offline requires a local -CollectionPath, not a live SQL instance.' }
    $OutputPath = [IO.Path]::GetFullPath($OutputPath)
    if ($PSCmdlet.ParameterSetName -eq 'Live') {
        $CollectionPath = Join-Path $OutputPath 'collection'
        $bundle = New-SsaCollection -SqlInstance $SqlInstance -CollectionPath $CollectionPath -Credential $Credential -TrustServerCertificate:$TrustServerCertificate
    } else { $bundle = Read-SsaBundle $CollectionPath }
    $result = New-SsaResult $bundle $Region $Currency $HoursPerMonth
    $result.Configuration | Add-Member NoteProperty Percentile $Percentile
    $result.Configuration | Add-Member NoteProperty HeadroomPercent $HeadroomPercent
    $result.Configuration | Add-Member NoteProperty StorageGrowthPercent $StorageGrowthPercent
    $result.Configuration | Add-Member NoteProperty SqlHybridBenefit ([bool]$SqlHybridBenefit)
    $result.Configuration | Add-Member NoteProperty WindowsHybridBenefit ([bool]$WindowsHybridBenefit)
    $result.Configuration | Add-Member NoteProperty TargetSqlMajorVersion $TargetSqlMajorVersion
    $result.Configuration | Add-Member NoteProperty TargetSqlEdition $TargetSqlEdition
    $result.Configuration | Add-Member NoteProperty IncludePreviewVm ([bool]$IncludePreviewVm)
    $rules = Invoke-SsaRules $bundle $TargetSqlMajorVersion $TargetSqlEdition
    $result.Findings = $rules.Findings; $result.RuleEvaluations = $rules.Evaluations
    if ($SkipPerformance) { $result.Performance.State = 'Skipped' }
    elseif ($PSCmdlet.ParameterSetName -eq 'Live') { $result.Performance.State = 'Pending' }
    Update-SsaTargetSummary $result
    $null = Export-SsaAssessment -Assessment $result -OutputPath $OutputPath
    if ($PSCmdlet.ParameterSetName -eq 'Live' -and -not $SkipPerformance) {
        Write-Information "Static assessment is available at $(Join-Path $OutputPath 'assessment.html'). Performance capture now requires Windows counters; interruption is resumable." -InformationAction Continue
        try {
            $null = Start-SsaPerformanceCapture -CollectionPath $CollectionPath -Duration $Duration -SampleIntervalSeconds $SampleIntervalSeconds -Credential $Credential -TrustServerCertificate:$TrustServerCertificate
        } catch {
            $result.Performance.State = 'FailedResumable'
            $result.ClientDependencies = Get-SsaClientDependencies $bundle $CollectionPath
            $result.Diagnostics += [pscustomobject]@{ Code = 'CaptureFailed'; Message = 'Performance collection failed; retain static results and use Resume-SsaPerformanceCapture after fixing SQL/Windows access.' }
            Update-SsaTargetSummary $result
            $null = Export-SsaAssessment -Assessment $result -OutputPath $OutputPath
            throw
        }
    }
    if (-not $SkipPerformance) {
        $performance = Get-SsaPerformanceAnalysis $CollectionPath $bundle $Percentile
        $result.ClientDependencies = $performance.ClientDependencies
        $publicPerformance = [ordered]@{}
        foreach ($property in $performance.PSObject.Properties) { if ($property.Name -notin @('Samples','ClientDependencies')) { $publicPerformance[$property.Name] = $property.Value } }
        $result.Performance = [pscustomobject]$publicPerformance
        $sizing = @{ CollectionPath = $CollectionPath; Percentile = $Percentile; HeadroomPercent = $HeadroomPercent; StorageGrowthPercent = $StorageGrowthPercent; TargetSqlMajorVersion = $TargetSqlMajorVersion; Region = $Region; IncludePreviewVm = $IncludePreviewVm }
        if ($TargetSqlEdition) { $sizing.TargetSqlEdition = $TargetSqlEdition }
        $result.Recommendations = @(Get-SsaSkuRecommendation @sizing)
        $priceable = @($result.Recommendations | Where-Object { $_.Status -ne 'Unavailable' })
        if ($priceable.Count) {
            $pricing = @{ Recommendation = $priceable; Region = $Region; Currency = $Currency; HoursPerMonth = $HoursPerMonth; SqlHybridBenefit = $SqlHybridBenefit; WindowsHybridBenefit = $WindowsHybridBenefit; CachePath = (Join-Path $OutputPath 'pricing-cache'); Offline = $Offline; AllowStaleCache = $AllowStaleCache }
            $result.Prices = @(Get-SsaPriceEstimate @pricing)
        }
    }
    $result.GeneratedAt = (Get-SsaUtcNow).ToString('o')
    Update-SsaTargetSummary $result
    $paths = Export-SsaAssessment -Assessment $result -OutputPath $OutputPath
    Write-Information ($result.Targets | Format-Table Target,Compatibility,SizingStatus,MonthlyPayg,MonthlyAhb -AutoSize | Out-String) -InformationAction Continue
    Write-Information "Report: $(Join-Path $OutputPath 'assessment.html')" -InformationAction Continue
    $result | Add-Member NoteProperty OutputFiles $paths
    return $result
}
