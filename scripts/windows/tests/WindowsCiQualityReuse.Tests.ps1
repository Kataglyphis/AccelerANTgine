#requires -Version 7.0
# The workflow wiring gate does not test Gallery availability or run the container build.

Describe 'Windows CI quality reuse' {
    $workflow = Get-Content -Raw -LiteralPath (Join-Path $PSScriptRoot '../../../.github/workflows/windows-x64.yml')

    It 'calls the reusable PowerShell quality workflow' {
        ($workflow -match 'uses: Kataglyphis/ANTfrastructure/\.github/workflows/powershell-quality\.yml@develop') | Should Be $true
    }

    It 'retains the scripts scope and advisory analyzer policy' {
        ($workflow -match 'lint-path: scripts') | Should Be $true
        ($workflow -match 'analyzer-strict: false') | Should Be $true
    }

    It 'does not install Gallery modules directly in the lane' {
        ($workflow -notmatch 'Install-Module\s+(PSScriptAnalyzer|Pester)') | Should Be $true
    }
}
