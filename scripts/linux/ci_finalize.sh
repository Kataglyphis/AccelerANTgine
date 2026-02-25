#!/usr/bin/env bash
set -euo pipefail

WORKSPACE_DIR="$(pwd)"

while [[ $# -gt 0 ]]; do
	case "$1" in
		--workspace-dir) WORKSPACE_DIR="${2:-}"; shift 2 ;;
		*) echo "Unknown argument: $1" >&2; exit 2 ;;
	esac
done

OWNER_UID=$(stat -c "%u" "${WORKSPACE_DIR}")
OWNER_GID=$(stat -c "%g" "${WORKSPACE_DIR}")
echo "Fixing ownership of docs/api to ${OWNER_UID}:${OWNER_GID}"
chown -R "${OWNER_UID}:${OWNER_GID}" "${WORKSPACE_DIR}/docs" || true
