function Start-SsaPerformanceCapture {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$CollectionPath,
        [timespan]$Duration = ([timespan]::FromDays(7)),
        [ValidateRange(1,3600)][double]$SampleIntervalSeconds = 30,
        [pscredential]$Credential, [switch]$TrustServerCertificate
    )
    Invoke-SsaCapture @PSBoundParameters
}

function Resume-SsaPerformanceCapture {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$CollectionPath, [pscredential]$Credential, [switch]$TrustServerCertificate)
    Invoke-SsaCapture -CollectionPath $CollectionPath -Duration ([timespan]::FromDays(7)) -SampleIntervalSeconds 30 -Credential $Credential -TrustServerCertificate:$TrustServerCertificate -Resume
}
