BeforeAll {
    $root = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
    Import-Module (Join-Path $root 'src\SimpleSqlAssessment\SimpleSqlAssessment.psd1') -Force
    . (Join-Path (Split-Path $PSScriptRoot -Parent) 'TestHelpers.ps1')
    $script:module = Get-Module SimpleSqlAssessment
    function New-ClientRow {
        param([int]$SessionId = 51, [string]$Database = 'App')
        [pscustomobject]@{
            SessionId = $SessionId; ClientAddress = '192.0.2.10'; LocalAddress = '192.0.2.20'
            HostName = 'APP01'; ProgramName = 'Example application'; ClientInterfaceName = 'Example driver'
            LoginName = 'example-login'; DatabaseName = $Database; NetTransport = 'TCP'
            AuthScheme = 'KERBEROS'; EncryptOption = 'TRUE'
        }
    }
    function New-ClientSnapshot {
        param([object[]]$Rows = @(), [int]$Second = 0, [string]$Status = 'Collected')
        [pscustomobject]@{
            Timestamp = ([datetime]'2026-01-01T00:00:00Z').AddSeconds($Second).ToString('o')
            Status = $Status; Rows = @($Rows); Error = $(if ($Status -ne 'Collected') { 'Fixture unavailable.' } else { $null })
        }
    }
    function Get-ClientSummary {
        param([object[]]$Snapshots)
        & $script:module {
            param($snapshots)
            $state = New-SsaClientObservationState
            foreach ($snapshot in $snapshots) { Add-SsaClientSnapshot $state $snapshot }
            ConvertTo-SsaClientDependencies $state 30
        } $Snapshots
    }
}

Describe 'Read-only inbound client snapshots' {
    BeforeEach {
        Mock Invoke-SsaQuery -ModuleName SimpleSqlAssessment {
            param($Query)
            if ($Query -like '*AS CanViewClients;') { [pscustomobject]@{ CanViewClients = 1 } }
        }
    }
    It 'checks complete server visibility with the SQL <Major> permission' -ForEach @(
        @{ Major = 11; Permission = 'VIEW SERVER STATE' }, @{ Major = 15; Permission = 'VIEW SERVER STATE' },
        @{ Major = 16; Permission = 'VIEW SERVER PERFORMANCE STATE' }, @{ Major = 17; Permission = 'VIEW SERVER PERFORMANCE STATE' }
    ) {
        $snapshot = & $script:module { param($major) Get-SsaClientSnapshot $null $major } $Major
        $snapshot.Status | Should -Be Collected
        $snapshot.Rows.Count | Should -Be 0
        Should -Invoke Invoke-SsaQuery -ModuleName SimpleSqlAssessment -Times 1 -Exactly -ParameterFilter {
            $Query -like "*'$Permission'*AS CanViewClients;" -and $TimeoutSeconds -eq 5
        }
    }
    It 'does not present self-only DMV visibility as a complete empty inventory' {
        Mock Invoke-SsaQuery -ModuleName SimpleSqlAssessment { [pscustomobject]@{ CanViewClients = 0 } }
        $snapshot = & $script:module { Get-SsaClientSnapshot $null 16 }
        $snapshot.Status | Should -Be Unavailable
        $snapshot.Error | Should -Match 'VIEW SERVER PERFORMANCE STATE'
        Should -Invoke Invoke-SsaQuery -ModuleName SimpleSqlAssessment -Times 0 -Exactly -ParameterFilter { $Query -like '*sys.dm_exec_sessions*' }
    }
    It 'keeps failed queries nonfatal and avoids copying exception contents into evidence' {
        Mock Invoke-SsaQuery -ModuleName SimpleSqlAssessment -ParameterFilter { $Query -like '*sys.dm_exec_sessions*' } { throw 'sensitive fixture exception' }
        $snapshot = & $script:module { Get-SsaClientSnapshot $null 16 }
        $snapshot.Status | Should -Be Error
        $snapshot.Rows.Count | Should -Be 0
        $snapshot.Error | Should -Not -Match 'sensitive fixture'
        (Get-ClientSummary @($snapshot)).Status | Should -Be Unavailable
    }
    It 'persists an explicit empty array after JSON round trip in both editions' {
        $snapshot = & $script:module { Get-SsaClientSnapshot $null 16 }
        $roundtrip = $snapshot | ConvertTo-Json -Depth 10 | ConvertFrom-Json
        ($roundtrip.Rows -is [array]) | Should -BeTrue
        (Get-ClientSummary @($roundtrip)).Status | Should -Be Collected
    }
    It 'queries user sessions without active-request filtering, SQL text, or collector/MARS duplicates' {
        $queries = Get-Content -Raw (Join-Path $root 'src\SimpleSqlAssessment\Queries\queries.json') | ConvertFrom-Json
        $queries.ClientConnections | Should -Match 's.is_user_process=1'
        $queries.ClientConnections | Should -Match 's.session_id<>@@SPID'
        $queries.ClientConnections | Should -Match 'c.parent_connection_id IS NULL'
        $queries.ClientConnections | Should -Match 'LEFT JOIN'
        $queries.ClientConnections | Should -Match 's.original_login_name AS LoginName'
        $queries.ClientConnections | Should -Not -Match 'dm_exec_requests|dm_exec_sql_text|most_recent_sql_handle|s.status='
    }
}

