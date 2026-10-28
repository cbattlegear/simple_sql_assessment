function Get-SsaClientSnapshot {
    param($Connection, [int]$VersionMajor)
    $snapshot = [pscustomobject]@{ Timestamp = (Get-SsaUtcNow).ToString('o'); Status = 'Unavailable'; Rows = @(); Error = $null }
    $permission = 'VIEW SERVER STATE'
    if ($VersionMajor -ge 16) { $permission = 'VIEW SERVER PERFORMANCE STATE' }
    try {
        $visibility = @(Invoke-SsaQuery $Connection "SELECT HAS_PERMS_BY_NAME(NULL,'SERVER','$permission') AS CanViewClients;" -TimeoutSeconds 5)
        if ($visibility.Count -ne 1 -or (Get-SsaValue $visibility[0] 'CanViewClients') -ne 1) {
            $snapshot.Error = "Client inventory requires $permission for server-wide visibility; no complete snapshot was collected."
        } else {
            $queries = Read-SsaJson (Join-Path $script:SsaModuleRoot 'Queries\queries.json')
            $snapshot.Rows = @(Invoke-SsaQuery $Connection $queries.ClientConnections -TimeoutSeconds 5)
            $snapshot.Timestamp = (Get-SsaUtcNow).ToString('o')
            $snapshot.Status = 'Collected'
        }
    } catch {
        $snapshot.Status = 'Error'
        $number = Get-SsaValue $_.Exception 'Number' 'unknown'
        $snapshot.Error = "Client inventory query failed (SQL error $number). Verify server-state permissions and connectivity."
    }
    if ($snapshot.Error) { Write-Warning $snapshot.Error }
    return $snapshot
}

function New-SsaClientObservationState {
    @{
        Clients = @{}; Diagnostics = @{}; SnapshotsObserved = 0
        SnapshotsUnavailable = 0; SnapshotsNotCollected = 0
        FirstSnapshotAt = $null; LastSnapshotAt = $null
    }
}

function Get-SsaClientLocation {
    param($Row)
    $transport = [string](Get-SsaValue $Row 'NetTransport')
    $address = [string](Get-SsaValue $Row 'ClientAddress')
    if ($transport -eq 'Shared memory' -or $address -eq '<local machine>') { return 'Local' }
    $ip = $null
    if ([Net.IPAddress]::TryParse($address, [ref]$ip)) {
        if ($ip.IsIPv4MappedToIPv6) { $ip = $ip.MapToIPv4() }
        if ([Net.IPAddress]::IsLoopback($ip)) { return 'Local' }
        $localIp = $null
        if ([Net.IPAddress]::TryParse([string](Get-SsaValue $Row 'LocalAddress'), [ref]$localIp)) {
            if ($localIp.IsIPv4MappedToIPv6) { $localIp = $localIp.MapToIPv4() }
            if ($ip.Equals($localIp)) { return 'Local' }
        }
        if ($transport -eq 'TCP') { return 'Remote' }
    }
    return 'Unknown'
}

function Add-SsaClientSnapshot {
    param($State, $Snapshot)
    if ($null -eq $Snapshot) { $State.SnapshotsNotCollected++; return }
    $status = Get-SsaValue $Snapshot 'Status'
    if ($status -ne 'Collected') {
        $State.SnapshotsUnavailable++
        $message = Get-SsaValue $Snapshot 'Error' 'Client snapshot is unavailable.'
        if (-not $message) { $message = 'Client snapshot is unavailable.' }
        if (-not $State.Diagnostics.ContainsKey($message)) {
            $State.Diagnostics[$message] = [pscustomobject]@{ Message = $message; SnapshotCount = 0 }
        }
        $State.Diagnostics[$message].SnapshotCount++
        return
    }
    $timestamp = Get-SsaValue $Snapshot 'Timestamp'
    if (-not $timestamp) { throw 'A collected client snapshot has no observation timestamp.' }
    $time = ([datetimeoffset]$timestamp).UtcDateTime.ToString('o')
    $State.SnapshotsObserved++
    if (-not $State.FirstSnapshotAt -or $time -lt $State.FirstSnapshotAt) { $State.FirstSnapshotAt = $time }
    if (-not $State.LastSnapshotAt -or $time -gt $State.LastSnapshotAt) { $State.LastSnapshotAt = $time }
    $snapshotGroups = @{}
    foreach ($row in @(Get-SsaValue $Snapshot 'Rows' @())) {
        $sessionId = Get-SsaValue $row 'SessionId'
        if ($null -eq $sessionId -or [int]$sessionId -lt 1) { throw 'A client observation has no valid session ID.' }
        $location = Get-SsaClientLocation $row
        $identity = @(
            ([string](Get-SsaValue $row 'ClientAddress')).ToLowerInvariant(),
            ([string](Get-SsaValue $row 'HostName')).ToLowerInvariant(),
            (Get-SsaValue $row 'ProgramName'), (Get-SsaValue $row 'ClientInterfaceName'),
            (Get-SsaValue $row 'LoginName'), $location
        )
        $key = Get-SsaHash (ConvertTo-Json -InputObject $identity -Compress)
        if (-not $State.Clients.ContainsKey($key)) {
            $State.Clients[$key] = [pscustomobject]@{
                ClientAddress = Get-SsaValue $row 'ClientAddress'; HostName = Get-SsaValue $row 'HostName'
                ProgramName = Get-SsaValue $row 'ProgramName'; ClientInterfaceName = Get-SsaValue $row 'ClientInterfaceName'
                LoginName = Get-SsaValue $row 'LoginName'; Location = $location
                FirstObservedAt = $time; LastObservedAt = $time; SamplesSeen = 0; PeakSessions = 0
                Databases = @{}; Transports = @{}; AuthenticationSchemes = @{}; EncryptionStates = @{}
            }
        }
        $client = $State.Clients[$key]
        if (-not $snapshotGroups.ContainsKey($key)) { $snapshotGroups[$key] = @{}; $client.SamplesSeen++ }
        # A session can have multiple MARS connection rows; count it once per snapshot.
        $snapshotGroups[$key][[string]$sessionId] = $true
        if ($time -lt $client.FirstObservedAt) { $client.FirstObservedAt = $time }
        if ($time -gt $client.LastObservedAt) { $client.LastObservedAt = $time }
        foreach ($field in @(
            @{ Source = 'DatabaseName'; Destination = 'Databases' },
            @{ Source = 'NetTransport'; Destination = 'Transports' },
            @{ Source = 'AuthScheme'; Destination = 'AuthenticationSchemes' },
            @{ Source = 'EncryptOption'; Destination = 'EncryptionStates' }
        )) {
            $item = Get-SsaValue $row $field.Source
            if ($null -ne $item -and [string]$item -ne '') { $client.($field.Destination)[[string]$item] = $true }
        }
    }
    foreach ($key in $snapshotGroups.Keys) {
        $client = $State.Clients[$key]
        $client.PeakSessions = [math]::Max($client.PeakSessions, $snapshotGroups[$key].Count)
    }
}

