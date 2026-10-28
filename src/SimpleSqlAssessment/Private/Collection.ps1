function Get-SsaEvidence {
    param($Bundle, [string]$Kind, [string]$Database = '')
    return @($Bundle.Evidence | Where-Object { $_.Kind -eq $Kind -and $_.Database -eq $Database })
}

function Add-SsaEvidence {
    param($List, $Connection, [string]$Kind, [string]$Database, [string]$Query, [bool]$Visible = $true)
    try {
        $rows = @(Invoke-SsaQuery $Connection $Query)
        $status = 'Collected'
        $errorText = $null
        if (-not $Visible) {
            $status = 'Unavailable'
            $errorText = 'Rows may be hidden by metadata permissions; visible positive evidence is retained.'
            Write-Warning "$Kind visibility is incomplete in '$Database'."
        }
        $List.Add([pscustomobject]@{ Kind = $Kind; Database = $Database; Status = $status; Rows = $rows; Error = $errorText })
    } catch {
        $number = Get-SsaValue $_.Exception 'Number' 'unknown'
        $errorText = "Collection failed (SQL error $number). Verify documented permissions and connectivity."
        Write-Warning "$Kind in '$Database': $errorText"
        $List.Add([pscustomobject]@{ Kind = $Kind; Database = $Database; Status = 'Error'; Rows = @(); Error = $errorText })
    }
}

function Get-SsaSource {
    param($Connection)
    $queries = Read-SsaJson (Join-Path $script:SsaModuleRoot 'Queries\queries.json')
    $sourceRows = @(Invoke-SsaQuery $Connection $queries.Source)
    if ($sourceRows.Count -ne 1) { throw 'The source identity query did not return exactly one row.' }
    $source = $sourceRows[0]
    $major = [int]$source.ProductVersion.Split('.')[0]
    if ($major -lt 11) { throw 'SQL Server 2012 or later is required.' }
    $cores = $null; $memory = $null
    try {
        $resources = @(Invoke-SsaQuery $Connection 'SELECT cpu_count AS LogicalProcessors,physical_memory_kb/1048576.0 AS PhysicalMemoryGB FROM sys.dm_os_sys_info;')
        $cores = $resources[0].LogicalProcessors; $memory = $resources[0].PhysicalMemoryGB
    } catch { Write-Warning 'Host resource metadata is unavailable. Static collection can continue; performance collection requires the documented server-performance permissions.' }
    $source | Add-Member NoteProperty LogicalProcessors $cores
    $source | Add-Member NoteProperty PhysicalMemoryGB $memory
    $source | Add-Member NoteProperty VersionMajor $major
    $source | Add-Member NoteProperty Identity (Get-SsaHash "$($source.Instance)|$($source.ComputerName)|$($source.InstanceName)")
    return $source
}

function Get-SsaServerVisibility {
    param($Connection)
    $rows = @(Invoke-SsaQuery $Connection "SELECT IS_SRVROLEMEMBER('sysadmin') AS IsSysadmin, HAS_PERMS_BY_NAME(NULL,'SERVER','VIEW ANY DEFINITION') AS ViewDefinition,HAS_PERMS_BY_NAME(NULL,'SERVER','VIEW ANY DATABASE') AS ViewDatabases,HAS_PERMS_BY_NAME(NULL,'SERVER','ALTER ANY LOGIN') AS ViewLogins;")
    return $rows[0]
}

