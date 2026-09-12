#!/usr/bin/env bash
# renovate-local.sh - which of this repo's dependencies are behind, decided by
# Renovate run as a LOCAL CLI, plus the git half that moves the gitlinks it is
# allowed to move.
#
#   bash scripts/linux/renovate-local.sh                     # report (default)
#   bash scripts/linux/renovate-local.sh --managers pep621   # the pyproject pins
#   bash scripts/linux/renovate-local.sh --apply --dry-run   # show the plan
#   bash scripts/linux/renovate-local.sh --apply             # move the gitlinks
#   bash scripts/linux/renovate-local.sh --print-bin         # resolved renovate.js
#
# THIN WRAPPER over ANTfrastructure's linux/scripts/renovate-local.sh, the same
# shape as run-lint-gates.sh beside it. Upstream owns everything that makes the
# answer trustworthy: the on-demand, checksum-verified bootstrap of
# RENOVATE_NODE_VERSION and RENOVATE_VERSION - both pinned in the hub's
# linux/scripts/01-core/versions.env, and the Node pin is deliberately NOT the
# canonical NODE_VERSION, because Renovate declares engines.node "^24.11.0"
# while the images ship 26 - the run against this repo's own
# .github/renovate.json, the machine-readable report it parses, and the apply
# half.
#
# THE CONSUMER ROOT IS PASSED EXPLICITLY, and for the same reason
# run-lint-gates.sh passes it: upstream defaults its target to $PWD, so a run
# from Src/ or from inside third_party/ANTfrastructure would grade the wrong tree
# and answer "up to date" about a repository nobody asked about. A root of your
# own is therefore an error here - upstream refuses a second one. Every other
# flag is forwarded untouched.
#
# ONLY ONE HALF WRITES. Renovate's --platform=local forces dryRun: it DETECTS
# and edits nothing, so a report run that leaves the tree byte-identical is the
# tool working, not a broken script. The write half is git, and it moves
# GITLINKS only.
#
# WHAT --apply REFUSES HERE, which matters more in this repo than in any other
# consumer: .gitmodules declares SEVEN submodules and exactly ONE of them names
# a branch - third_party/ANTfrastructure (branch = main). FUZZTEST,
# GOOGLE_BENCHMARK, NLOHMANN_JSON, SPDLOG, tomlplusplus and nanobind declare
# none, and an unset branch does not disarm `git submodule update --remote`: it
# makes it fall back to the REMOTE'S DEFAULT BRANCH, i.e. every commit on main
# since the pin was taken. So upstream passes explicit paths, only for the
# submodule that declares a branch, and prints the other six as REFUSED when
# they are behind - to be moved by hand, deliberately, and for FUZZTEST with the
# Abseil/GoogleTest coupling in mind. Nothing is staged or committed either way.
#
# That is not theory here. `--apply --dry-run` on 2026-09-09 reported five
# submodules behind - FUZZTEST, GOOGLE_BENCHMARK, NLOHMANN_JSON, SPDLOG and
# nanobind - listed all five as REFUSED, and ended in "nothing to apply", with
# `git status` unchanged afterwards. third_party/ANTfrastructure was already at the
# tip of main and tomlplusplus was not behind, so the ONE submodule this tool can
# move had nothing to move. Expect that: on this repo --apply is mostly a
# machine-checked list of what you must decide yourself.
#
# THE PYTHON, RUST AND pre-commit SIDES ARE REPORT-ONLY. --apply moves gitlinks
# and nothing else; point --managers at another ecosystem and you get a table,
# never an edit. This repo has four of them - `pep621` reads pyproject.toml,
# `pip_requirements` reads requirements.txt, `cargo` reads
# Src/rusty_code/Cargo.toml, and `pre-commit` reads .pre-commit-config.yaml -
# and each stays yours to edit.
#
# Measured 2026-09-09 (`--managers pep621,pip_requirements,pre-commit,cargo`,
# from WSL): 2 rows, both from Cargo.toml, and both printing the SAME string in
# both columns - `cxx 1.0 1.0` and `cxx-build 1.0 1.0`. That is not a broken
# renderer: the report prints the manifest's currentValue and newValue, and for a
# range that already covers the new release the manifest does not change. The
# report JSON behind that row says currentVersion 1.0.194, newVersion 1.0.200,
# updateType patch - i.e. a Cargo.lock move, not an edit to Cargo.toml. Nothing
# was behind in pyproject.toml, requirements.txt or .pre-commit-config.yaml.
#
# THAT RUN ALSO WARNED, and the warning is worth acting on rather than reading
# past: "Rate limit exceeded for api.github.com, as no hostRules set for this
# host". The managers that reach GitHub answer short without a token, and the
# variable that clears it under `--platform=local` is GITHUB_COM_TOKEN -
# RENOVATE_TOKEN alone does not, measured both ways in ANThology on the same day.
# Here the token silenced the warning and the answer stayed at the same 2 rows;
# in a repo with tagged GitHub actions in scope it changes the answer outright.
#
#   GITHUB_COM_TOKEN="$(gh auth token)" bash scripts/linux/renovate-local.sh \
#     --managers pep621,pip_requirements,pre-commit,cargo
#
# NOTHING RUNS THIS FOR YOU, and nothing else reads the config it uses. The
# Renovate GitHub App is installed on no repo in this family and will not be
# (owner decision, 2026-09-09), and unlike the other consumers this repo has no
# .github/dependabot.yml either - so this CLI is the ONLY dependency watch it
# has. No workflow calls this script; it blocks no commit; it is not a gate.
#
# RUN IT FROM WSL on this host: the bootstrap wants Node, and the Windows side
# has none. That stands a Linux git next to a Windows checkout, which sees every
# text file as CR-modified, so --apply would abort part way through and leave the
# superproject half updated. Upstream handles that rather than you: it switches
# to git.exe when WSL can reach the tree through it, and refuses up front when it
# cannot. The report half only reads and is safe from anywhere.
#
# Full rationale, the version pins and the `--platform=github` variant:
# third_party/ANTfrastructure/docs/dependency-updates.md - read its token paragraph
# against the GITHUB_COM_TOKEN measurement above.
set -euo pipefail

