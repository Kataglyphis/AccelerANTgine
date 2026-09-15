#requires -Version 7.0

# Guards against generated artifacts sneaking into this repo's git index.
#
# The check itself is generic and lives in ANTfrastructure's
# WindowsRepoHygiene.Common (Get-TrackedIgnoredFile, Get-TrackedGeneratedArtifact,
# each with its own suite upstream). Only this repo's root and its pathspec list
# are local - what counts as "generated" is a property of THIS build.
#
# Why it exists here: this tree shipped docs/_build_validation/, docs/test-results/,
# docs/test-results-md/, docs/test_results.xml, profile.prof and a
# Test/python/__pycache__/*.pyc in the index, all of them rewritten by
# ci-docs.sh / ci-profile-bench.sh / pytest on every run. Adding the .gitignore
# rules fixed nothing on its own: .gitignore stops NEW files, and does nothing
# once a path is already tracked. Both halves were needed, and this suite is what
# keeps the second half from quietly regressing.
#
# NOTE: written for Pester 3.4.0 (what the Windows lane pins) - no BeforeAll
# outside Describe, and the dash-less assertion syntax.

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
        # The check above only sees files that are tracked AND ignored. An
        # artifact committed before anyone added the ignore rule is tracked and
        # NOT ignored, so it is invisible to it - which is exactly how
        # docs/test_results.xml and profile.prof survived here for months.
        #
        # These are git pathspecs. '**/__pycache__/*' rather than
        # '**/__pycache__/': measured against this index, the trailing-slash
        # form matches nothing, so it would have reported clean over the .pyc
        # that was actually tracked.
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
