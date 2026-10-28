BeforeDiscovery {
    $root = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
    $manifest = Get-Content -Raw (Join-Path $root 'src\SimpleSqlAssessment\Rules\rules.json') | ConvertFrom-Json
    $cases = @()
    foreach ($rule in $manifest.Rules) { foreach ($target in $rule.Targets) { $cases += @{ Id = $rule.Id; Target = $target } } }
}
BeforeAll {
    $root = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
    Import-Module (Join-Path $root 'src\SimpleSqlAssessment\SimpleSqlAssessment.psd1') -Force
    . (Join-Path (Split-Path $PSScriptRoot -Parent) 'TestHelpers.ps1')
    $script:module = Get-Module SimpleSqlAssessment
    $script:catalog = [pscustomobject]@{
        SqlDatabase = @([pscustomobject]@{ MaxDataGB = 1024 })
        ManagedInstance = @([pscustomobject]@{ MaxDataGB = 1024; MaxDatabases = 500 })
        Vm = @([pscustomobject]@{ SqlMajorVersions = @(16,17) })
    }
}
Describe 'Published rule accounting' {
    It 'retains exactly 30 DB and 34 MI mappings and 46 unique IDs' {
        @(Get-SsaAssessmentRule -Target SqlDatabase).Count | Should -Be 30
        @(Get-SsaAssessmentRule -Target ManagedInstance).Count | Should -Be 34
        @(Get-SsaAssessmentRule -Target SqlDatabase,ManagedInstance | Select-Object -ExpandProperty RuleId -Unique).Count | Should -Be 46
    }
    It 'detects observable positive evidence for <Target>/<Id>' -ForEach $cases {
        $bundle = New-TestBundle
        $rule = Get-SsaAssessmentRule -Target $Target | Where-Object RuleId -EQ $Id
        $text = 'SELECT 1;'; $source = 'Module'
        $global = @{ AgentJobs='Jobs'; DatabaseMail='Mail'; ServerAudits='Audits'; ServerCredentials='Credentials'; ServerScopedTriggers='Triggers'; WindowsAuthentication='Principals' }
        if ($global.ContainsKey($Id)) { Set-TestEvidence $bundle $global[$Id] @([pscustomobject]@{ Name = 'example' }) }
        $jobTypes = @{ AnalysisCommandJob='ANALYSISCOMMAND'; AnalysisQueryJob='ANALYSISQUERY'; MergeJob='Merge'; PowerShellJob='PowerShell'; QueueReaderJob='QueueReader' }
        if ($jobTypes.ContainsKey($Id)) { Set-TestEvidence $bundle 'Jobs' @([pscustomobject]@{ Name='Job'; Subsystem=$jobTypes[$Id] }) }
        switch ($Id) {
            AssemblyFromFile { $text = "CREATE ASSEMBLY A FROM 'C:\assembly.dll';" }
            BulkInsert { $text = "BULK INSERT dbo.T FROM 'C:\data.txt';" }
            ClrAssemblies { Set-TestEvidence $bundle 'Assemblies' @([pscustomobject]@{Name='Assembly';PermissionSet='SAFE_ACCESS'}) 'App' }
            ClrStrictSecurity { Set-TestEvidence $bundle 'Assemblies' @([pscustomobject]@{Name='Assembly';PermissionSet='SAFE_ACCESS'}) 'App' }
            ComputeClause { $text = 'SELECT a FROM dbo.T ORDER BY a COMPUTE SUM(a);' }
            CrossDatabaseReferences { $text = 'SELECT * FROM OtherDb.dbo.T;' }
            CryptographicProvider { $text = "CREATE CRYPTOGRAPHIC PROVIDER P FROM FILE='C:\provider.dll';" }
            DatabasePrincipalAlias { $text = 'SELECT * FROM sys.database_principal_aliases;' }
            DbCompatLevelLowerThan100 { $bundle.Databases[0].CompatibilityLevel = 90 }
            DisableDefCNSTCHK { $text = 'SET DISABLE_DEF_CNST_CHK ON;' }
            FastFirstRowHint { $text = 'SELECT * FROM dbo.T WITH (FASTFIRSTROW);' }
            FileStream { Set-TestEvidence $bundle 'FileStream' @([pscustomobject]@{Name='FileTable'}) 'App' }
            LinkedServer { Set-TestEvidence $bundle 'LinkedServers' @([pscustomobject]@{Name='Remote';Provider='MSOLEDBSQL'}) }
            LinkedServerWithNonSQLProvider { Set-TestEvidence $bundle 'LinkedServers' @([pscustomobject]@{Name='Remote';Provider='OraOLEDB.Oracle'}) }
            MIDatabaseSize { $bundle.Databases[0].DataMB=2097152 }
            MIHeterogeneousMSDTCTransactSQL { $text = 'BEGIN DISTRIBUTED TRANSACTION; COMMIT;' }
            MIHomogeneousMSDTCTransactSQL { $text = 'BEGIN DISTRIBUTED TRANSACTION; COMMIT;' }
            MIInstanceSize { $bundle.Databases[0].DataMB=2097152 }
            MSDTCTransactSQL { $text = 'BEGIN DISTRIBUTED TRANSACTION; COMMIT;' }
            MultipleLogFiles { Set-TestEvidence $bundle 'Files' @([pscustomobject]@{Type='LOG'},[pscustomobject]@{Type='LOG'}) 'App' }
            NextColumn { $text = 'SELECT NEXT VALUE FROM dbo.T;' }
            NonANSILeftOuterJoinSyntax { $text = 'SELECT * FROM a,b WHERE a.id *= b.id;' }
            NonANSIRightOuterJoinSyntax { $text = 'SELECT * FROM a,b WHERE a.id =* b.id;' }
            NumDbExceeds500 { $bundle.Databases = @(1..501 | ForEach-Object { [pscustomobject]@{Name="D$_";DataMB=1;LogMB=1} }) }
            OpenRowsetWithNonBlobDataSourceBulk { $text = "SELECT * FROM OPENROWSET(BULK 'C:\file.txt', SINGLE_BLOB) a;" }
            OpenRowsetWithNonSQLProvider { $text = "SELECT * FROM OPENROWSET('OraOLEDB.Oracle','x','select 1') a;" }
            OpenRowsetWithSQLAndNonSQLProvider { $text = "SELECT * FROM OPENROWSET('MSOLEDBSQL','x','select 1') a;" }
            RAISERROR { $text = "RAISERROR 50001 'legacy';" }
            ServiceBroker { Set-TestEvidence $bundle 'Broker' @([pscustomobject]@{Name='UserService'}) 'App' }
            SQLDBDatabaseSize { $bundle.Databases[0].DataMB=2097152 }
            SqlMail { $text = "EXEC xp_sendmail 'recipient';" }
            SystemProcedures110 { $text = "EXEC sp_dboption 'App','auto close','false';" }
            TraceFlags { Set-TestEvidence $bundle 'TraceFlags' @([pscustomobject]@{TraceFlag=1117}) }
            TransactSqlJob { $text = "EXEC xp_cmdshell 'echo';"; $source = 'Job' }
            XpCmdshell { $text = "EXEC xp_cmdshell 'echo';" }
        }
        $syntax = & $script:module { param($text) Read-SsaSyntax $text 11 } $text
        $analyses = @([pscustomobject]@{ Database='App';Object='dbo.Procedure';Source=$source;Syntax=$syntax })
        $matches = @(& $script:module { param($rule,$bundle,$analyses,$catalog) Get-SsaRuleMatches $rule $bundle $bundle.Databases[0] $analyses $catalog } $rule $bundle $analyses $script:catalog)
        $matches.Count | Should -BeGreaterThan 0
    }
    It 'does not flag clean evidence for <Target>/<Id>' -ForEach $cases {
        $bundle = New-TestBundle
        $rule = Get-SsaAssessmentRule -Target $Target | Where-Object RuleId -EQ $Id
        $syntax = & $script:module { Read-SsaSyntax "SELECT 'xp_cmdshell COMPUTE FASTFIRSTROW' AS [COMPUTE]; -- BEGIN DISTRIBUTED TRANSACTION" 11 }
        $analyses = @([pscustomobject]@{Database='App';Object='dbo.Clean';Source='Module';Syntax=$syntax})
        $matches = @(& $script:module {param($r,$b,$a,$c) Get-SsaRuleMatches $r $b $b.Databases[0] $a $c} $rule $bundle $analyses $script:catalog)
        $matches.Count | Should -Be 0
    }
    It 'does not pass missing required evidence for <Target>/<Id>' -ForEach $cases {
        Mock Get-SsaCatalog -ModuleName SimpleSqlAssessment {
            [pscustomobject]@{SqlDatabase=@([pscustomobject]@{MaxDataGB=1024});ManagedInstance=@([pscustomobject]@{MaxDataGB=1024;MaxDatabases=500});Vm=@([pscustomobject]@{SqlMajorVersions=@(16,17)})}
        }
        $bundle = New-TestBundle
        $rule = Get-SsaAssessmentRule -Target $Target | Where-Object RuleId -EQ $Id
        $kind = $rule.RequiredEvidence[0]
        foreach ($entry in @($bundle.Evidence | Where-Object Kind -EQ $kind)) { $entry.Status = 'Error' }
        $evaluation = & $script:module {param($b) Invoke-SsaRules $b} $bundle
        @($evaluation.Evaluations | Where-Object { $_.Target -eq $Target -and $_.RuleId -eq $Id -and $_.Status -eq 'NeedsReview' }).Count | Should -BeGreaterThan 0
        @($evaluation.Evaluations | Where-Object { $_.Target -eq $Target -and $_.RuleId -eq $Id -and $_.Status -eq 'Pass' }).Count | Should -Be 0
    }
}
Describe 'T-SQL evidence boundaries' {
    It 'finds constant dynamic SQL but exposes unresolved sp_executesql' {
        $constant = & $script:module { Read-SsaSyntax "EXEC('EXEC xp_cmdshell ''echo''');" 11 }
        @($constant.Hits | Where-Object { $_.Kind -eq 'Procedure' -and $_.Value -eq 'xp_cmdshell' }).Count | Should -Be 1
        $dynamic = & $script:module { Read-SsaSyntax 'EXEC sp_executesql @statement;' 11 }
        $dynamic.Incomplete | Should -BeTrue
    }
    It 'does not confuse modern RAISERROR or NEXT VALUE FOR with legacy syntax' {
        $syntax = & $script:module { Read-SsaSyntax "RAISERROR ('error',16,1); SELECT NEXT VALUE FOR dbo.Sequence;" 11 }
        @($syntax.Hits | Where-Object { $_.Kind -in @('RAISERROR','NextColumn') }).Count | Should -Be 0
    }
    It 'does not mistake column names or assembly file removal for incompatible constructs' {
        $syntax = & $script:module { Read-SsaSyntax "SELECT FASTFIRSTROW, sys.database_principal_aliases FROM dbo.T sys; ALTER ASSEMBLY A DROP FILE 'example';" 11 }
        @($syntax.Hits | Where-Object { $_.Kind -in @('FastFirstRowHint','DatabasePrincipalAlias','AssemblyFromFile') }).Count | Should -Be 0
    }
    It 'detects database and server references in procedure and function calls' {
        $syntax = & $script:module { Read-SsaSyntax 'EXEC OtherDb.dbo.P; SELECT OtherDb.dbo.F(); SELECT * FROM Remote.OtherDb.dbo.T;' 11 }
        @($syntax.Hits | Where-Object { $_.Kind -eq 'CrossDatabase' -and $_.Value -eq 'OtherDb' }).Count | Should -Be 3
        @($syntax.Hits | Where-Object Kind -EQ LinkedServer).Count | Should -Be 1
    }
    It 'treats variable procedure names as incomplete evidence rather than crashing' {
        $syntax = & $script:module { Read-SsaSyntax 'EXEC @procedure;' 11 }
        $syntax.Incomplete | Should -BeTrue
    }
    It 'accepts a fully qualified Azure Blob URI for bulk operations' {
        $bundle = New-TestBundle
        foreach ($case in @(
            @{Id='BulkInsert';Sql="BULK INSERT dbo.T FROM 'https://example.blob.core.windows.net/container/file.csv';"},
            @{Id='OpenRowsetWithNonBlobDataSourceBulk';Sql="SELECT * FROM OPENROWSET(BULK 'https://example.blob.core.windows.net/container/file.csv', SINGLE_BLOB) b;"}
        )) {
            $rule = Get-SsaAssessmentRule -Target ManagedInstance | Where-Object RuleId -EQ $case.Id
            $syntax = & $script:module {param($text) Read-SsaSyntax $text 16} $case.Sql
            $analyses = @([pscustomobject]@{Database='App';Object='dbo.Import';Source='Module';Syntax=$syntax})
            @(& $script:module {param($r,$b,$a,$c) Get-SsaRuleMatches $r $b $b.Databases[0] $a $c} $rule $bundle $analyses $script:catalog).Count | Should -Be 0
        }
    }
    It 'does not classify a configured but unlinked instance dependency as a proven database blocker' {
        $bundle = New-TestBundle
        Set-TestEvidence $bundle 'LinkedServers' @([pscustomobject]@{Name='Remote';Provider='MSOLEDBSQL'})
        $rule = Get-SsaAssessmentRule -Target SqlDatabase | Where-Object RuleId -EQ LinkedServer
        $matches = @(& $script:module {param($r,$b,$c) Get-SsaRuleMatches $r $b $b.Databases[0] @() $c} $rule $bundle $script:catalog)
        $matches.Count | Should -Be 1
        $matches[0].Review | Should -BeTrue
    }
    It 'allows documented MI global flags but rejects session scope and undocumented flags' {
        $bundle = New-TestBundle
        $rule = Get-SsaAssessmentRule -Target ManagedInstance | Where-Object RuleId -EQ TraceFlags
        Set-TestEvidence $bundle 'TraceFlags' @([pscustomobject]@{TraceFlag=460;Status=1;Global=1;Session=0})
        foreach ($case in @(
            @{Sql='DBCC TRACEON(460,2389,-1);';Count=0},
            @{Sql='DBCC TRACEON(460);';Count=1},
            @{Sql='DBCC TRACEON(1117,-1);';Count=1}
        )) {
            $syntax = & $script:module {param($text) Read-SsaSyntax $text 16} $case.Sql
            $analyses = @([pscustomobject]@{Database='App';Object='dbo.Flags';Source='Module';Syntax=$syntax})
            @(& $script:module {param($r,$b,$a,$c) Get-SsaRuleMatches $r $b $null $a $c} $rule $bundle $analyses $script:catalog).Count | Should -Be $case.Count
        }
        Set-TestEvidence $bundle 'TraceFlags' @([pscustomobject]@{TraceFlag=460;Status=1;Global=0;Session=1})
        @(& $script:module {param($r,$b,$c) Get-SsaRuleMatches $r $b $null @() $c} $rule $bundle $script:catalog).Count | Should -Be 1
    }
    It 'uses shared target-specific detectors for T-SQL jobs outside user database context' {
        $bundle = New-TestBundle
        $rule = Get-SsaAssessmentRule -Target ManagedInstance | Where-Object RuleId -EQ TransactSqlJob
        $syntax = & $script:module { Read-SsaSyntax "EXEC master.dbo.sp_dboption 'App','auto close','false'; DBCC TRACEON(460,-1);" 16 }
        $analyses = @([pscustomobject]@{Database='master';Object='Job:1';Source='Job';Syntax=$syntax})
        $matches = @(& $script:module {param($r,$b,$a,$c) Get-SsaRuleMatches $r $b $null $a $c} $rule $bundle $analyses $script:catalog)
        $matches.Count | Should -Be 1
        $matches[0].Message | Should -BeLike '*SystemProcedures110*'
    }
    It 'evaluates incompatible server-trigger SQL once at instance scope' {
        $bundle = New-TestBundle
        $bundle.Definitions = @([pscustomobject]@{
            Database='master';Object='AuditTrigger';Encrypted=$false;Source='ServerTrigger'
            Text="CREATE TRIGGER AuditTrigger ON ALL SERVER FOR CREATE_DATABASE AS EXEC master.dbo.xp_cmdshell 'echo';"
        })
        $result = & $script:module {param($b) Invoke-SsaRules $b} $bundle
        $hits = @($result.Findings | Where-Object { $_.Target -eq 'ManagedInstance' -and $_.RuleId -eq 'XpCmdshell' })
        $hits.Count | Should -Be 1
        $hits[0].Scope | Should -Be Instance
        $hits[0].Category | Should -Be Issue
    }
}