Describe 'Client location and observation aggregation' {
    It 'classifies <Transport> / <Address> as <Expected> without relying on the hostname' -ForEach @(
        @{ Transport = 'TCP'; Address = '192.0.2.10'; Local = '192.0.2.20'; Expected = 'Remote' },
        @{ Transport = 'TCP'; Address = '127.0.0.1'; Local = '192.0.2.20'; Expected = 'Local' },
        @{ Transport = 'TCP'; Address = '::1'; Local = '192.0.2.20'; Expected = 'Local' },
        @{ Transport = 'TCP'; Address = '::ffff:127.0.0.1'; Local = '192.0.2.20'; Expected = 'Local' },
        @{ Transport = 'TCP'; Address = '::ffff:192.0.2.20'; Local = '192.0.2.20'; Expected = 'Local' },
        @{ Transport = 'Shared memory'; Address = ''; Local = ''; Expected = 'Local' },
        @{ Transport = 'Named pipe'; Address = '<local machine>'; Local = ''; Expected = 'Local' },
        @{ Transport = 'Named pipe'; Address = ''; Local = ''; Expected = 'Unknown' },
        @{ Transport = 'TCP'; Address = ''; Local = '192.0.2.20'; Expected = 'Unknown' }
    ) {
        $row = New-ClientRow
        $row.ClientAddress = $Address; $row.LocalAddress = $Local; $row.NetTransport = $Transport
        $row.HostName = 'SAME-AS-SERVER-IS-NOT-PROOF'
        (Get-ClientSummary @((New-ClientSnapshot @($row)))).Clients[0].Location | Should -Be $Expected
    }
    It 'counts sightings and sampled peak sessions, not repeated logins or summed concurrency' {
        $a = New-ClientSnapshot @((New-ClientRow 51),(New-ClientRow 52),(New-ClientRow 52)) 0
        $b = New-ClientSnapshot @((New-ClientRow 51 'OtherDb')) 30
        $summary = Get-ClientSummary @($a,$b)
        $summary.SnapshotsObserved | Should -Be 2
        $summary.Clients.Count | Should -Be 1
        $summary.Clients[0].SamplesSeen | Should -Be 2
        $summary.Clients[0].PeakSessions | Should -Be 2
        $summary.Clients[0].Databases | Should -Be @('App','OtherDb')
        $summary.Clients[0].FirstObservedAt | Should -Be '2026-01-01T00:00:00.0000000Z'
        $summary.Clients[0].LastObservedAt | Should -Be '2026-01-01T00:00:30.0000000Z'
        @($summary.Notes | Where-Object { $_ -like '*not every database accessed*' }).Count | Should -Be 1
    }
    It 'preserves authentication, encryption, and driver evidence without multiplying client groups' {
        $a = New-ClientRow; $b = New-ClientRow
        $b.AuthScheme = 'SQL'; $b.EncryptOption = 'FALSE'
        $summary = Get-ClientSummary @((New-ClientSnapshot @($a)),(New-ClientSnapshot @($b) 30))
        $summary.Clients[0].AuthenticationSchemes | Should -Be @('KERBEROS','SQL')
        $summary.Clients[0].EncryptionStates | Should -Be @('FALSE','TRUE')
        $summary.Clients[0].ClientInterfaceName | Should -Be 'Example driver'
    }
    It 'keeps different clients/applications/logins and delimiter-containing identifiers separate' {
        $rows = @(New-ClientRow 51; New-ClientRow 52; New-ClientRow 53; New-ClientRow 54)
        $rows[1].ClientAddress = '192.0.2.11'
        $rows[2].ProgramName = 'Other|application'
        $rows[3].LoginName = 'Other|login'
        (Get-ClientSummary @((New-ClientSnapshot $rows))).Clients.Count | Should -Be 4
    }
    It 'retains unknown clients rather than deleting incomplete identities' {
        $row = New-ClientRow; $row.ClientAddress = $null; $row.HostName = $null
        $summary = Get-ClientSummary @((New-ClientSnapshot @($row)))
        $summary.Clients.Count | Should -Be 1
        $summary.Clients[0].Location | Should -Be Unknown
    }
    It 'retains partial successful evidence and summarizes repeated failures' {
        $success = New-ClientSnapshot @((New-ClientRow))
        $failed = New-ClientSnapshot @() 30 'Error'
        $summary = Get-ClientSummary @($success,$failed,$failed,$null)
        $summary.Status | Should -Be Partial
        $summary.SnapshotsObserved | Should -Be 1
        $summary.SnapshotsUnavailable | Should -Be 2
        $summary.SnapshotsNotCollected | Should -Be 1
        $summary.Diagnostics.Count | Should -Be 1
        $summary.Diagnostics[0].SnapshotCount | Should -Be 2
        $summary.Clients.Count | Should -Be 1
    }
    It 'distinguishes legacy missing evidence, denied visibility, and observed zero clients' {
        (Get-ClientSummary @($null)).Status | Should -Be NotCollected
        (Get-ClientSummary @((New-ClientSnapshot @() 0 'Unavailable'))).Status | Should -Be Unavailable
        $empty = Get-ClientSummary @((New-ClientSnapshot))
        $empty.Status | Should -Be Collected
        $empty.Clients.Count | Should -Be 0
        $empty.SnapshotsObserved | Should -Be 1
    }
    It 'normalizes offset times and uses actual observation ordering' {
        $a = New-ClientSnapshot @((New-ClientRow)); $a.Timestamp = '2026-01-01T01:00:30+01:00'
        $b = New-ClientSnapshot @((New-ClientRow)); $b.Timestamp = '2026-01-01T00:00:00Z'
        $summary = Get-ClientSummary @($a,$b)
        $summary.Clients[0].FirstObservedAt | Should -Be '2026-01-01T00:00:00.0000000Z'
        $summary.Clients[0].LastObservedAt | Should -Be '2026-01-01T00:00:30.0000000Z'
    }
    It 'rejects malformed collected observations instead of inventing identity or timestamps' {
        $snapshot = New-ClientSnapshot @((New-ClientRow)); $snapshot.Timestamp = $null
        { Get-ClientSummary @($snapshot) } | Should -Throw '*timestamp*'
        $snapshot = New-ClientSnapshot @([pscustomobject]@{ HostName = 'invalid' })
        { Get-ClientSummary @($snapshot) } | Should -Throw '*session ID*'
    }
}

