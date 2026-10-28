@{
    RootModule = 'SimpleSqlAssessment.psm1'
    ModuleVersion = '0.1.0'
    GUID = 'a5317d12-59cd-4dc2-930c-fceee4e0bbf2'
    Author = 'Simple SQL Assessment contributors'
    Description = 'Read-only SQL Server migration assessment, resumable performance capture, Azure sizing and retail cost estimates.'
    PowerShellVersion = '5.1'
    CompatiblePSEditions = @('Desktop', 'Core')
    FunctionsToExport = @(
        'Test-SsaPrerequisite', 'Get-SsaAssessmentRule', 'New-SsaCollection',
        'Start-SsaPerformanceCapture', 'Resume-SsaPerformanceCapture',
        'Invoke-SsaAssessment', 'Get-SsaSkuRecommendation',
        'Get-SsaPriceEstimate', 'Export-SsaAssessment'
    )
    CmdletsToExport = @()
    VariablesToExport = @()
    AliasesToExport = @()
    PrivateData = @{ PSData = @{ Tags = @('SQLServer', 'Assessment', 'Azure', 'Migration') } }
}