_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# The bootstrap directly, not ci-common.sh: this wrapper needs antfrastructure_exec
# and nothing else, and ci-common.sh pulls in the whole core library plus its
# fallback block for a lane that runs no build. The source= directive below
# points the shell linter at the file rather than silencing it.
# shellcheck source=lib/antfrastructure.sh
source "${_SCRIPT_DIR}/lib/antfrastructure.sh"

# Named separately from antfrastructure_path's generic "not found / it moved
# upstream" message. While the family adopts this tool the expected failure is a
# gitlink pinned BEFORE the driver existed upstream, and sending the reader to
# docs/INDEX.md to hunt for a file that is simply not in this pin wastes the
# trip. The sibling wrappers in OmniAccelerANT and jotrockenmitlocken carry the
# same guard for the same reason.
HUB_RENOVATE_RELATIVE="linux/scripts/renovate-local.sh"
if [ ! -f "${ANTFRASTRUCTURE_DIR}/${HUB_RENOVATE_RELATIVE}" ]; then
  echo "Error: ${ANTFRASTRUCTURE_DIR}/${HUB_RENOVATE_RELATIVE} is missing." >&2
  echo "       Either ANTfrastructure is not checked out (git submodule update" >&2
  echo "       --init --recursive third_party/ANTfrastructure), or the pinned" >&2
  echo "       ANTfrastructure predates the shared Renovate CLI - bump the" >&2
  echo "       third_party/ANTfrastructure gitlink." >&2
  exit 1
fi

antfrastructure_exec "${HUB_RENOVATE_RELATIVE}" "${KATAGLYPHIS_REPO_ROOT}" "$@"
