[CmdletBinding()]
param(
    [string]$OutputPath = (Join-Path (Split-Path $PSScriptRoot -Parent) 'artifacts\sample'),
    [switch]$RefreshPrices
)
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
Import-Module (Join-Path $root 'src\SimpleSqlAssessment\SimpleSqlAssessment.psd1') -Force
. (Join-Path $root 'tests\TestHelpers.ps1')
$module = Get-Module SimpleSqlAssessment
$OutputPath = [IO.Path]::GetFullPath($OutputPath)
if ((Test-Path -LiteralPath $OutputPath) -and @(Get-ChildItem -LiteralPath $OutputPath -Force).Count) {
    throw 'Choose a new or empty output directory; existing sample artifacts will not be replaced.'
}
$collection = Join-Path $OutputPath 'collection'
$bundle = New-TestBundle
$bundle.CollectionId = [guid]::NewGuid().ToString()
$bundle.Source.Instance = 'SYNTHETIC DEMO - NOT A REAL ASSESSMENT'
$bundle.Source.ComputerName = 'synthetic-host'
$bundle.Source | Add-Member NoteProperty PhysicalMemoryGB 32
$bundle.Databases[0].DataMB = 51200
$bundle.Databases[0].LogMB = 10240
$bundle.Definitions = @([pscustomobject]@{
    Database='App';Object='dbo.SyntheticLegacyExport';Encrypted=$false;Source='Module'
    Text="CREATE PROCEDURE dbo.SyntheticLegacyExport AS EXEC master.dbo.xp_cmdshell 'echo synthetic example'; SELECT * FROM OtherDb.dbo.Example;"
})
Set-TestEvidence $bundle 'Definitions' $bundle.Definitions 'App'
Set-TestEvidence $bundle 'LinkedServers' @([pscustomobject]@{Name='SyntheticRemote';Provider='MSOLEDBSQL'})
$start = [datetime]::UtcNow.AddDays(-2)
$bundle.CollectedAt = $start.ToString('o')
$bundle.Diagnostics = @([pscustomobject]@{
    Code='SyntheticExample'
    Message='SYNTHETIC EXAMPLE ONLY. No SQL source was contacted. Capture is partial, contains an intentional gap, and is not a seven-day assessment. Any AHB scenario is an illustrative entitlement assumption.'
})
$null = Save-TestBundle $collection $bundle
$previous = $null; $usable = 0.0
foreach ($index in 0..288) {
    $second = $index*300
    if ($index -ge 120) { $second += 3600 }
    $raw = New-TestRawSample $second
    $raw.Timestamp = $start.AddSeconds($second).ToString('o')
    $raw.MemoryGB = 6 + [Math]::Abs([Math]::Sin($index/18.0))*3
    $raw | Add-Member NoteProperty HostUsedMemoryGB (12+$raw.MemoryGB)
    $raw.Windows.UsedCores = 0.5+[Math]::Abs([Math]::Sin($index/13.0))*2
    $raw.Windows.CpuPercent = $raw.Windows.UsedCores/4*100
    $raw.Windows.HostCpuPercent = $raw.Windows.CpuPercent+10
    ($raw.Files | Where-Object DatabaseId -EQ 5).SizeMB = 51200
    ($raw.Files | Where-Object DatabaseId -EQ 2).SizeMB = 4096
    $raw.Files += [pscustomobject]@{
        DatabaseId=5;DatabaseName='App';FileId=2;FileGuid='synthetic-log';Type='LOG';SizeMB=10240
        Reads=0;Writes=$second*100L;ReadBytes=0;WriteBytes=$second*1048576L
        ReadStallMs=0;WriteStallMs=$second*1L
    }
    $sample = & $module {param($a,$b) ConvertTo-SsaRateSample $a $b 300} $previous $raw
    $usable += $sample.UsableSeconds
    & $module {
        param($collection,$bundle,$raw,$sample,$sequence)
        $payload = ConvertTo-Json -InputObject ([pscustomobject]@{Raw=$raw;Sample=$sample}) -Depth 30 -Compress
        Write-SsaJson (Join-Path $collection ('performance\sample-{0:D10}.json' -f $sequence)) ([pscustomobject]@{
            SchemaVersion='1.0';Sequence=$sequence;CollectionId=$bundle.CollectionId;Sha256=Get-SsaHash $payload;Payload=$payload
        })
    } $collection $bundle $raw $sample ($index+1)
    $previous = $raw
}
& $module {
    param($collection,$bundle,$start,$usable)
    Write-SsaJson (Join-Path $collection 'capture.json') ([pscustomobject]@{
        SchemaVersion='1.0';CollectionId=$bundle.CollectionId;State='Interrupted';RequestedSeconds=604800
        UsableSeconds=$usable;StartedAt=$start.ToString('o');LastSequence=289;SampleIntervalSeconds=300
        ConfigurationHash=Get-SsaHash ('{0:R}|{1:R}' -f [double]604800,[double]300)
    })
} $collection $bundle $start $usable
$result = Invoke-SsaAssessment -CollectionPath $collection -OutputPath $OutputPath `
    -Region eastus -Offline -SqlHybridBenefit -WindowsHybridBenefit -TargetSqlMajorVersion 16
if ($RefreshPrices) {
    $items = @($result.Recommendations | Where-Object Status -NE Unavailable)
    $result.Prices = @(Get-SsaPriceEstimate -Recommendation $items -Region eastus `
        -SqlHybridBenefit -WindowsHybridBenefit -CachePath (Join-Path $OutputPath 'pricing-cache'))
    & $module {param($assessment) Update-SsaTargetSummary $assessment} $result
    $result.OutputFiles = Export-SsaAssessment -Assessment $result -OutputPath $OutputPath
}
Write-Host "Synthetic example: $($result.OutputFiles.HtmlPath)"
