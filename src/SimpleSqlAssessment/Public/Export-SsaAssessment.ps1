function Export-SsaAssessment {
    <#
    .SYNOPSIS
    Exports a normalized assessment as a standalone HTML snapshot, JSON, and eight CSV tables.
    .DESCRIPTION
    OutputPath is a directory. All formats are written on each call, without network access.
    SQL definitions, job-step commands, credentials, and raw samples are excluded. Other
    structured values are retained in JSON; spreadsheet-sensitive CSV strings are prefixed
    with an apostrophe. Exports still contain sensitive source and object identifiers.
    Large HTML chart series are downsampled with extrema and gap boundaries retained;
    JSON retains the supplied normalized series. Optional Inventory is a database array
    with Id, Name, State, CompatibilityLevel, DataMB, and LogMB fields.
    Existing files are replaced atomically per file, not as a cross-file transaction.
    .OUTPUTS
    PSCustomObject with OutputPath, HtmlPath, JsonPath, CsvPath, and CsvFiles properties.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, ValueFromPipeline)][ValidateNotNull()]$Assessment,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$OutputPath
    )
    process {
        $directory = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutputPath)
        $csvDirectory = Join-Path $directory 'csv'
        $result = ConvertTo-SsaReportValue -Value $Assessment
        if ($null -eq $result -or $result -isnot [pscustomobject]) { throw 'Assessment must be a structured result object.' }
        $html = New-SsaReportHtml -Assessment $result
        $htmlPath = Join-Path $directory 'assessment.html'
        $jsonPath = Join-Path $directory 'assessment.json'
        [void][IO.Directory]::CreateDirectory($csvDirectory)

        Write-SsaReportJson -Path $jsonPath -Value $result
        $files = [ordered]@{}
        $tables = @(
            @{ Name = 'target-summary'; Property = 'Targets'; Columns = @('Target', 'Compatibility', 'BlockerCount', 'WarningCount', 'ReviewCount', 'SizingStatus', 'MonthlyPayg', 'MonthlyAhb') },
            @{ Name = 'findings'; Property = 'Findings'; Columns = @('Target', 'RuleId', 'Category', 'PublishedCategory', 'Scope', 'Database', 'Object', 'Line', 'Message', 'Remediation', 'SourceUrl') },
            @{ Name = 'rule-coverage'; Property = 'RuleEvaluations'; Columns = @('Target', 'RuleId', 'Database', 'Status', 'Category', 'Message', 'SourceUrl') },
            @{ Name = 'recommendations'; Property = 'Recommendations'; Columns = @('RecommendationId', 'CatalogId', 'Target', 'Database', 'Status', 'DiskType', 'StorageAssessment', 'ServiceTier', 'Hardware', 'VCores', 'MemoryGB', 'DataGB', 'LogGB', 'TempdbGB', 'ReservedStorageGB', 'ProvisionedIops', 'IncludedIops', 'AdditionalIops', 'AdditionalMemoryGB', 'TempdbPlacement', 'VmSize', 'BaseVmSize', 'BaseVCores', 'VmGeneration', 'VmPreview', 'LocalTempDisks', 'LocalTempDiskGB', 'LocalTempGB', 'LocalTempDiskType', 'RemoteDiskController', 'SqlEdition', 'SqlMajorVersion', 'Reason', 'Confidence', 'Constraints', 'PriceComponents', 'DiskLayout') }
        )
        foreach ($table in $tables) {
            $path = Join-Path $csvDirectory ($table.Name + '.csv')
            Write-SsaReportCsv -Path $path -Rows @(Get-SsaValue -Object $result -Name $table.Property -Default @()) -Columns $table.Columns
            $files[$table.Name] = $path
        }
        $path = Join-Path $csvDirectory 'cost-components.csv'
        Write-SsaReportCsv -Path $path -Rows @(Get-SsaCostComponentRows -Assessment $result) -Columns @('RecommendationId', 'Target', 'Database', 'Scenario', 'Status', 'TotalMonthly', 'Currency', 'Region', 'HoursPerMonth', 'Component', 'MeterId', 'Quantity', 'Unit', 'Rate', 'TierMinimumUnits', 'MonthlyCost', 'EffectiveStartDate', 'RetrievedAt', 'Errors')
        $files['cost-components'] = $path
        $path = Join-Path $csvDirectory 'disk-alternatives.csv'
        Write-SsaReportCsv -Path $path -Rows @(Get-SsaValue $result 'Prices' @() | Where-Object { Get-SsaValue $_ 'DiskType' }) -Columns @('RecommendationId','CatalogId','DiskType','Scenario','Status','TotalMonthly','Currency','IsSuggested','SuggestionReason','StorageHoursPerMonth','DiskBillingPolicy')
        $files['disk-alternatives'] = $path
        $path = Join-Path $csvDirectory 'client-dependencies.csv'
        $clients = Get-SsaValue -Object $result -Name ClientDependencies
        Write-SsaReportCsv -Path $path -Rows @(Get-SsaValue $clients 'Clients' @()) -Columns @('Location','ClientAddress','HostName','ProgramName','ClientInterfaceName','LoginName','Databases','Transports','AuthenticationSchemes','EncryptionStates','FirstObservedAt','LastObservedAt','SamplesSeen','PeakSessions')
        $files['client-dependencies'] = $path
        $path = Join-Path $csvDirectory 'performance-summary.csv'
        $performance = Get-SsaValue -Object $result -Name Performance
        Write-SsaReportCsv -Path $path -Rows @(Get-SsaValue -Object $performance -Name Summary -Default @()) -Columns @('Metric', 'Database', 'P95', 'Peak', 'Unit')
        $files['performance-summary'] = $path
        # Publish the browser snapshot last, so failed preparation leaves the old HTML intact.
        Write-SsaReportText -Path $htmlPath -Text $html
        [pscustomobject][ordered]@{
            OutputPath = $directory
            HtmlPath = $htmlPath
            JsonPath = $jsonPath
            CsvPath = $csvDirectory
            CsvFiles = [pscustomobject]$files
        }
    }
}
