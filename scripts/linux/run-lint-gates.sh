#!/usr/bin/env bash
# run-lint-gates.sh - the hub lint aggregator over this repo's root, passed explicitly so it never grades the hub's tree.
set -euo pipefail

_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# The bootstrap directly, not ci-common.sh: only antfrastructure_exec is needed.
# shellcheck source=lib/antfrastructure.sh
source "${_SCRIPT_DIR}/lib/antfrastructure.sh"

antfrastructure_exec linux/scripts/run-lint-gates.sh "${KATAGLYPHIS_REPO_ROOT}" "$@"
