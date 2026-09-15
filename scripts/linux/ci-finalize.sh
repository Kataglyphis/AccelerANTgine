#!/usr/bin/env bash
set -euo pipefail

_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${_SCRIPT_DIR}/ci-common.sh"

# fix_bind_mount_ownership was 45 lines in this file, under a comment asking for
# it to move to 01-core beside dartdoc_build_fix_ownership. ANTfrastructure
# 05b0eb5e did that, and kept the SPLIT that was the point of it rather than
# just the code: only the paths that actually differ are chowned (never a
# blanket -R, which on a mostly-correct tree asks the kernel for a chown it
# refuses for a non-owner and turns a no-op into an error); a failure as a
# non-root uid is explained and tolerated, because handing a file to another
# uid needs CAP_CHOWN and as an unprivileged container user that is arithmetic,
# not a defect; the same failure AS ROOT is fatal, because there it means a
# read-only or broken mount. A missing target is not an error.
#
# The upstream copy spells the fatal arm as err rather than die; both exit 1.
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
