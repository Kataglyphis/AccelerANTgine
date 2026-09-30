#!/usr/bin/env bash
set -euo pipefail

_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${_SCRIPT_DIR}/ci-common.sh"

# See third_party/ANTfrastructure/docs/shared-script-libraries.md, section 01-core/bind-mount-ownership.sh
antfrastructure_source linux/scripts/01-core/bind-mount-ownership.sh

WORKSPACE_DIR="$(pwd)"

while [[ $# -gt 0 ]]; do
	case "$1" in
		--workspace-dir) WORKSPACE_DIR="${2:-}"; shift 2 ;;
		*) die "Unknown argument: $1" ;;
	esac
done

# The container's uid differs from the host user's, so without this the host cannot clean docs/.
fix_bind_mount_ownership "${WORKSPACE_DIR}/docs" "${WORKSPACE_DIR}"
