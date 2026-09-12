#!/usr/bin/env bash
# run-lint-gates.sh - this repo's shell + workflow + secret + Python lint gates.
#
# THIN WRAPPER over ANTfrastructure's linux/scripts/run-lint-gates.sh, which owns
# all four gates and everything that makes them trustworthy: the pinned tool
# bootstraps (shellcheck, actionlint and gitleaks are also SHA256-verified; ruff
# is version-pinned and fetched via uvx, so uv verifies it against PyPI rather
# than against a digest in versions.env), the git-ls-files scope construction, the
# empty-scope refusals, the run-all-four-then-fail-once accumulator, and the
# secret gate's two-arm self-test (an empty tree must scan clean, a planted PAT
# must be reported at the path that was passed in - otherwise "no findings"
# cannot be told apart from "the scanner never started").
#
# WHAT THIS CLOSES. Before this file the repo ran no lint gate of any kind:
# not over its 12 tracked *.sh, not over its 4 workflows, not over its 4
# first-party *.py, and - the one that matters most - no secret scan, while
# .github/workflows/linux_run.yml deploys the built docs over FTP with three
# repository secrets (SERVER, USERNAME, PW). A credential committed to this
# tree had nothing standing between it and the push.
#
# The scripts in this directory carried 21 "disable" directives naming codes for
# a linter that had never run over them; 13 remain after this change set. Those are now assertions somebody can
# check rather than decoration.
#
# The roundabout wording above is deliberate, not style: a comment line whose
# FIRST word is the shell linter's own name is parsed as a DIRECTIVE, and one
# it cannot parse is itself an error-level finding. That is how this gate fails
# on its own wrapper if the header is written the obvious way.
#
# THE CONSUMER ROOT IS PASSED EXPLICITLY, and upstream refuses to infer it. The
# half of this gate that does the work lives inside third_party/ANTfrastructure, so
# a root derived from its own BASH_SOURCE would grade ANTfrastructure's tree and
# report green over the wrong repository.
#
# --exclude defaults to third_party upstream, which is what this repo needs:
# all seven entries there are submodule gitlinks graded in their own
# repositories at their own ratchet, and the one first-party file among them
# (third_party/CMakeLists.txt) is kept by upstream's depth-2 rule rather than
# swept out with the prefix.
#
# CI and a dev box run the SAME entry point - that is the point of the file,
# not the line count:
#
#   bash scripts/linux/run-lint-gates.sh                    # the whole repo
#   bash scripts/linux/run-lint-gates.sh --exclude models   # extra exclusions
#
# Four tools, four network bootstraps, so the first local run is not instant.
set -euo pipefail

_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# The bootstrap directly, not ci-common.sh: this wrapper needs antfrastructure_exec
# and nothing else, and ci-common.sh pulls in the whole core library (logging,
# apt, parallelism) plus its fallback block for a lane that runs no build.
# source= rather than a disable directive - it points the linter at the file
# instead of silencing it.
# shellcheck source=lib/antfrastructure.sh
source "${_SCRIPT_DIR}/lib/antfrastructure.sh"

antfrastructure_exec linux/scripts/run-lint-gates.sh "${KATAGLYPHIS_REPO_ROOT}" "$@"
