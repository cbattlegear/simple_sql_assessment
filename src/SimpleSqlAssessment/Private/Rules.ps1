function Get-SsaEvidenceRows {
    param($Bundle, [string]$Kind, [string]$Database)
    $globalKinds = @('Databases','LinkedServers','Providers','Jobs','Mail','Principals','Audits','Credentials','Triggers','TraceFlags')
    if ($Kind -in $globalKinds) { $Database = '' }
    foreach ($entry in @(Get-SsaEvidence $Bundle $Kind $Database)) { foreach ($row in $entry.Rows) { $row } }
}

function Test-SsaEvidenceComplete {
    param($Bundle, [string]$Kind, [string]$Database)
    if ($Kind -in @('Databases','LinkedServers','Providers','Jobs','Mail','Principals','Audits','Credentials','Triggers','TraceFlags')) { $Database = '' }
    if (-not $Database -and $Kind -in @('Files','Definitions','SkuFeatures','DatabasePrincipals')) {
        foreach ($db in $Bundle.Databases) { if (-not (Test-SsaEvidenceComplete $Bundle $Kind $db.Name)) { return $false } }
        return (Test-SsaEvidenceComplete $Bundle 'Databases' '')
    }
    $entries = @(Get-SsaEvidence $Bundle $Kind $Database)
    return ($entries.Count -eq 1 -and $entries[0].Status -eq 'Collected')
}

function New-SsaMatch {
    param([string]$Object, [string]$Message, [int]$Line = 0, [switch]$Review)
    [pscustomobject]@{ Object = $Object; Message = $Message; Line = $Line; Review = [bool]$Review }
}

function Get-SsaSyntaxMatch {
    param($Rule, $Analyses, $Bundle, [string]$Database)
    $procedureRules = @{
        XpCmdshell = @('xp_cmdshell')
        SqlMail = @('xp_sendmail','xp_startmail','xp_stopmail','sp_processmail','sp_sendmail')
        SystemProcedures110 = @('sp_dboption','sp_addserver','sp_dropalias','sp_activedirectory_obj','sp_activedirectory_scp','sp_activedirectory_start')
    }
    $sqlProviders = @('SQLNCLI','SQLNCLI11','SQLOLEDB','MSOLEDBSQL')
    $supportedMiFlags = @()
    if ($Rule.RuleId -eq 'TraceFlags' -and $Rule.Target -eq 'ManagedInstance') {
        $supportedMiFlags = @((Read-SsaJson (Join-Path $script:SsaModuleRoot 'Rules\rules.json')).ManagedInstanceTraceFlags.Global)
    }
    foreach ($analysis in $Analyses) {
        foreach ($hit in $analysis.Syntax.Hits) {
            $matches = $false; $review = $false
            $message = "Detected $($Rule.RuleId) usage."
            if ($procedureRules.ContainsKey($Rule.RuleId)) {
                $matches = $hit.Kind -eq 'Procedure' -and $hit.Value -in $procedureRules[$Rule.RuleId]
            } elseif ($Rule.RuleId -eq 'MSDTCTransactSQL') { $matches = $hit.Kind -eq 'DistributedTransaction' }
            elseif ($Rule.RuleId -in @('MIHomogeneousMSDTCTransactSQL','MIHeterogeneousMSDTCTransactSQL')) {
                if ($hit.Kind -eq 'DistributedTransaction') {
                    $servers = @(Get-SsaEvidenceRows $Bundle 'LinkedServers' '')
                    $nonSql = @($servers | Where-Object { $_.Provider -and $_.Provider -notin $sqlProviders })
                    $matches = $true
                    $review = $true
                    $message = 'Transaction participant and network configuration cannot be established from a BEGIN DISTRIBUTED TRANSACTION statement alone.'
                    if ($Rule.RuleId -eq 'MIHeterogeneousMSDTCTransactSQL' -and $nonSql.Count) {
                        $message = 'Non-SQL providers and distributed transactions coexist; verify whether the transaction actually uses these participants.'
                    }
                }
            } elseif ($Rule.RuleId -eq 'CrossDatabaseReferences') {
                $matches = $hit.Kind -eq 'CrossDatabase' -and $hit.Value -ne $Database
            } elseif ($Rule.RuleId -eq 'TraceFlags' -and $hit.Kind -eq 'TraceFlags') {
                $matches = $true
                if ($Rule.Target -eq 'ManagedInstance') {
                    $parts = $hit.Value.Split(':')
                    if ($parts[0] -eq 'Global') {
                        $unsupported = @($parts[1].Split(',') | Where-Object { [int]$_ -notin $supportedMiFlags })
                        $matches = $unsupported.Count -gt 0
                        $message = 'The statement requests global trace flags absent from the documented Managed Instance allowlist.'
                    } elseif ($parts[0] -eq 'Session') { $message = 'Session trace flags are not supported on Managed Instance.' }
                    else { $review = $true; $message = 'Trace flag values or scope are unresolved; verify against the versioned Managed Instance global allowlist.' }
                }
            } elseif ($Rule.RuleId -eq 'OpenRowsetWithSQLAndNonSQLProvider') { $matches = $hit.Kind -eq 'ProviderRowset' }
            elseif ($Rule.RuleId -eq 'OpenRowsetWithNonSQLProvider') {
                $matches = $hit.Kind -eq 'ProviderRowset' -and $hit.Value -notin $sqlProviders
            } elseif ($Rule.RuleId -in @('BulkInsert','OpenRowsetWithNonBlobDataSourceBulk')) {
                $kind = 'BulkInsert'; if ($Rule.RuleId -ne 'BulkInsert') { $kind = 'BulkRowset' }
                if ($hit.Kind -eq $kind) {
                    $matches = $true
                    if ($hit.Value -match '^https://[^/]+\.blob\.core\.(windows\.net|usgovcloudapi\.net|chinacloudapi\.cn)/[^/]+/.+') { $matches = $false }
                    elseif ($analysis.Syntax.BulkDataSources.Count) {
                        $sources = @(Get-SsaEvidenceRows $Bundle 'ExternalDataSources' $Database)
                        $resolved = @($sources | Where-Object { $_.Name -in $analysis.Syntax.BulkDataSources })
                        $valid = @($resolved | Where-Object { $_.Location -match '^https://[^/]+\.blob\.core\.(windows\.net|usgovcloudapi\.net|chinacloudapi\.cn)(/|$)' })
                        # Multiple statements/sources require statement-specific review, not blanket acceptance.
                        if ($analysis.Syntax.BulkDataSources.Count -eq 1 -and $resolved.Count -eq 1 -and $valid.Count -eq 1 -and @($analysis.Syntax.Hits | Where-Object { $_.Kind -in @('BulkInsert','BulkRowset') }).Count -eq 1) { $matches = $false }
                        else { $review = $true; $message = 'Bulk source mapping is unresolved or spans multiple statements; verify Blob-backed access per statement.' }
                    }
                }
            } else { $matches = $hit.Kind -eq $Rule.RuleId }
            if ($matches) { New-SsaMatch $analysis.Object $message $hit.Line -Review:$review }
        }
    }
}

