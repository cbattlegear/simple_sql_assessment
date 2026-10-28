function Test-SsaPrerequisite {
    [CmdletBinding()]
    param(
        [string]$SqlInstance, [pscredential]$Credential,
        [switch]$SkipPerformance, [switch]$TrustServerCertificate
    )
    $checks = New-Object 'System.Collections.Generic.List[object]'
    $checks.Add([pscustomobject]@{ Check = 'WindowsX64'; Passed = ($env:OS -eq 'Windows_NT' -and [Environment]::Is64BitProcess); Message = 'Windows x64 is required.' })
    try {
        Initialize-SsaSqlLibrary
        $checks.Add([pscustomobject]@{ Check = 'SqlLibraries'; Passed = $true; Message = 'Pinned SQL connectivity and ScriptDom libraries loaded.' })
    } catch {
        $checks.Add([pscustomobject]@{ Check = 'SqlLibraries'; Passed = $false; Message = $_.Exception.Message })
    }
    if ($SqlInstance) {
        $connection = $null
        try {
            $connection = New-SsaSqlConnection $SqlInstance 'master' $Credential -TrustServerCertificate:$TrustServerCertificate
            $source = Get-SsaSource $connection
            $checks.Add([pscustomobject]@{ Check = 'Source'; Passed = $true; Message = "$($source.Instance), SQL major version $($source.VersionMajor)." })
            if (-not $SkipPerformance) {
                $null = Get-SsaWindowsSample -ComputerName $source.ComputerName -SqlProcessId $source.SqlProcessId -LogicalProcessors $source.LogicalProcessors
                $checks.Add([pscustomobject]@{ Check = 'WindowsCounters'; Passed = $true; Message = 'Host and SQL process counters accessible.' })
            }
        } catch {
            $checks.Add([pscustomobject]@{ Check = 'SourceOrCounters'; Passed = $false; Message = $_.Exception.Message })
        } finally { if ($connection) { $connection.Dispose() } }
    }
    return $checks.ToArray()
}
