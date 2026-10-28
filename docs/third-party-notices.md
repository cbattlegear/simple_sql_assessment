# Dependencies and third-party references

The release ZIP contains this module's source, catalogs, report assets, and
documentation. It does **not** redistribute the following dependency binaries.
Obtain them through your approved package source and review their upstream
licenses and notices.

| Dependency | Pinned version | Use |
| --- | --- | --- |
| [SqlServer](https://www.powershellgallery.com/packages/SqlServer/22.4.5.1) | 22.4.5.1 | Runtime-specific Microsoft.Data.SqlClient and ScriptDom assets |
| [Pester](https://www.powershellgallery.com/packages/Pester/5.7.1) | 5.7.1 | Development tests only |
| [PSScriptAnalyzer](https://www.powershellgallery.com/packages/PSScriptAnalyzer/1.25.0) | 1.25.0 | Development static analysis only |

`dependencies.psd1` is the dependency-version lock. `build.ps1
-RestoreDependencies` restores missing exact versions to a local directory.
SQL library initialization verifies the loaded DLLs against the pinned module's
assets using SHA-256; it rejects a conflicting library already loaded in the
process. This checks runtime consistency, not independent package authenticity.
Use trusted package sources and their normal signing/integrity controls.

Upstream projects include
[Microsoft.Data.SqlClient](https://github.com/dotnet/SqlClient),
[SQL ScriptDOM](https://github.com/microsoft/SqlScriptDOM),
[Pester](https://github.com/pester/Pester), and
[PSScriptAnalyzer](https://github.com/PowerShell/PSScriptAnalyzer).

Rule and capacity facts are derived from linked Microsoft Learn sources.
Catalog records retain their source URLs and source revisions; rule manifests
retain published IDs/categories and reconciliation notes. Azure prices are
public retail data with retained meter provenance. No retired DMA binary or
proprietary DMA engine is included. This project is not an official Microsoft
migration-readiness certification or licensing authority.