Describe 'Client capture and offline workflow' {
    BeforeEach {
        $script:collection = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $bundle = New-TestBundle
        $bundle | Add-Member NoteProperty ClientSnapshot (New-ClientSnapshot @((New-ClientRow)))
        $null = Save-TestBundle $script:collection $bundle
        $rawSamples = @(0..12 | ForEach-Object {
            $raw = New-TestRawSample $_
            $raw | Add-Member NoteProperty ClientSnapshot (New-ClientSnapshot @((New-ClientRow 51 'OtherDb')) $_)
            $raw
        })
        & $script:module { param($samples) $script:ClientTestSamples = $samples; $script:ClientTestIndex = 0; $script:ClientTestFailure = $false } $rawSamples
        Mock New-SsaSqlConnection -ModuleName SimpleSqlAssessment { New-Object IO.MemoryStream }
        Mock Start-Sleep -ModuleName SimpleSqlAssessment {}
        Mock Get-SsaRawSample -ModuleName SimpleSqlAssessment {
            & (Get-Module SimpleSqlAssessment) {
                if ($script:ClientTestFailure -and $script:ClientTestIndex -ge 1) { throw 'Fixture outage.' }
                $script:ClientTestSamples[$script:ClientTestIndex++]
            }
        }
    }
    It 'aggregates static and committed raw snapshots including baselines without duplicating on resume' {
        $null = Start-SsaPerformanceCapture -CollectionPath $script:collection -Duration ([timespan]::FromSeconds(1)) -SampleIntervalSeconds 1
        $null = Resume-SsaPerformanceCapture -CollectionPath $script:collection
        $summary = & $script:module { param($path) Get-SsaClientDependencies (Read-SsaBundle $path) $path } $script:collection
        $summary.Status | Should -Be Collected
        $summary.SnapshotsObserved | Should -Be 3
        $summary.SampleIntervalSeconds | Should -Be 1
        $summary.Clients[0].SamplesSeen | Should -Be 3
        $summary.Clients[0].Databases | Should -Be @('App','OtherDb')
        $analysis = & $script:module { param($path) Get-SsaPerformanceAnalysis $path (Read-SsaBundle $path) } $script:collection
        $analysis.UsableSeconds | Should -Be 1
        ($analysis.ClientDependencies | ConvertTo-Json -Depth 10) | Should -Be ($summary | ConvertTo-Json -Depth 10)
    }
    It 'keeps observations across an interrupted capture without attributing outage activity' {
        & $script:module { $script:ClientTestFailure = $true }
        { Start-SsaPerformanceCapture -CollectionPath $script:collection -Duration ([timespan]::FromSeconds(1)) -SampleIntervalSeconds 1 } | Should -Throw '*outage*'
        & $script:module { $script:ClientTestFailure = $false; $script:ClientTestIndex = 10 }
        $null = Resume-SsaPerformanceCapture -CollectionPath $script:collection
        $summary = & $script:module { param($path) Get-SsaClientDependencies (Read-SsaBundle $path) $path } $script:collection
        $summary.SnapshotsObserved | Should -Be 4
        $summary.Clients[0].SamplesSeen | Should -Be 4
        $summary.Clients[0].PeakSessions | Should -Be 1
    }
    It 'does not make optional client errors invalidate performance samples' {
        & $script:module {
            foreach ($raw in $script:ClientTestSamples) {
                $raw.ClientSnapshot.Status = 'Error'; $raw.ClientSnapshot.Rows = @(); $raw.ClientSnapshot.Error = 'Fixture denied.'
            }
        }
        $state = Start-SsaPerformanceCapture -CollectionPath $script:collection -Duration ([timespan]::FromSeconds(1)) -SampleIntervalSeconds 1
        $state.UsableSeconds | Should -Be 1
        $summary = & $script:module { param($path) Get-SsaClientDependencies (Read-SsaBundle $path) $path } $script:collection
        $summary.Status | Should -Be Partial
        $summary.SnapshotsUnavailable | Should -Be 2
    }
    It 'keeps old bundles readable without inventing client evidence' {
        $oldPath = Join-Path $TestDrive 'old-capture'
        $null = Save-ObservedBundle $oldPath
        $summary = & $script:module { param($path) Get-SsaClientDependencies (Read-SsaBundle $path) $path } $oldPath
        $summary.Status | Should -Be NotCollected
        $summary.SnapshotsNotCollected | Should -Be 4
        $summary.Clients.Count | Should -Be 0
    }
    It 'exports a static-only client report offline without SQL or Windows observations' {
        Mock New-SsaSqlConnection -ModuleName SimpleSqlAssessment { throw 'Must stay offline.' }
        $result = Invoke-SsaAssessment -CollectionPath $script:collection -OutputPath (Join-Path $TestDrive 'clients-static') -Region eastus -Offline -SkipPerformance
        $result.ClientDependencies.Status | Should -Be Collected
        $result.ClientDependencies.Clients[0].HostName | Should -Be APP01
        $result.Performance.State | Should -Be Skipped
        Test-Path $result.OutputFiles.CsvFiles.'client-dependencies' | Should -BeTrue
        Should -Invoke New-SsaSqlConnection -ModuleName SimpleSqlAssessment -Times 0 -Exactly
    }
    It 'wires captured clients into the integrated offline result even when no sizing fits' {
        $null = Start-SsaPerformanceCapture -CollectionPath $script:collection -Duration ([timespan]::FromSeconds(1)) -SampleIntervalSeconds 1
        Mock New-SsaSqlConnection -ModuleName SimpleSqlAssessment { throw 'Must stay offline.' }
        Mock Get-SsaSkuRecommendation -ModuleName SimpleSqlAssessment { @() }
        $result = Invoke-SsaAssessment -CollectionPath $script:collection -OutputPath (Join-Path $TestDrive 'clients-full') -Region eastus -Offline
        $result.ClientDependencies.SnapshotsObserved | Should -Be 3
        $result.ClientDependencies.Clients[0].Databases | Should -Be @('App','OtherDb')
        $result.Performance.PSObject.Properties.Name | Should -Not -Contain ClientDependencies
        Should -Invoke New-SsaSqlConnection -ModuleName SimpleSqlAssessment -Times 1 -Exactly
    }
}

