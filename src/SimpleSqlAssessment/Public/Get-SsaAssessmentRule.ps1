function Get-SsaAssessmentRule {
    [CmdletBinding()]
    param([ValidateSet('SqlDatabase','ManagedInstance','SqlVm')][string[]]$Target = @('SqlDatabase','ManagedInstance','SqlVm'))
    $manifest = Read-SsaJson (Join-Path $script:SsaModuleRoot 'Rules\rules.json')
    foreach ($rule in $manifest.Rules) {
        foreach ($targetName in $rule.Targets) {
            if ($targetName -notin $Target) { continue }
            [pscustomobject]@{
                RuleId = $rule.Id; Target = $targetName; Scope = $rule.Scope
                Category = $rule.Category; RequiredEvidence = $rule.Evidence; Detector = $rule.Detector
                Remediation = $rule.Remediation; Resolution = Get-SsaValue $rule 'Resolution'
                SourceUrl = $manifest.Sources.$targetName; RuleVersion = $manifest.Version
            }
        }
    }
    if ('SqlVm' -in $Target) {
        foreach ($rule in $manifest.VmRules) {
            [pscustomobject]@{
                RuleId = $rule.Id; Target = 'SqlVm'; Scope = 'Instance'; Category = $rule.Category
                RequiredEvidence = @('Databases','SkuFeatures'); Detector = $rule.Id
                Remediation = $rule.Remediation; Resolution = 'Scoped VM pack; not exhaustive Upgrade Advisor parity.'
                SourceUrl = $manifest.Sources.SqlVm; RuleVersion = $manifest.Version
            }
        }
    }
}
