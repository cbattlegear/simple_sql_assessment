[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$manifest = Get-Content -LiteralPath (Join-Path $root 'src\SimpleSqlAssessment\Rules\rules.json') -Raw | ConvertFrom-Json
foreach ($target in @('SqlDatabase','ManagedInstance')) {
    $url = $manifest.Sources.$target
    $page = Invoke-WebRequest -Uri $url -UseBasicParsing -TimeoutSec 30 -ErrorAction Stop
    $table = [regex]::Match($page.Content, '(?is)<h2\b[^>]*\bid=["'']rules-summary["''][^>]*>.*?<table\b[^>]*>(?<rules>.*?)</table>')
    if (-not $table.Success) { throw "The published summary format changed for $target. Review $url manually; no unchanged result can be established." }
    $published = @([regex]::Matches($table.Groups['rules'].Value,'(?is)<tr\b[^>]*>\s*<td\b[^>]*>\s*<code>(?<id>[A-Za-z][A-Za-z0-9]+)</code>') | ForEach-Object { $_.Groups['id'].Value } | Sort-Object -Unique)
    if (-not $published.Count) { throw "No published rule IDs could be read for $target." }
    $expected = @($manifest.Rules | Where-Object { $target -in $_.Targets } | ForEach-Object { $_.Id } | Sort-Object -Unique)
    $added = @($published | Where-Object { $_ -notin $expected })
    $removed = @($expected | Where-Object { $_ -notin $published })
    $status = 'Unchanged'
    if ($added.Count -or $removed.Count) { $status = 'NeedsReview'; Write-Warning "$target published rule inventory changed. Review detector, evidence, and fixture implications before updating the manifest." }
    [pscustomobject]@{Target=$target;Status=$status;SnapshotVersion=$manifest.Version;PublishedCount=$published.Count;Added=$added;Removed=$removed;SourceUrl=$url}
}
