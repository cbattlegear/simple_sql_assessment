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
        $bundle.ClientSnapshot.Status | Should -Be Unavailable
        (Get-Content -Raw (Join-Path $script:collection 'inventory.json') | ConvertFrom-Json).ClientSnapshot.Status | Should -Be Unavailable
    }
    It 'retains inaccessible catalogs as explicit evidence errors and diagnostics' {
        Mock Invoke-SsaQuery -ModuleName SimpleSqlAssessment -ParameterFilter { $Query -like '*sys.cryptographic_providers*' } { throw 'Fixture permission denied.' }
        $bundle = New-SsaCollection -SqlInstance 'fixture-endpoint' -CollectionPath $script:collection
        @($bundle.Evidence | Where-Object { $_.Kind -eq 'Providers' -and $_.Status -eq 'Error' }).Count | Should -Be 1
        @($bundle.Diagnostics | Where-Object Kind -EQ Providers).Count | Should -Be 1
        Test-Path (Join-Path $script:collection 'inventory.json') | Should -BeTrue
    }
    It 'persists a successful client snapshot independently of catalog evidence visibility' {
        Mock Invoke-SsaQuery -ModuleName SimpleSqlAssessment -ParameterFilter { $Query -like '*AS CanViewClients;' } { [pscustomobject]@{ CanViewClients = 1 } }
        Mock Invoke-SsaQuery -ModuleName SimpleSqlAssessment -ParameterFilter { $Query -like '*sys.dm_exec_sessions*' } {
            [pscustomobject]@{ SessionId = 51; ClientAddress = '192.0.2.10'; HostName = 'APP01' }
        }
        $bundle = New-SsaCollection -SqlInstance 'fixture-endpoint' -CollectionPath $script:collection
        $bundle.ClientSnapshot.Status | Should -Be Collected
        $saved = Get-Content -Raw (Join-Path $script:collection 'inventory.json') | ConvertFrom-Json
        $saved.ClientSnapshot.Rows[0].HostName | Should -Be APP01
    }
    It 'restricts evidence access without Set-Acl or audit/owner privilege requirements' {
        Mock Set-Acl -ModuleName SimpleSqlAssessment { throw "The process does not possess the 'SeSecurityPrivilege' privilege." }
        $null = [IO.Directory]::CreateDirectory($script:collection)
        $owner = (Get-Acl -LiteralPath $script:collection).Owner
        $null = New-SsaCollection -SqlInstance 'fixture-endpoint' -CollectionPath $script:collection
        $acl = Get-Acl -LiteralPath $script:collection
        $acl.Owner | Should -Be $owner
        $acl.AreAccessRulesProtected | Should -BeTrue
        $rules = @($acl.GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier]))
        $rules.Count | Should -Be 1
        $rules[0].IdentityReference.Value | Should -Be ([Security.Principal.WindowsIdentity]::GetCurrent().User.Value)
        $rules[0].FileSystemRights | Should -Be ([Security.AccessControl.FileSystemRights]::FullControl)
        $rules[0].AccessControlType | Should -Be ([Security.AccessControl.AccessControlType]::Allow)
        $rules[0].InheritanceFlags | Should -Be ([Security.AccessControl.InheritanceFlags]'ContainerInherit,ObjectInherit')
        $rules[0].IsInherited | Should -BeFalse
        $fileAcl = Get-Acl -LiteralPath (Join-Path $script:collection 'inventory.json')
        $fileRules = @($fileAcl.GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier]))
        $fileRules.Count | Should -Be 1
        $fileRules[0].IdentityReference.Value | Should -Be $rules[0].IdentityReference.Value
        Should -Invoke Set-Acl -ModuleName SimpleSqlAssessment -Times 0 -Exactly
    }
    It 'resolves a relative collection under the PowerShell location, not the process directory' {
        $parent = Join-Path $TestDrive 'relative collection (1)'
        $null = [IO.Directory]::CreateDirectory($parent)
        $processDirectory = [Environment]::CurrentDirectory
        Push-Location -LiteralPath $parent
        try {
            $null = New-SsaCollection -SqlInstance 'fixture-endpoint' -CollectionPath '.\collection'
            Test-Path -LiteralPath (Join-Path $parent 'collection\inventory.json') | Should -BeTrue
            [Environment]::CurrentDirectory | Should -Be $processDirectory
        } finally { Pop-Location }
    }
    It 'stops before SQL access or evidence writes if directory protection fails' {
        Mock Set-SsaCollectionDirectoryAccess -ModuleName SimpleSqlAssessment { throw 'Fixture DACL persistence failed.' }
        { New-SsaCollection -SqlInstance 'fixture-endpoint' -CollectionPath $script:collection } | Should -Throw '*DACL persistence failed*'
        Test-Path -LiteralPath (Join-Path $script:collection 'inventory.json') | Should -BeFalse
        Test-Path -LiteralPath (Join-Path $script:collection 'manifest.json') | Should -BeFalse
        Should -Invoke New-SsaSqlConnection -ModuleName SimpleSqlAssessment -Times 0 -Exactly
    }
    It 'terminates on source failure instead of writing incomplete evidence under Continue preference' {
        Mock Get-SsaSource -ModuleName SimpleSqlAssessment { throw 'Fixture certificate-chain failure.' }
        $failure = $null
        $original = $ErrorActionPreference
        try {
            $ErrorActionPreference = 'Continue'
            try { $null = New-SsaCollection -SqlInstance 'fixture-endpoint' -CollectionPath $script:collection }
            catch { $failure = $_ }
        } finally { $ErrorActionPreference = $original }
        $failure | Should -Not -BeNullOrEmpty
        $failure.ToString() | Should -Match 'certificate-chain failure'
        Test-Path -LiteralPath (Join-Path $script:collection 'inventory.json') | Should -BeFalse
        Should -Invoke Get-SsaServerVisibility -ModuleName SimpleSqlAssessment -Times 0 -Exactly
    }
    It 'refuses nonempty collection directories without changing their contents' {
        $null = [IO.Directory]::CreateDirectory($script:collection)
        $marker = Join-Path $script:collection 'existing.txt'
        [IO.File]::WriteAllText($marker,'preserve')
        $before = (Get-Acl -LiteralPath $script:collection).Sddl
        { New-SsaCollection -SqlInstance 'fixture-endpoint' -CollectionPath $script:collection } | Should -Throw '*new or empty*'
        [IO.File]::ReadAllText($marker) | Should -Be preserve
        (Get-Acl -LiteralPath $script:collection).Sddl | Should -Be $before
        Should -Invoke New-SsaSqlConnection -ModuleName SimpleSqlAssessment -Times 0 -Exactly
    }
}