function Get-SsaRuleMatches {
    param($Rule, $Bundle, $Database, $Analyses, $Catalog)
    $name = ''; if ($Database) { $name = $Database.Name }
    $rows = @()
    switch ($Rule.RuleId) {
        AgentJobs {
            foreach ($job in @(Get-SsaEvidenceRows $Bundle 'Jobs' '')) {
                New-SsaMatch $job.Name 'SQL Agent jobs are a non-blocking migration warning. Plan replacement scheduling for Azure SQL Database.'
            }
        }
        AnalysisCommandJob { $rows = @(Get-SsaEvidenceRows $Bundle 'Jobs' '' | Where-Object { $_.Subsystem -eq 'ANALYSISCOMMAND' }) }
        AnalysisQueryJob { $rows = @(Get-SsaEvidenceRows $Bundle 'Jobs' '' | Where-Object { $_.Subsystem -eq 'ANALYSISQUERY' }) }
        MergeJob { $rows = @(Get-SsaEvidenceRows $Bundle 'Jobs' '' | Where-Object { $_.Subsystem -eq 'Merge' }) }
        PowerShellJob { $rows = @(Get-SsaEvidenceRows $Bundle 'Jobs' '' | Where-Object { $_.Subsystem -eq 'PowerShell' }) }
        QueueReaderJob { $rows = @(Get-SsaEvidenceRows $Bundle 'Jobs' '' | Where-Object { $_.Subsystem -eq 'QueueReader' }) }
        ClrAssemblies { $rows = @(Get-SsaEvidenceRows $Bundle 'Assemblies' $name) }
        ClrStrictSecurity { $rows = @(Get-SsaEvidenceRows $Bundle 'Assemblies' $name | Where-Object { $_.PermissionSet -in @('SAFE_ACCESS','EXTERNAL_ACCESS') }) }
        DatabaseMail { $rows = @(Get-SsaEvidenceRows $Bundle 'Mail' '') }
        FileStream { $rows = @(Get-SsaEvidenceRows $Bundle 'FileStream' $name) }
        LinkedServer {
            foreach ($server in @(Get-SsaEvidenceRows $Bundle 'LinkedServers' '')) {
                New-SsaMatch $server.Name 'A linked server is configured; verify usage by this database and migrate required dependencies.' -Review
            }
        }
        LinkedServerWithNonSQLProvider {
            foreach ($server in @(Get-SsaEvidenceRows $Bundle 'LinkedServers' '' | Where-Object { $_.Provider -notin @('SQLNCLI','SQLNCLI11','SQLOLEDB','MSOLEDBSQL') })) {
                New-SsaMatch $server.Name 'A non-SQL linked-server provider is configured; establish database usage and replace unsupported dependencies.' -Review
            }
        }
        ServerAudits { $rows = @(Get-SsaEvidenceRows $Bundle 'Audits' '') }
        ServerCredentials { $rows = @(Get-SsaEvidenceRows $Bundle 'Credentials' '') }
        ServerScopedTriggers { $rows = @(Get-SsaEvidenceRows $Bundle 'Triggers' '') }
        ServiceBroker { $rows = @(Get-SsaEvidenceRows $Bundle 'Broker' $name) }
        WindowsAuthentication {
            $rows = @(Get-SsaEvidenceRows $Bundle 'Principals' '')
            foreach ($db in $Bundle.Databases) { $rows += @(Get-SsaEvidenceRows $Bundle 'DatabasePrincipals' $db.Name) }
            foreach ($principal in $rows) {
                New-SsaMatch $principal.Name 'Windows authentication is a non-blocking migration warning. Plan supported identity mapping and validate access on the target.'
            }
            $rows = @()
        }
        CryptographicProvider {
            foreach ($provider in @(Get-SsaEvidenceRows $Bundle 'Providers' '')) {
                New-SsaMatch $provider.Name 'A cryptographic provider is configured at instance scope; verify which database keys and applications depend on it.' -Review
            }
        }
        DbCompatLevelLowerThan100 {
            if ($Database.CompatibilityLevel -lt 100) { New-SsaMatch $name 'The database compatibility level must be raised and application behavior retested.' }
        }
        MultipleLogFiles {
            $logs = @(Get-SsaEvidenceRows $Bundle 'Files' $name | Where-Object { $_.Type -eq 'LOG' })
            if ($logs.Count -gt 1) { New-SsaMatch $name 'Multiple log files require migration-method validation and consolidation before unsupported restore paths.' }
        }
        SQLDBDatabaseSize {
            $limit = ($Catalog.SqlDatabase | Measure-Object MaxDataGB -Maximum).Maximum
            if ($null -ne $Database.DataMB -and $Database.DataMB / 1024 -gt $limit) { New-SsaMatch $name 'Data capacity exceeds every SQL Database configuration in the current supported catalog.' }
        }
        MIDatabaseSize {
            $limit = ($Catalog.ManagedInstance | Measure-Object MaxDataGB -Maximum).Maximum
            if ($null -ne $Database.DataMB -and ($Database.DataMB + $Database.LogMB) / 1024 -gt $limit) { New-SsaMatch $name 'Database storage exceeds every Managed Instance configuration in the supported catalog.' }
        }
        MIInstanceSize {
            $total = 0.0
            foreach ($db in $Bundle.Databases) { $total += ([double]$db.DataMB + [double]$db.LogMB) / 1024 }
            if ($total -gt ($Catalog.ManagedInstance | Measure-Object MaxDataGB -Maximum).Maximum) { New-SsaMatch $Bundle.Source.Instance 'Aggregate storage exceeds the supported Managed Instance catalog.' }
        }
        NumDbExceeds500 {
            if (@($Bundle.Databases).Count -gt ($Catalog.ManagedInstance | Measure-Object MaxDatabases -Maximum).Maximum) { New-SsaMatch $Bundle.Source.Instance 'Database count exceeds the supported Managed Instance catalog.' }
        }
        CrossDatabaseReferences {
            foreach ($dependency in @(Get-SsaEvidenceRows $Bundle 'Dependencies' $name)) {
                if ($dependency.DatabaseName -and $dependency.DatabaseName -ne $name) { New-SsaMatch $dependency.Object 'A catalog dependency references another database.' }
            }
            foreach ($synonym in @(Get-SsaEvidenceRows $Bundle 'Synonyms' $name)) {
                if ($synonym.BaseObject -match '^[^\.]+\.[^\.]+\.[^\.]+') { New-SsaMatch $synonym.Name 'A multipart synonym requires target-specific dependency resolution.' -Review }
            }
        }
        TraceFlags {
            $supportedMiFlags = @((Read-SsaJson (Join-Path $script:SsaModuleRoot 'Rules\rules.json')).ManagedInstanceTraceFlags.Global)
            foreach ($flag in @(Get-SsaEvidenceRows $Bundle 'TraceFlags' '')) {
                if ((Get-SsaValue $flag 'Status' 1) -ne 1) { continue }
                $id = Get-SsaValue $flag 'TraceFlag' '?'
                $scopeKnown = $null -ne (Get-SsaValue $flag 'Global') -and $null -ne (Get-SsaValue $flag 'Session')
                if ($Rule.Target -eq 'ManagedInstance' -and $scopeKnown -and $flag.Global -eq 1 -and $flag.Session -eq 0 -and $id -in $supportedMiFlags) { continue }
                New-SsaMatch ("Trace flag " + $id) 'This active flag is unsupported on the target or its scope needs verification against the versioned target allowlist.' -Review:($Rule.Target -eq 'ManagedInstance' -and -not $scopeKnown)
            }
        }
        TransactSqlJob {
            $jobRules = @(Get-SsaAssessmentRule -Target ManagedInstance | Where-Object RuleId -NE TransactSqlJob)
            foreach ($analysis in $Analyses) {
                if ($analysis.Source -ne 'Job') { continue }
                foreach ($jobRule in $jobRules) {
                    foreach ($hit in @(Get-SsaSyntaxMatch $jobRule @($analysis) $Bundle $analysis.Database)) {
                        New-SsaMatch $analysis.Object ("A T-SQL Agent step requires remediation or review for " + $jobRule.RuleId + '.') $hit.Line -Review:$hit.Review
                    }
                }
            }
        }
    }
    foreach ($row in $rows) { New-SsaMatch ([string](Get-SsaValue $row 'Name' $name)) ("Source evidence requires remediation or migration planning for " + $Rule.RuleId + '.') }
    Get-SsaSyntaxMatch $Rule $Analyses $Bundle $name
}

