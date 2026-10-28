[CmdletBinding()]
param([switch]$RestoreDependencies, [switch]$Test, [switch]$Lint, [switch]$Package)
$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
$versions = Import-PowerShellDataFile (Join-Path $root 'dependencies.psd1')
$dependencyRoot = Join-Path $root '.dependencies'

function Find-BuildModule {
    param([string]$Name)
    $version = $versions[$Name]
    $installed = @(Get-Module -ListAvailable $Name | Where-Object { $_.Version -eq [version]$version })
    if ($installed.Count) { return $installed[0].Path }
    foreach ($base in @($dependencyRoot, (Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'PowerShell\Modules'))) {
        $path = Join-Path $base "$Name\$version\$Name.psd1"
        if (Test-Path -LiteralPath $path) { return $path }
    }
    return $null
}

if ($RestoreDependencies) {
    [void][IO.Directory]::CreateDirectory($dependencyRoot)
    foreach ($name in $versions.Keys) {
        if (-not (Find-BuildModule $name)) {
            Write-Host "Restoring $name $($versions[$name]) from PowerShell Gallery into .dependencies."
            Save-Module -Name $name -RequiredVersion $versions[$name] -Path $dependencyRoot -Repository PSGallery -ErrorAction Stop
        }
    }
}

$manifest = Join-Path $root 'src\SimpleSqlAssessment\SimpleSqlAssessment.psd1'
$null = Test-ModuleManifest $manifest
if ($Test) {
    $pester = Find-BuildModule Pester
    if (-not $pester) { throw 'Pester 5.7.1 is missing. Run .\build.ps1 -RestoreDependencies first.' }
    Import-Module $pester -Force
    $configuration = New-PesterConfiguration
    $configuration.Run.Path = Join-Path $root 'tests'
    $configuration.Run.PassThru = $true
    $configuration.Output.Verbosity = 'Normal'
    $result = Invoke-Pester -Configuration $configuration
    if ($result.FailedCount -gt 0 -or $result.Result -ne 'Passed') { throw "$($result.FailedCount) test(s) failed." }
}
if ($Lint) {
    $analyzer = Find-BuildModule PSScriptAnalyzer
    if (-not $analyzer) { throw 'PSScriptAnalyzer is missing. Run .\build.ps1 -RestoreDependencies first.' }
    Import-Module $analyzer -Force
    $settings = @{
        IncludeRules = @('PSUseApprovedVerbs','PSUseCompatibleSyntax','PSAvoidUsingPlainTextForPassword','PSAvoidUsingConvertToSecureStringWithPlainText')
        Rules = @{ PSUseCompatibleSyntax = @{ TargetVersions = @('5.1','7.0') } }
    }
    $issues = @(Invoke-ScriptAnalyzer -Path (Join-Path $root 'src') -Recurse -Settings $settings)
    if ($issues.Count) { $issues | Format-Table -AutoSize; throw "Static analysis reported $($issues.Count) issue(s)." }
}
if ($Package) {
    $version = (Import-PowerShellDataFile $manifest).ModuleVersion
    $path = Join-Path $root "artifacts\SimpleSqlAssessment-$version.zip"
    [void][IO.Directory]::CreateDirectory((Split-Path $path -Parent))
    $items = @('.github','src','tests','examples','tools','README.md','docs','dependencies.psd1','build.ps1') | ForEach-Object { Join-Path $root $_ }
    Compress-Archive -Path $items -DestinationPath $path -Force
    Get-Item -LiteralPath $path
}
