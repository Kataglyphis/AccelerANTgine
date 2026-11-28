#requires -Version 7.0
# The workflow wiring gate does not test Gallery availability or run the container build.

Describe 'Windows CI quality reuse' {
    BeforeAll {
        $workflows = Join-Path $PSScriptRoot '../../../.github/workflows'
        $script:quality = Get-Content -Raw -LiteralPath (Join-Path $workflows 'powershell-quality.yml')
        $script:lane = Get-Content -Raw -LiteralPath (Join-Path $workflows 'windows-x64.yml')
    }

    It 'calls the reusable PowerShell quality workflow' {
        ($script:quality -match 'uses: Kataglyphis/ANTfrastructure/\.github/workflows/powershell-quality\.yml@develop') | Should -Be $true
    }

    It 'retains the scripts scope and advisory analyzer policy' {
        ($script:quality -match 'lint-path: scripts') | Should -Be $true
        ($script:quality -match 'analyzer-strict: \$\{\{ inputs\.strict == true \}\}') | Should -Be $true
        ($script:quality -match '(?s)strict:.*?type: boolean\s+default: false') | Should -Be $true
    }

    It 'does not install Gallery modules directly in the lane' {
        ($script:lane -notmatch 'Install-Module\s+(PSScriptAnalyzer|Pester)') | Should -Be $true
        ($script:quality -notmatch 'Install-Module\s+(PSScriptAnalyzer|Pester)') | Should -Be $true
    }
}
