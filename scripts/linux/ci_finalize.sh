#!/usr/bin/env bash
set -euo pipefail

_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${_SCRIPT_DIR}/ci_common.sh"

WORKSPACE_DIR="$(pwd)"

while [[ $# -gt 0 ]]; do
	case "$1" in
		--workspace-dir) WORKSPACE_DIR="${2:-}"; shift 2 ;;
		*) die "Unknown argument: $1" ;;
	esac
done

OWNER_UID=$(stat -c "%u" "${WORKSPACE_DIR}")
OWNER_GID=$(stat -c "%g" "${WORKSPACE_DIR}")
info "Fixing ownership of docs/ to ${OWNER_UID}:${OWNER_GID}"
chown -R "${OWNER_UID}:${OWNER_GID}" "${WORKSPACE_DIR}/docs" || true
