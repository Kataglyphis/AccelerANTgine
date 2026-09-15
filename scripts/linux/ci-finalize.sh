#!/usr/bin/env bash
set -euo pipefail

_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${_SCRIPT_DIR}/ci-common.sh"

# fix_bind_mount_ownership was 45 lines here, under a comment asking for it to
# move to 01-core beside dartdoc_build_fix_ownership. ANTfrastructure 05b0eb5e
# did that and kept the SPLIT that is the point of it, not just the code:
# selective chown and never -R, tolerated and explained as non-root, fatal as
# root, a missing target not an error. The reasoning for each decision is in
# third_party/ANTfrastructure/docs/shared-script-libraries.md, under the
# "01-core/bind-mount-ownership.sh" heading.
# Upstream spells the fatal arm err where this file spelled it die; both exit 1.
antfrastructure_source linux/scripts/01-core/bind-mount-ownership.sh

WORKSPACE_DIR="$(pwd)"

while [[ $# -gt 0 ]]; do
	case "$1" in
		--workspace-dir) WORKSPACE_DIR="${2:-}"; shift 2 ;;
		*) die "Unknown argument: $1" ;;
	esac
done

# Hand the docs tree back to whoever owns the bind mount. The container runs as
# a different uid than the host user, so everything ci-docs.sh wrote is
# root-owned until this runs - and on the host that shows up as a docs/ nobody
# can clean or regenerate.
fix_bind_mount_ownership "${WORKSPACE_DIR}/docs" "${WORKSPACE_DIR}"
