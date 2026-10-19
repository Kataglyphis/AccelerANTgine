#!/usr/bin/env bash
# ci-common.sh - source after set -euo pipefail for ANTfrastructure's core library (info/die, arch_oci, compute_jobs, apt_install).

[ -n "${_CI_COMMON_SH_LOADED:-}" ] && return 0
_CI_COMMON_SH_LOADED=1

_CI_COMMON_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ANTFRASTRUCTURE_DIR comes from lib/antfrastructure.sh, a verbatim copy of the upstream template.
# shellcheck disable=SC1091
source "${_CI_COMMON_DIR}/lib/antfrastructure.sh"

# No fallback: the ci-*.sh chain runs hub scripts next, so a missing hub stops here with the bootstrap's fix.
_ANTFRASTRUCTURE_CORE="$(antfrastructure_path linux/scripts/01-core)" || exit 1
# shellcheck disable=SC1091
source "${_ANTFRASTRUCTURE_CORE}/common.sh"
# shellcheck disable=SC1091
source "${_ANTFRASTRUCTURE_CORE}/modules.sh"
info "ANTfrastructure core library loaded from ${_ANTFRASTRUCTURE_CORE}"
