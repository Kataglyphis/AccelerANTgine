#!/usr/bin/env bash
# run-lint-gates.sh - the hub lint aggregator over this repo's root, passed explicitly so it never grades the hub's tree.
set -euo pipefail

_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Matches lint-gates.yml's `workflow-conventions: sha-pin`.
export WORKFLOW_CONVENTIONS_GATE="${WORKFLOW_CONVENTIONS_GATE:-sha-pin}"

# The bootstrap directly, not ci-common.sh: only antfrastructure_exec is needed.
# shellcheck source=lib/antfrastructure.sh
source "${_SCRIPT_DIR}/lib/antfrastructure.sh"

# First, and in a second: a refactor that moves a line a mutation recipe names fails here, not in CI after the push.
stale_check="$(antfrastructure_path docs/scripts/verify_mutations.py)"
for manifest in "${KATAGLYPHIS_REPO_ROOT}"/scripts/linux/tests/*mutations*.json; do
  python3 "${stale_check}" --manifest "${manifest}" --root "${KATAGLYPHIS_REPO_ROOT}" --stale-check
done

# Matches lint-gates.yml's `ratchets: true`; without it the doc-link and ratchet gates never ran here.
antfrastructure_exec linux/scripts/run-lint-gates.sh "${KATAGLYPHIS_REPO_ROOT}" --ratchets --agents-drift "$@"
