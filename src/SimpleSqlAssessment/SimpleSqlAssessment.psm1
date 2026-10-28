Set-StrictMode -Version 2.0
$script:SsaModuleRoot = $PSScriptRoot
$script:SsaVersion = '0.1.0'
foreach ($directory in @('Private', 'Public')) {
    foreach ($file in @(Get-ChildItem -LiteralPath (Join-Path $PSScriptRoot $directory) -Filter '*.ps1' -ErrorAction Stop | Sort-Object Name)) {
        . $file.FullName
    }
}
Export-ModuleMember -Function @(
    'Test-SsaPrerequisite', 'Get-SsaAssessmentRule', 'New-SsaCollection',
    'Start-SsaPerformanceCapture', 'Resume-SsaPerformanceCapture',
    'Invoke-SsaAssessment', 'Get-SsaSkuRecommendation',
    'Get-SsaPriceEstimate', 'Export-SsaAssessment'
)
