#requires -Version 7.0

# Keeps generated artifacts out of the index, where .gitignore no longer helps; Pester 3.4.0 syntax.

Describe 'Repo generated artifacts' {

    . (Join-Path $PSScriptRoot '..\Resolve-BuildModule.ps1')
    Import-BuildModule 'WindowsRepoHygiene.Common'

    $repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..')).Path

    It 'has no tracked file that is also gitignored' {
        $tracked = @(Get-TrackedIgnoredFile -RepoRoot $repoRoot)

        if ($tracked.Count -gt 0) {
            Write-Host 'Tracked files that .gitignore also excludes (generated artifacts committed by mistake):'
            $tracked | ForEach-Object { Write-Host "  $_" }
            Write-Host 'Fix with: git rm --cached <path> for each file listed above - do not relax .gitignore.'
        }

        $tracked.Count | Should Be 0
    }

    It 'has no tracked file under a known generated-output path' {
        # Catches what the check above cannot: tracked and not ignored; git pathspecs, and '**/__pycache__/' matches nothing.
        $generated = @(
            'logs/'                     # Build-Windows.ps1 / ci-* run output
            'target/'                   # cargo, Src/rusty_code
            'build*/'                   # every CMake preset's tree
            '*.prof'                    # gperftools, ci-profile-bench.sh
            '*.profraw'                 # llvm coverage
            '**/__pycache__/*'          # pytest / Test/python
            'docs/build/'               # Sphinx output
            'docs/coverage/'            # gcovr / llvm-cov
            'docs/test_results*.xml'    # ctest JUnit
            'docs/test-results*/'       # ci-docs.sh junit2html + pandoc output
            'docs/_build*'              # Sphinx validation tree
            'scan-build-reports/'       # run-static-analysis-format.sh
        )
        $tracked = @(Get-TrackedGeneratedArtifact -RepoRoot $repoRoot -Pattern $generated)

        if ($tracked.Count -gt 0) {
            Write-Host 'Tracked files under a generated-output path:'
            $tracked | ForEach-Object { Write-Host "  $_" }
            Write-Host 'Fix with: git rm -r --cached <path>, then add the path to .gitignore.'
        }

        $tracked.Count | Should Be 0
    }
}