function Invoke-SsaRules {
    param($Bundle, [int]$TargetSqlMajorVersion = 0, [string]$TargetSqlEdition)
    $catalog = Get-SsaCatalog
    $analyses = New-Object 'System.Collections.Generic.List[object]'
    foreach ($definition in $Bundle.Definitions) {
        $syntax = [pscustomobject]@{ Hits = @(); Errors = @(); Incomplete = $true; BulkDataSources = @() }
        if (-not $definition.Encrypted -and $definition.Text) { $syntax = Read-SsaSyntax $definition.Text $Bundle.Source.VersionMajor }
        $analyses.Add([pscustomobject]@{ Database = $definition.Database; Object = $definition.Object; Source = $definition.Source; Syntax = $syntax })
    }
    $findings = New-Object 'System.Collections.Generic.List[object]'
    $evaluations = New-Object 'System.Collections.Generic.List[object]'
    foreach ($rule in @(Get-SsaAssessmentRule -Target SqlDatabase,ManagedInstance)) {
        $scopes = @($null)
        if ($rule.Scope -eq 'Database') { $scopes = @($Bundle.Databases) }
        if (-not $scopes.Count) {
            $state = 'NotApplicable'
            if (-not (Test-SsaEvidenceComplete $Bundle 'Databases' '')) { $state = 'NeedsReview' }
            $evaluations.Add([pscustomobject]@{ Target = $rule.Target; RuleId = $rule.RuleId; Database = ''; Status = $state; Category = $rule.Category; Message = 'No visible user databases; check inventory completeness.'; SourceUrl = $rule.SourceUrl })
        }
        foreach ($database in $scopes) {
            $dbName = ''; if ($database) { $dbName = $database.Name }
            $selected = @($analyses | Where-Object {
                (-not $dbName -or $_.Database -eq $dbName) -and
                ($_.Source -ne 'Job' -or $rule.RuleId -eq 'TransactSqlJob')
            })
            $incomplete = $false
            foreach ($kind in $rule.RequiredEvidence) { if (-not (Test-SsaEvidenceComplete $Bundle $kind $dbName)) { $incomplete = $true } }
            if ('Definitions' -in $rule.RequiredEvidence -and @($selected | Where-Object { $_.Syntax.Incomplete }).Count) { $incomplete = $true }
            if ($database -and $database.State -ne 'ONLINE') { $incomplete = $true }
            if ($rule.RuleId -eq 'TransactSqlJob' -and @($selected | Where-Object { $_.Source -eq 'Job' -and $_.Syntax.Incomplete }).Count) { $incomplete = $true }
            $matches = @(Get-SsaRuleMatches $rule $Bundle $database $selected $catalog)
            $state = 'Pass'
            if ($matches.Count) { $state = 'Finding' }
            elseif ($incomplete) { $state = 'NeedsReview' }
            $evaluations.Add([pscustomobject]@{ Target = $rule.Target; RuleId = $rule.RuleId; Database = $dbName; Status = $state; Category = $rule.Category; Message = $(if ($matches.Count) { 'See findings and evidence limitations.' } elseif ($incomplete) { 'Required evidence is missing, inaccessible, encrypted, or not fully parseable.' } else { 'No incompatible usage detected in the collected evidence; application-only queries remain outside coverage.' }); SourceUrl = $rule.SourceUrl })
            if ($matches.Count -and $incomplete) {
                $evaluations.Add([pscustomobject]@{ Target = $rule.Target; RuleId = $rule.RuleId; Database = $dbName; Status = 'NeedsReview'; Category = 'Warning'; Message = 'Positive findings exist, but evidence coverage is incomplete.'; SourceUrl = $rule.SourceUrl })
            }
            foreach ($match in $matches) {
                $category = $rule.Category
                if ($match.Review) { $category = 'Warning' }
                $findings.Add([pscustomobject]@{
                    Target = $rule.Target; RuleId = $rule.RuleId; Category = $category; PublishedCategory = $rule.Category
                    Scope = $rule.Scope; Database = $dbName; Object = $match.Object; Line = $match.Line
                    Message = $match.Message; Remediation = $rule.Remediation; SourceUrl = $rule.SourceUrl
                })
                if ($match.Review -and -not $incomplete) {
                    $evaluations.Add([pscustomobject]@{ Target = $rule.Target; RuleId = $rule.RuleId; Database = $dbName; Status = 'NeedsReview'; Category = 'Warning'; Message = $match.Message; SourceUrl = $rule.SourceUrl })
                }
            }
        }
    }
    $serverDefinitions = @($analyses | Where-Object Source -EQ ServerTrigger)
    foreach ($rule in @(Get-SsaAssessmentRule -Target SqlDatabase,ManagedInstance | Where-Object Scope -EQ Database)) {
        foreach ($match in @(Get-SsaSyntaxMatch $rule $serverDefinitions $Bundle 'master')) {
            $category = $rule.Category; $status = 'Finding'
            if ($match.Review) { $category = 'Warning'; $status = 'NeedsReview' }
            $findings.Add([pscustomobject]@{
                Target=$rule.Target;RuleId=$rule.RuleId;Category=$category;PublishedCategory=$rule.Category
                Scope='Instance';Database='master';Object=$match.Object;Line=$match.Line
                Message=$match.Message;Remediation=$rule.Remediation;SourceUrl=$rule.SourceUrl
            })
            $evaluations.Add([pscustomobject]@{
                Target=$rule.Target;RuleId=$rule.RuleId;Database='master';Status=$status
                Category=$category;Message='Server-trigger executable SQL is assessed at instance scope.';SourceUrl=$rule.SourceUrl
            })
        }
    }
    $vm = Invoke-SsaVmRules $Bundle $TargetSqlMajorVersion $TargetSqlEdition $catalog
    foreach ($item in $vm.Findings) { $findings.Add($item) }
    foreach ($item in $vm.Evaluations) { $evaluations.Add($item) }
    foreach ($target in @('SqlDatabase','ManagedInstance')) {
        $evaluations.Add([pscustomobject]@{
            Target = $target; RuleId = 'Supplemental.RuntimeQueryCoverage'; Database = ''; Status = 'NeedsReview'; Category = 'Warning'
            Message = 'Application-only statements and runtime-built SQL are not captured by this read-only assessment. Review application query coverage before migration.'
            SourceUrl = 'https://learn.microsoft.com/en-us/data-migration/sql-server/pre-migration'
        })
    }
    [pscustomobject]@{ Findings = $findings.ToArray(); Evaluations = $evaluations.ToArray() }
}