function ConvertTo-SsaClientDependencies {
    param($State, $SampleIntervalSeconds)
    $status = 'NotCollected'
    if ($State.SnapshotsObserved) {
        $status = 'Collected'
        if ($State.SnapshotsUnavailable -or $State.SnapshotsNotCollected) { $status = 'Partial' }
    } elseif ($State.SnapshotsUnavailable) { $status = 'Unavailable' }
    $clients = @($State.Clients.Values | Sort-Object Location, ClientAddress, HostName, ProgramName, LoginName | ForEach-Object {
        $row = [ordered]@{}
        foreach ($property in $_.PSObject.Properties) {
            $row[$property.Name] = $property.Value
            if ($property.Value -is [System.Collections.IDictionary]) { $row[$property.Name] = @($property.Value.Keys | Sort-Object) }
        }
        [pscustomobject]$row
    })
    [pscustomobject]@{
        Status = $status; SnapshotsObserved = $State.SnapshotsObserved
        SnapshotsUnavailable = $State.SnapshotsUnavailable; SnapshotsNotCollected = $State.SnapshotsNotCollected
        FirstSnapshotAt = $State.FirstSnapshotAt; LastSnapshotAt = $State.LastSnapshotAt
        SampleIntervalSeconds = $SampleIntervalSeconds; Clients = $clients
        Diagnostics = @($State.Diagnostics.Values | Sort-Object Message)
        Notes = @(
            'Observed inbound clients only, not a complete application dependency map or connection audit.',
            'Snapshots can miss short-lived connections and jobs outside the observation window. SamplesSeen is sightings, not new logins; PeakSessions is sampled concurrency, not a guaranteed peak.',
            'Host and program names are client supplied. SQL-observed IPs can identify a proxy or NAT gateway. Local/remote classification is best effort; unknown clients are retained. No DNS lookups or client-machine access are performed.',
            'Databases are observed current session contexts, not every database accessed or proof of a database dependency.',
            'The collector query session and internal sessions are excluded. Existing pooled and sleeping user sessions are included; sightings do not prove active workload.',
            'Collected means all included snapshots succeeded, not that all clients were discovered. Missing legacy evidence and failed queries remain explicit. Client identifiers and logins are sensitive.'
        )
    }
}

function Get-SsaClientDependencies {
    param($Bundle, [string]$CollectionPath)
    $state = New-SsaClientObservationState
    Add-SsaClientSnapshot $state (Get-SsaValue $Bundle 'ClientSnapshot')
    $interval = $null
    if ($CollectionPath) {
        Read-SsaCaptureRecords $CollectionPath $Bundle | ForEach-Object {
            Add-SsaClientSnapshot $state (Get-SsaValue $_.Raw 'ClientSnapshot')
        }
        $path = Join-Path $CollectionPath 'capture.json'
        if (Test-Path -LiteralPath $path) { $interval = Get-SsaValue (Read-SsaJson $path) 'SampleIntervalSeconds' }
    }
    ConvertTo-SsaClientDependencies $state $interval
}
