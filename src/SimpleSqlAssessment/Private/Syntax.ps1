function Read-SsaSyntax {
    param([AllowEmptyString()][string]$Text, [int]$VersionMajor = 11, [int]$Depth = 0)
    Initialize-SsaSqlLibrary
    if (-not ('SimpleSqlAssessment.SqlVisitor' -as [type])) {
        $assembly = [Microsoft.SqlServer.TransactSql.ScriptDom.TSqlParser].Assembly.Location
        $references = @($assembly)
        $compiler = @{}
        if ($PSVersionTable.PSEdition -eq 'Core') {
            $references += Join-Path $PSHOME 'ref\System.Collections.dll'
            $compiler.CompilerOptions = '/nowarn:1701'
        }
        Add-Type -Path (Join-Path $script:SsaModuleRoot 'Private\SqlVisitor.cs') -ReferencedAssemblies $references @compiler -ErrorAction Stop
    }
    $version = [Math]::Min(170, [Math]::Max(110, $VersionMajor * 10))
    $parser = New-Object ("Microsoft.SqlServer.TransactSql.ScriptDom.TSql{0}Parser" -f $version)($true)
    $errors = New-Object 'System.Collections.Generic.List[Microsoft.SqlServer.TransactSql.ScriptDom.ParseError]'
    $reader = New-Object IO.StringReader($Text)
    try { $tree = $parser.Parse($reader, [ref]$errors) } finally { $reader.Dispose() }
    $visitor = New-Object SimpleSqlAssessment.SqlVisitor
    $tree.Accept($visitor)
    $hits = New-Object 'System.Collections.Generic.List[object]'
    foreach ($hit in $visitor.Hits) {
        if ($hit.Kind -eq 'DynamicConstant' -and $Depth -lt 3) {
            $nested = Read-SsaSyntax -Text $hit.Value -VersionMajor $VersionMajor -Depth ($Depth + 1)
            foreach ($nestedHit in $nested.Hits) { $hits.Add($nestedHit) }
            if ($nested.Incomplete) { $hits.Add([pscustomobject]@{ Kind = 'DynamicGap'; Value = 'Constant dynamic SQL could not be fully parsed.'; Line = $hit.Line }) }
        } elseif ($hit.Kind -eq 'DynamicConstant') {
            $hits.Add([pscustomobject]@{ Kind = 'DynamicGap'; Value = 'Dynamic SQL nesting limit reached.'; Line = $hit.Line })
        } else {
            $hits.Add($hit)
            if ($hit.Kind -eq 'Procedure' -and $hit.Value -eq 'sp_executesql') {
                $hits.Add([pscustomobject]@{ Kind = 'DynamicGap'; Value = 'sp_executesql requires runtime parameter/context verification.'; Line = $hit.Line })
            }
        }
    }
    $tokens = @($tree.ScriptTokenStream | Where-Object { $_.TokenType.ToString() -notin @('WhiteSpace','SingleLineComment','MultilineComment','EndOfFile') })
    $words = @($tokens | ForEach-Object {
        if ($_.TokenType.ToString() -match 'StringLiteral') { '<literal>' }
        else { $_.Text.Trim('[', ']', '"').ToUpperInvariant() }
    })
    for ($i = 0; $i -lt $words.Count; $i++) {
        $word = $words[$i]
        if ($tokens[$i].TokenType.ToString() -eq 'QuotedIdentifier' -and $word -notin @('NEXT','SYS','DATABASE_PRINCIPAL_ALIASES')) { continue }
        $next = ''; if ($i + 1 -lt $words.Count) { $next = $words[$i + 1] }
        $kind = $null; $value = $word
        if ($word -eq 'COMPUTE') { $kind = 'ComputeClause' }
        elseif ($word -eq 'FASTFIRSTROW' -and $i -gt 0 -and 'WITH' -in @($words | Select-Object -Skip ([Math]::Max(0,$i-3)) -First ([Math]::Min(3,$i)))) { $kind = 'FastFirstRowHint' }
        elseif ($word -eq 'DISABLE_DEF_CNST_CHK' -and $i -gt 0 -and $words[$i-1] -eq 'SET') { $kind = 'DisableDefCNSTCHK' }
        elseif ($word -eq '*=' -or ($word -eq '*' -and $next -eq '=')) { $kind = 'NonANSILeftOuterJoinSyntax' }
        elseif ($word -eq '=*' -or ($word -eq '=' -and $next -eq '*')) { $kind = 'NonANSIRightOuterJoinSyntax' }
        elseif ($word -eq 'RAISERROR' -and $next -ne '(') { $kind = 'RAISERROR' }
        elseif ($word -eq 'CRYPTOGRAPHIC' -and $next -eq 'PROVIDER') { $kind = 'CryptographicProvider' }
        elseif ($word -eq 'BEGIN' -and $next -eq 'DISTRIBUTED') { $kind = 'DistributedTransaction' }
        elseif ($word -eq 'NEXT' -and $next -eq 'VALUE' -and ($i + 2 -ge $words.Count -or $words[$i+2] -ne 'FOR')) { $kind = 'NextColumn' }
        elseif ($word -eq 'DBCC' -and $next -in @('TRACEON','TRACEOFF')) {
            $kind = 'TraceFlags'; $flags = @(); $globalMode = $false; $resolved = $true; $closed = $false
            for ($j = $i+2; $j -lt $tokens.Count; $j++) {
                if ($words[$j] -eq ')') { $closed = $true; break }
                if ($words[$j] -in @('(',',','-')) { continue }
                $number = 0
                if (-not [int]::TryParse($words[$j],[ref]$number)) { $resolved = $false; continue }
                if ($j -gt 0 -and $words[$j-1] -eq '-') {
                    if ($number -eq 1) { $globalMode = $true } else { $resolved = $false }
                } else { $flags += $number }
            }
            $value = 'Unknown:'
            if ($resolved -and $closed -and $flags.Count) {
                $mode = 'Session'; if ($globalMode) { $mode = 'Global' }
                $value = $mode + ':' + ($flags -join ',')
            }
        }
        elseif ($word -eq 'ASSEMBLY' -and $i -gt 0 -and $words[$i-1] -in @('CREATE','ALTER')) {
            for ($j = $i+1; $j -lt $tokens.Count-1; $j++) {
                if ($tokens[$j].Text -eq ';') { break }
                if ($words[$j] -eq 'FROM' -and $tokens[$j+1].TokenType.ToString() -match 'StringLiteral') { $kind = 'AssemblyFromFile'; break }
            }
        }
        if ($kind) { $hits.Add([pscustomobject]@{ Kind = $kind; Value = $value; Line = $tokens[$i].Line }) }
        if ($word -eq 'SP_EXECUTESQL') { $hits.Add([pscustomobject]@{ Kind = 'DynamicGap'; Value = 'sp_executesql requires runtime parameter/context verification.'; Line = $tokens[$i].Line }) }
    }
    $bulkSources = New-Object 'System.Collections.Generic.List[string]'
    for ($i = 0; $i -lt $words.Count - 2; $i++) {
        if ($words[$i] -eq 'DATA_SOURCE' -and $words[$i+1] -eq '=') {
            $bulkSources.Add($tokens[$i+2].Text.Trim("'", '"', '[', ']'))
        }
    }
    [pscustomobject]@{
        Hits = $hits.ToArray(); Errors = @($errors | ForEach-Object { [pscustomobject]@{ Number = $_.Number; Line = $_.Line } })
        Incomplete = ($errors.Count -gt 0 -or @($hits | Where-Object { $_.Kind -eq 'DynamicGap' }).Count -gt 0)
        BulkDataSources = $bulkSources.ToArray()
    }
}
