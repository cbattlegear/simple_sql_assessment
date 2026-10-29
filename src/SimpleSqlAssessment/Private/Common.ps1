function Get-SsaValue {
    param($Object, [string]$Name, $Default = $null)
    if ($null -eq $Object) { return $Default }
    if ($Object -is [System.Collections.IDictionary]) {
        if ($Object.Contains($Name)) { return $Object[$Name] }
    } elseif ($null -ne $Object.PSObject.Properties[$Name]) { return $Object.$Name }
    return $Default
}

function Resolve-SsaFileSystemPath {
    param([Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Path)
    $ErrorActionPreference = 'Stop'
    $provider = $null; $drive = $null
    $resolved = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path, [ref]$provider, [ref]$drive)
    if ($provider.Name -ne 'FileSystem') { throw 'Assessment paths must use the FileSystem provider.' }
    return $resolved
}

function Write-SsaJson {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)]$Value)
    $fullPath = [IO.Path]::GetFullPath($Path)
    [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($fullPath))
    $temporary = $fullPath + '.' + [guid]::NewGuid().ToString('N') + '.tmp'
    try {
        [IO.File]::WriteAllText($temporary, (ConvertTo-Json -InputObject $Value -Depth 60), (New-Object Text.UTF8Encoding($false)))
        if ([IO.File]::Exists($fullPath)) { [IO.File]::Replace($temporary, $fullPath, [NullString]::Value) }
        else { [IO.File]::Move($temporary, $fullPath) }
    } finally {
        if ([IO.File]::Exists($temporary)) { [IO.File]::Delete($temporary) }
    }
}

function Read-SsaJson {
    param([Parameter(Mandatory)][string]$Path)
    if (-not [IO.File]::Exists($Path)) { throw "Required JSON file not found: $Path" }
    try { return ([IO.File]::ReadAllText($Path) | ConvertFrom-Json -ErrorAction Stop) }
    catch { throw "Invalid JSON in '$Path': $($_.Exception.Message)" }
}

function Read-SsaBundle {
    param([Parameter(Mandatory)][string]$CollectionPath)
    $path = Resolve-SsaFileSystemPath $CollectionPath
    if ([IO.Directory]::Exists($path)) { $path = Join-Path $path 'inventory.json' }
    $bundle = Read-SsaJson $path
    foreach ($name in @('SchemaVersion', 'CollectionId', 'CollectedAt', 'Source', 'Databases', 'Evidence', 'Definitions', 'Diagnostics')) {
        if ($null -eq $bundle.PSObject.Properties[$name]) { throw "Collection is missing required property '$name'." }
    }
    if ($bundle.SchemaVersion -ne '1.0') { throw "Unsupported collection schema '$($bundle.SchemaVersion)'." }
    if ([int]$bundle.Source.VersionMajor -lt 11) { throw 'SQL Server 2012 or later is required.' }
    return $bundle
}

function Get-SsaHash {
    param([Parameter(Mandatory)][string]$Text)
    $algorithm = [Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($algorithm.ComputeHash([Text.Encoding]::UTF8.GetBytes($Text)))).Replace('-', '').ToLowerInvariant() }
    finally { $algorithm.Dispose() }
}

function Initialize-SsaSqlLibrary {
    if ($env:OS -ne 'Windows_NT' -or -not [Environment]::Is64BitProcess) { throw 'SQL collection and parsing require Windows x64.' }
    if ($PSVersionTable.PSEdition -eq 'Core' -and $PSVersionTable.PSVersion -lt [version]'7.4') {
        throw 'The pinned SQL libraries require PowerShell 7.4 or newer on Core. Windows PowerShell 5.1 uses the separate .NET Framework assets.'
    }
    if ((Get-Variable -Name SsaSqlLibraryValidated -Scope Script -ErrorAction SilentlyContinue) -and $script:SsaSqlLibraryValidated) { return }
    $provider = @(Get-Module -ListAvailable SqlServer | Where-Object { $_.Version -eq [version]'22.4.5.1' })
    if (-not $provider.Count) {
        $root = Split-Path (Split-Path $script:SsaModuleRoot -Parent) -Parent
        foreach ($candidate in @(
            (Join-Path $root '.dependencies\SqlServer\22.4.5.1\SqlServer.psd1'),
            (Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'PowerShell\Modules\SqlServer\22.4.5.1\SqlServer.psd1')
        )) {
            if (Test-Path -LiteralPath $candidate) { $provider = @(Get-Module -ListAvailable -Name $candidate); break }
        }
    }
    if (-not $provider.Count) {
        throw 'SQL libraries are missing. Install the pinned SqlServer 22.4.5.1 module using build.ps1 -RestoreDependencies, or install it separately. Importing this module never downloads dependencies.'
    }
    $base = $provider[0].ModuleBase
    if ($PSVersionTable.PSEdition -eq 'Core') { $base = Join-Path $base 'coreclr' }
    Import-Module $provider[0].Path -Scope Local -ErrorAction Stop
    Add-Type -Path (Join-Path $base 'Microsoft.SqlServer.TransactSql.ScriptDom.dll') -ErrorAction Stop
    foreach ($type in @([Microsoft.SqlServer.TransactSql.ScriptDom.TSqlParser],[Microsoft.Data.SqlClient.SqlConnection])) {
        $actual = $type.Assembly.Location
        $expected = Join-Path $base ([IO.Path]::GetFileName($actual))
        $assets = @($expected)
        if (-not (Test-Path -LiteralPath $expected) -and $PSVersionTable.PSEdition -eq 'Core') {
            $assets = @(Get-ChildItem -LiteralPath (Join-Path $base 'runtimes\win') -Filter ([IO.Path]::GetFileName($actual)) -Recurse -File -ErrorAction Stop | Select-Object -ExpandProperty FullName)
        }
        $expectedHashes = @($assets | ForEach-Object { (Get-FileHash -LiteralPath $_ -Algorithm SHA256 -ErrorAction Stop).Hash })
        if ((Get-FileHash -LiteralPath $actual -Algorithm SHA256 -ErrorAction Stop).Hash -notin $expectedHashes) {
            throw 'A different SQL library is already loaded. Start a fresh PowerShell process with the pinned SqlServer module.'
        }
    }
    $script:SsaSqlLibraryValidated = $true
}