Describe 'Optional client queries in real capture assembly' {
    It 'returns required performance observations even when the optional client query fails' {
        $bundle = New-TestBundle
        $source = $bundle.Source
        $source | Add-Member NoteProperty PhysicalMemoryGB 16
        $fixture = New-TestRawSample
        $fixture.Windows | Add-Member NoteProperty AvailableMemoryGB 8
        Mock Get-SsaSource -ModuleName SimpleSqlAssessment { $source }
        Mock Get-SsaWindowsSample -ModuleName SimpleSqlAssessment { $fixture.Windows }
        Mock Invoke-SsaQuery -ModuleName SimpleSqlAssessment {
            param($Query)
            if ($Query -like '*sys.dm_io_virtual_file_stats*') { $fixture.Files }
            elseif ($Query -like '*Total Server Memory*') { [pscustomobject]@{ MemoryKB = 1048576 } }
            elseif ($Query -like '*AS StartTime*') { [pscustomobject]@{ StartTime = 'stable' } }
            elseif ($Query -like '*AS CanViewClients;') { [pscustomobject]@{ CanViewClients = 1 } }
            elseif ($Query -like '*sys.dm_exec_sessions*') { throw 'Optional client query failed.' }
        }
        $raw = & $script:module { param($b) Get-SsaRawSample $null $b } $bundle
        $raw.ClientSnapshot.Status | Should -Be Error
        $raw.Files.Count | Should -Be 2
        $raw.MemoryGB | Should -Be 1
    }
}
