BeforeAll {
    $root = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
    Import-Module (Join-Path $root 'src\SimpleSqlAssessment\SimpleSqlAssessment.psd1') -Force
    . (Join-Path (Split-Path $PSScriptRoot -Parent) 'TestHelpers.ps1')
    $script:module = Get-Module SimpleSqlAssessment
}
Describe 'Read-only source collection and version gates' {
    BeforeEach {
        $script:collection = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        & $script:module {param($source) $script:CollectionFixtureSource=$source} (New-TestBundle).Source
        Mock Get-SsaSource -ModuleName SimpleSqlAssessment { & (Get-Module SimpleSqlAssessment) { $script:CollectionFixtureSource } }
        Mock Get-SsaServerVisibility -ModuleName SimpleSqlAssessment { [pscustomobject]@{IsSysadmin=1;ViewDefinition=1;ViewDatabases=1;ViewLogins=1} }
        Mock New-SsaSqlConnection -ModuleName SimpleSqlAssessment { New-Object IO.MemoryStream }
        Mock Invoke-SsaQuery -ModuleName SimpleSqlAssessment {
            param($Query)
            if ($Query -like '*WHERE database_id > 4*') {
                [pscustomobject]@{Id=5;Name='App';State='ONLINE';CompatibilityLevel=110}
            } elseif ($Query -like 'SELECT HAS_PERMS_BY_NAME*') { [pscustomobject]@{ViewDefinition=1} }
            elseif ($Query -like '*AS FullVisibility;') { [pscustomobject]@{FullVisibility=1} }
            elseif ($Query -like 'SELECT file_id AS Id*') {
                [pscustomobject]@{Id=1;Name='App';Type='ROWS';SizeMB=1024}
                [pscustomobject]@{Id=2;Name='App_log';Type='LOG';SizeMB=128}
            } elseif ($Query -like '*INNER JOIN sys.sql_modules*') {
                [pscustomobject]@{Object='dbo.ReadOnly';Text='CREATE PROCEDURE dbo.ReadOnly AS SELECT 1;';Encrypted=$false}
            }
        }
    }
    It 'gates newer metadata for SQL major version <VersionMajor>' -ForEach @(
        @{VersionMajor=11},@{VersionMajor=12},@{VersionMajor=13},@{VersionMajor=14},
        @{VersionMajor=15},@{VersionMajor=16},@{VersionMajor=17}
    ) {
        & $script:module {param($major) $script:CollectionFixtureSource.VersionMajor=$major} $VersionMajor
        $bundle = New-SsaCollection -SqlInstance 'fixture-endpoint' -CollectionPath $script:collection
        $bundle.Source.VersionMajor | Should -Be $VersionMajor
        $bundle.Source.ConnectionEndpoint | Should -Be 'fixture-endpoint'
        $bundle.Databases[0].DataMB | Should -Be 1024
        $bundle.Databases[0].LogMB | Should -Be 128
        $bundle.Definitions.Count | Should -Be 1
        $expectedCalls = 1; if ($VersionMajor -lt 13) { $expectedCalls = 0 }
        Should -Invoke Invoke-SsaQuery -ModuleName SimpleSqlAssessment -Times $expectedCalls -Exactly -ParameterFilter { $Query -like '*sys.external_data_sources*' }
        @($bundle.Evidence | Where-Object { $_.Kind -eq 'ExternalDataSources' -and $_.Status -eq 'Collected' }).Count | Should -Be 1
    }
    It 'retains inaccessible catalogs as explicit evidence errors and diagnostics' {
        Mock Invoke-SsaQuery -ModuleName SimpleSqlAssessment -ParameterFilter { $Query -like '*sys.cryptographic_providers*' } { throw 'Fixture permission denied.' }
        $bundle = New-SsaCollection -SqlInstance 'fixture-endpoint' -CollectionPath $script:collection
        @($bundle.Evidence | Where-Object { $_.Kind -eq 'Providers' -and $_.Status -eq 'Error' }).Count | Should -Be 1
        @($bundle.Diagnostics | Where-Object Kind -EQ Providers).Count | Should -Be 1
        Test-Path (Join-Path $script:collection 'inventory.json') | Should -BeTrue
    }
    It 'refuses nonempty collection directories without changing their contents' {
        $null = [IO.Directory]::CreateDirectory($script:collection)
        $marker = Join-Path $script:collection 'existing.txt'
        [IO.File]::WriteAllText($marker,'preserve')
        { New-SsaCollection -SqlInstance 'fixture-endpoint' -CollectionPath $script:collection } | Should -Throw '*new or empty*'
        [IO.File]::ReadAllText($marker) | Should -Be preserve
        Should -Invoke New-SsaSqlConnection -ModuleName SimpleSqlAssessment -Times 0 -Exactly
    }
}