function New-SsaSqlConnection {
    param([string]$SqlInstance, [string]$Database = 'master', [pscredential]$Credential, [switch]$TrustServerCertificate)
    Initialize-SsaSqlLibrary
    $builder = New-Object Microsoft.Data.SqlClient.SqlConnectionStringBuilder
    $builder['Data Source'] = $SqlInstance
    $builder['Initial Catalog'] = $Database
    $builder['Application Name'] = 'SimpleSqlAssessment'
    $builder['Encrypt'] = 'True'
    $builder['TrustServerCertificate'] = [bool]$TrustServerCertificate
    $builder['Connect Timeout'] = 15
    $builder['Integrated Security'] = -not [bool]$Credential
    $connection = New-Object Microsoft.Data.SqlClient.SqlConnection($builder.ConnectionString)
    if ($Credential) {
        $password = $Credential.Password.Copy()
        $password.MakeReadOnly()
        $connection.Credential = New-Object Microsoft.Data.SqlClient.SqlCredential($Credential.UserName, $password)
    }
    return $connection
}

function Invoke-SsaQuery {
    param($Connection, [string]$Query, [int]$TimeoutSeconds = 30)
    $ErrorActionPreference = 'Stop'
    $command = $Connection.CreateCommand()
    $command.CommandText = $Query
    $command.CommandTimeout = $TimeoutSeconds
    $reader = $null
    try {
        if ($Connection.State -ne 'Open') { $Connection.Open() }
        $reader = $command.ExecuteReader()
        $rows = New-Object 'System.Collections.Generic.List[object]'
        while ($reader.Read()) {
            $row = [ordered]@{}
            for ($i = 0; $i -lt $reader.FieldCount; $i++) {
                $value = $reader.GetValue($i)
                if ($value -is [DBNull]) { $value = $null }
                $row[$reader.GetName($i)] = $value
            }
            $rows.Add([pscustomobject]$row)
        }
        return $rows.ToArray()
    } finally {
        if ($reader) { $reader.Dispose() }
        $command.Dispose()
    }
}

function New-SsaResult {
    param($Bundle, [string]$Region, [string]$Currency, [double]$HoursPerMonth)
    $catalog = Get-SsaCatalog
    [pscustomobject][ordered]@{
        SchemaVersion = '1.0'; AssessmentId = [guid]::NewGuid().ToString()
        GeneratedAt = [datetime]::UtcNow.ToString('o'); Source = $Bundle.Source
        Configuration = [pscustomobject]@{ Region = $Region; Currency = $Currency; HoursPerMonth = $HoursPerMonth }
        Inventory = $Bundle.Databases
        ClientDependencies = Get-SsaClientDependencies $Bundle
        Targets = @(); Findings = @(); RuleEvaluations = @(); Recommendations = @(); Prices = @()
        Performance = [pscustomobject]@{ State = 'Unavailable'; RequestedSeconds = 604800; UsableSeconds = 0; WallSeconds = 0; Gaps = @(); Summary = @(); Series = @() }
        Diagnostics = @($Bundle.Diagnostics)
        Provenance = [pscustomobject]@{ ModuleVersion = $script:SsaVersion; RuleVersion = '2026.10.22'; CatalogVersion = $catalog.Version; CatalogCoverage = Get-SsaValue $catalog 'Coverage'; CollectionId = $Bundle.CollectionId; CollectedAt = $Bundle.CollectedAt }
    }
}