function Invoke-SsaVmRules {
    param($Bundle, [int]$TargetSqlMajorVersion, [string]$TargetSqlEdition, $Catalog)
    $findings = New-Object 'System.Collections.Generic.List[object]'
    $evaluations = New-Object 'System.Collections.Generic.List[object]'
    $major = $TargetSqlMajorVersion
    if (-not $major) { $major = $Bundle.Source.VersionMajor }
    if (-not $TargetSqlEdition) { $TargetSqlEdition = $Bundle.Source.Edition }
    $supported = @($Catalog.Vm | Where-Object { $major -in $_.SqlMajorVersions }).Count -gt 0
    foreach ($rule in @(Get-SsaAssessmentRule -Target SqlVm)) {
        $status = 'Pass'; $message = 'No issue detected within the explicitly scoped VM rule.'
        switch ($rule.RuleId) {
            VmEngineVersion {
                if ($major -lt $Bundle.Source.VersionMajor -or -not $supported) { $status = 'Finding'; $message = 'Engine downgrade or an uncataloged target version is not supported.' }
                elseif ($major -gt $Bundle.Source.VersionMajor) { $status = 'NeedsReview'; $message = 'Upgrade requested: validate the documented direct upgrade path, breaking changes, and application regression tests. This module does not claim exhaustive Upgrade Advisor coverage.' }
            }
            VmCompatibilityLevel {
                $minimum = 100; if ($major -eq 11) { $minimum = 90 }
                foreach ($db in $Bundle.Databases) { if ($db.CompatibilityLevel -lt $minimum -or $db.CompatibilityLevel -gt $major * 10) { $status = 'Finding'; $message = 'One or more compatibility levels are outside the cataloged target engine range.' } }
            }
            VmEditionFeatures {
                foreach ($db in $Bundle.Databases) {
                    if (-not (Test-SsaEvidenceComplete $Bundle 'SkuFeatures' $db.Name)) { $status = 'NeedsReview'; $message = 'Edition-dependent feature evidence is incomplete.' }
                    $features = @(Get-SsaEvidenceRows $Bundle 'SkuFeatures' $db.Name)
                    if ($features.Count -and $TargetSqlEdition -notmatch 'Enterprise|Developer') { $status = 'NeedsReview'; $message = 'Persisted features require version-specific edition validation; no automatic downgrade is assumed.' }
                }
            }
            VmInstanceDependencies {
                $count = 0
                foreach ($kind in @('Jobs','Principals','LinkedServers','Credentials','Triggers','Providers')) { $count += @(Get-SsaEvidenceRows $Bundle $kind '').Count; if (-not (Test-SsaEvidenceComplete $Bundle $kind '')) { $status = 'NeedsReview' } }
                if ($count) { $status = 'NeedsReview' }
                if ($status -eq 'NeedsReview') { $message = 'Instance objects must be migrated/validated separately; incomplete inventories cannot establish absence.' }
            }
            VmExternalDependencies { $status = 'NeedsReview'; $message = 'Validate external files, providers, shares, identities, services, and OS dependencies on the proposed VM.' }
            VmMigrationPrerequisites { $status = 'NeedsReview'; $message = 'Migration method, backup chain, encryption keys, target networking, and restore prerequisites require operator validation.' }
        }
        $evaluations.Add([pscustomobject]@{ Target = 'SqlVm'; RuleId = $rule.RuleId; Database = ''; Status = $status; Category = $rule.Category; Message = $message; SourceUrl = $rule.SourceUrl })
        if ($status -eq 'Finding') {
            $findings.Add([pscustomobject]@{ Target = 'SqlVm'; RuleId = $rule.RuleId; Category = $rule.Category; PublishedCategory = $rule.Category; Scope = 'Instance'; Database = ''; Object = $Bundle.Source.Instance; Line = 0; Message = $message; Remediation = $rule.Remediation; SourceUrl = $rule.SourceUrl })
        }
    }
    [pscustomobject]@{ Findings = $findings.ToArray(); Evaluations = $evaluations.ToArray() }
}
