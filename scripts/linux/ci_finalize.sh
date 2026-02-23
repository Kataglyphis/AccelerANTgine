#!/usr/bin/env bash
set -euo pipefail

WORKSPACE_DIR="${WORKSPACE_DIR:-$(pwd)}"

OWNER_UID=$(stat -c "%u" "${WORKSPACE_DIR}")
OWNER_GID=$(stat -c "%g" "${WORKSPACE_DIR}")
echo "Fixing ownership of docs/api to ${OWNER_UID}:${OWNER_GID}"
chown -R "${OWNER_UID}:${OWNER_GID}" "${WORKSPACE_DIR}/docs" || true
