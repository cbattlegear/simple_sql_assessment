BeforeAll {
    $root = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
    Import-Module (Join-Path $root 'src\SimpleSqlAssessment\SimpleSqlAssessment.psd1') -Force
}
Describe 'Opt-in live SQL source validation' {
    It 'collects the explicitly configured source without changing SQL configuration' -Skip:([string]::IsNullOrWhiteSpace($env:SSA_TEST_SQLINSTANCE)) {
        $bundle = New-SsaCollection -SqlInstance $env:SSA_TEST_SQLINSTANCE -CollectionPath (Join-Path $TestDrive 'live')
        $bundle.Source.VersionMajor | Should -BeGreaterOrEqual 11
        $bundle.Source.Instance | Should -Not -BeNullOrEmpty
        $bundle.SchemaVersion | Should -Be '1.0'
    }
}
