#!/usr/bin/env bash
# This tests the docs installation contract, not Sphinx rendering or downloads.
set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf -- "${tmp}"' EXIT
workspace="${tmp}/project with spaces"
mkdir -p "${workspace}/scripts/linux" "${workspace}/bin"
cp "${repo}/scripts/linux/ci-docs.sh" "${workspace}/scripts/linux/ci-docs.sh"
touch "${workspace}/CMakeLists.txt"

cat > "${workspace}/scripts/linux/ci-common.sh" <<'STUB'
info() { :; }
die() { printf '%s\n' "$*" >&2; exit 1; }
antfrastructure_source() {
  if [[ "$1" == linux/scripts/01-core/python_uv.sh ]]; then
    source "${UV_TEST_HUB}/$1"
    uv_venv_create() { mkdir -p "$1/bin" "$1/lib"; printf '#!/usr/bin/env bash\nexit 0\n' > "$1/bin/python"; chmod +x "$1/bin/python"; _CURRENT_VENV_PATH="$1"; }
    uv_reconcile_chain_ort() { :; }
  fi
}
ci_parse_value_options() { [[ "$1" == docs && "$2" == --workspace-dir ]]; WORKSPACE_DIR="$3"; }
cmake() { mkdir -p build/build/html; touch build/Doxyfile build/build/html/graph.svg; }
doxygen() { :; }
docs_build_prepare_python_env() { (docs_venv_create); (docs_venv_install_requirements); }
docs_build_copy_static_svg() { :; }
docs_build_run_generator() { :; }
docs_build_sphinx() { touch "${UV_TEST_SPHINX}"; }
STUB
cat > "${workspace}/bin/uv" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "${UV_PROJECT_ENVIRONMENT-<unset>}" "${UV_PYTHON-<unset>}" \
  "${VIRTUAL_ENV-<unset>}" "$@" > "${UV_TEST_LOG}"
exit "${UV_TEST_EXIT}"
STUB
chmod +x "${workspace}/bin/uv"

export PATH="${workspace}/bin:${PATH}" UV_PYTHON=/poison/python VIRTUAL_ENV=/poison/venv UV_PROJECT_ENVIRONMENT=/poison/project
export UV_TEST_HUB="${UV_TEST_HUB:-${repo}/third_party/ANTfrastructure}"
export UV_TEST_LOG="${tmp}/uv.log" UV_TEST_SPHINX="${tmp}/sphinx" UV_TEST_EXIT=0
cd "${workspace}"
bash scripts/linux/ci-docs.sh --workspace-dir "${workspace}"
mapfile -t actual < "${UV_TEST_LOG}"
expected=("${workspace}/.venv" '<unset>' '<unset>' sync --only-group docs --locked
  --python "${workspace}/.venv/bin/python")
[[ "${actual[*]}" == "${expected[*]}" && ${#actual[@]} -eq ${#expected[@]} ]] || {
  printf 'unexpected uv environment or arguments\n' >&2; exit 1;
}
[[ -f "${UV_TEST_SPHINX}" ]] || { printf 'Sphinx was not reached\n' >&2; exit 1; }
rm -f "${UV_TEST_SPHINX}"
export UV_TEST_EXIT=7
if bash scripts/linux/ci-docs.sh --workspace-dir "${workspace}"; then
  printf 'failed uv sync was accepted\n' >&2; exit 1
fi
[[ ! -e "${UV_TEST_SPHINX}" ]] || { printf 'Sphinx ran after a failed sync\n' >&2; exit 1; }
printf 'docs uv installation contract passed\n'
