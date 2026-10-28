BeforeAll {
    $root = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
    Import-Module (Join-Path $root 'src\SimpleSqlAssessment\SimpleSqlAssessment.psd1') -Force
    $script:module = Get-Module SimpleSqlAssessment
}
Describe 'Module and persistence contracts' {
    It 'exports only its nine approved commands' {
        @(Get-Command -Module SimpleSqlAssessment).Count | Should -Be 9
    }
    It 'atomically replaces UTF-8 JSON without leaving temporary files' {
        $path = Join-Path $TestDrive 'state.json'
        & $script:module {param($p) Write-SsaJson $p @{State='first'}; Write-SsaJson $p @{State='second'}} $path
        (Get-Content -Raw $path | ConvertFrom-Json).State | Should -Be 'second'
        @(Get-ChildItem $TestDrive -Filter '*.tmp').Count | Should -Be 0
    }
    It 'creates an encrypted SQL connection without connecting or storing a password in its string' {
        $connection = & $script:module { New-SsaSqlConnection -SqlInstance 'fixture.invalid' }
        try {
            $connection.State.ToString() | Should -Be 'Closed'
            $connection.ConnectionString | Should -Match 'Encrypt=True|Encrypt=Mandatory'
            $connection.ConnectionString | Should -Match 'Integrated Security=True'
            $connection.ConnectionString | Should -Not -Match 'Password='
        } finally { $connection.Dispose() }
    }
    It 'returns SQL reader rows without nesting an extra array' {
        $table = New-Object Data.DataTable
        [void]$table.Columns.Add('Name',[string])
        [void]$table.Rows.Add('A'); [void]$table.Rows.Add('B')
        $command = [pscustomobject]@{CommandText='';CommandTimeout=0;Table=$table}
        $command | Add-Member ScriptMethod ExecuteReader { ,$this.Table.CreateDataReader() }
        $command | Add-Member ScriptMethod Dispose {}
        $connection = [pscustomobject]@{State='Open';Command=$command}
        $connection | Add-Member ScriptMethod CreateCommand { $this.Command }
        $rows = @(& $script:module {param($c) Invoke-SsaQuery $c 'SELECT Name FROM fixture;'} $connection)
        $rows.Count | Should -Be 2
        $rows[0].Name | Should -Be 'A'
        $rows[1].Name | Should -Be 'B'
    }
}