function New-SsaCollection {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$SqlInstance,
        [Parameter(Mandatory)][string]$CollectionPath,
        [pscredential]$Credential,
        [switch]$TrustServerCertificate
    )
    $root = [IO.Path]::GetFullPath($CollectionPath)
    if (Test-Path -LiteralPath (Join-Path $root 'inventory.json')) { throw 'A collection already exists here. Choose a new path to preserve the original evidence.' }
    if ((Test-Path -LiteralPath $root) -and @(Get-ChildItem -LiteralPath $root -Force).Count) { throw 'The collection directory must be new or empty; existing files and their permissions will not be changed.' }
    [void][IO.Directory]::CreateDirectory($root)
    if ($env:OS -ne 'Windows_NT') { throw 'The first release requires Windows.' }
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent().User
    $acl = New-Object Security.AccessControl.DirectorySecurity
    $acl.SetOwner($identity)
    $acl.SetAccessRuleProtection($true, $false)
    $rule = New-Object Security.AccessControl.FileSystemAccessRule($identity, 'FullControl', 'ContainerInherit,ObjectInherit', 'None', 'Allow')
    $acl.AddAccessRule($rule)
    Set-Acl -LiteralPath $root -AclObject $acl -ErrorAction Stop
    Write-Warning 'The local collection contains sensitive definitions and job text. Do not share the evidence bundle without reviewing it.'
    $queries = Read-SsaJson (Join-Path $script:SsaModuleRoot 'Queries\queries.json')
    $connection = New-SsaSqlConnection $SqlInstance 'master' $Credential -TrustServerCertificate:$TrustServerCertificate
    $evidence = New-Object 'System.Collections.Generic.List[object]'
    $definitions = New-Object 'System.Collections.Generic.List[object]'
    try {
        $source = Get-SsaSource $connection
        $source | Add-Member NoteProperty ConnectionEndpoint $SqlInstance
        $visibility = Get-SsaServerVisibility $connection
        $databases = @(Invoke-SsaQuery $connection $queries.Databases)
        $evidence.Add([pscustomobject]@{ Kind = 'Databases'; Database = ''; Status = $(if ($visibility.ViewDatabases -eq 1) { 'Collected' } else { 'Unavailable' }); Rows = $databases; Error = $null })
        foreach ($kind in @('LinkedServers','Credentials','Principals','Audits','Providers','Triggers','Mail','Jobs','TraceFlags')) {
            $visible = $visibility.IsSysadmin -eq 1 -or $visibility.ViewDefinition -eq 1
            if ($kind -eq 'Principals') { $visible = $visibility.IsSysadmin -eq 1 -or $visibility.ViewLogins -eq 1 }
            if ($kind -eq 'Jobs') {
                $msdb = New-SsaSqlConnection $SqlInstance 'msdb' $Credential -TrustServerCertificate:$TrustServerCertificate
                try {
                    $jobVisibility = @(Invoke-SsaQuery $msdb "SELECT CASE WHEN IS_SRVROLEMEMBER('sysadmin')=1 OR IS_ROLEMEMBER('db_owner')=1 OR IS_ROLEMEMBER('SQLAgentReaderRole')=1 OR IS_ROLEMEMBER('SQLAgentOperatorRole')=1 THEN 1 ELSE 0 END AS FullVisibility;")
                    $visible = $jobVisibility[0].FullVisibility -eq 1
                } catch {
                    $visible = $false
                    Write-Warning 'Could not verify complete SQL Agent job visibility in msdb.'
                } finally { $msdb.Dispose() }
            }
            Add-SsaEvidence $evidence $connection $kind '' $queries.$kind $visible
        }
        foreach ($database in $databases) {
            $dbConnection = New-SsaSqlConnection $SqlInstance $database.Name $Credential -TrustServerCertificate:$TrustServerCertificate
            try {
                $permissions = @(Invoke-SsaQuery $dbConnection "SELECT HAS_PERMS_BY_NAME(DB_NAME(),'DATABASE','VIEW DEFINITION') AS ViewDefinition;")
                $visible = $permissions[0].ViewDefinition -eq 1
                foreach ($kind in @('Files','Definitions','Assemblies','FileStream','Broker','Dependencies','Synonyms','ObjectNames','DatabasePrincipals','SkuFeatures','ExternalDataSources')) {
                    if ($kind -eq 'ExternalDataSources' -and $source.VersionMajor -lt 13) {
                        $evidence.Add([pscustomobject]@{ Kind = $kind; Database = $database.Name; Status = 'Collected'; Rows = @(); Error = $null })
                    } else { Add-SsaEvidence $evidence $dbConnection $kind $database.Name $queries.$kind $visible }
                }
            } catch {
                Write-Warning "Database '$($database.Name)' could not be opened. Its rules will remain unassessed."
                $evidence.Add([pscustomobject]@{ Kind = 'DatabaseAccess'; Database = $database.Name; Status = 'Error'; Rows = @(); Error = 'Database connection or visibility check failed.' })
            } finally { $dbConnection.Dispose() }
            $definitionEvidence = @($evidence | Where-Object { $_.Kind -eq 'Definitions' -and $_.Database -eq $database.Name })
            foreach ($item in $definitionEvidence) {
                foreach ($row in $item.Rows) { $definitions.Add([pscustomobject]@{ Database = $database.Name; Object = $row.Object; Text = $row.Text; Encrypted = $row.Encrypted; Source = 'Module' }) }
            }
            $fileEvidence = @($evidence | Where-Object { $_.Kind -eq 'Files' -and $_.Database -eq $database.Name })
            $dataMB = $null; $logMB = $null
            if ($fileEvidence.Count -and $fileEvidence[0].Status -eq 'Collected') {
                $dataMB = [double](($fileEvidence[0].Rows | Where-Object { $_.Type -eq 'ROWS' } | Measure-Object SizeMB -Sum).Sum)
                $logMB = [double](($fileEvidence[0].Rows | Where-Object { $_.Type -eq 'LOG' } | Measure-Object SizeMB -Sum).Sum)
            }
            $database | Add-Member NoteProperty DataMB $dataMB
            $database | Add-Member NoteProperty LogMB $logMB
        }
        foreach ($entry in @($evidence | Where-Object { $_.Kind -eq 'Jobs' })) {
            foreach ($job in $entry.Rows) {
                if ($job.Subsystem -eq 'TSQL') {
                    $dbName = $job.DatabaseName
                    if (-not $dbName) { $dbName = 'master' }
                    $definitions.Add([pscustomobject]@{ Database = $dbName; Object = "$($job.Name):$($job.StepId)"; Text = $job.Command; Encrypted = $false; Source = 'Job' })
                }
            }
        }
        foreach ($entry in @($evidence | Where-Object { $_.Kind -eq 'Triggers' })) {
            foreach ($trigger in $entry.Rows) {
                $definitions.Add([pscustomobject]@{ Database = 'master'; Object = $trigger.Name; Text = $trigger.Text; Encrypted = -not [bool]$trigger.Text; Source = 'ServerTrigger' })
            }
        }
        $bundle = [pscustomobject][ordered]@{
            SchemaVersion = '1.0'; CollectionId = [guid]::NewGuid().ToString(); CollectedAt = [datetime]::UtcNow.ToString('o')
            Source = $source; Databases = $databases; Evidence = $evidence.ToArray(); Definitions = $definitions.ToArray()
            ClientSnapshot = Get-SsaClientSnapshot $connection $source.VersionMajor
            Diagnostics = @($evidence | Where-Object { $_.Status -ne 'Collected' } | ForEach-Object { [pscustomobject]@{ Code = 'EvidenceUnavailable'; Database = $_.Database; Kind = $_.Kind; Message = $_.Error } })
        }
        Write-SsaJson (Join-Path $root 'inventory.json') $bundle
        Write-SsaJson (Join-Path $root 'manifest.json') ([pscustomobject]@{ SchemaVersion = '1.0'; CollectionId = $bundle.CollectionId; CollectedAt = $bundle.CollectedAt; SourceIdentity = $source.Identity; ModuleVersion = $script:SsaVersion })
        return $bundle
    } finally { $connection.Dispose() }
}
