#!/usr/bin/env bash
# This tests wheel-driver sequencing, not native compilation or the wheel's contents.
set -euo pipefail
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf -- "${tmp}"' EXIT
workspace="${tmp}/project with spaces"
mkdir -p "${workspace}/scripts/linux" "${workspace}/bin" "${workspace}/hub/linux/scripts/02-toolchain/python"
cp "${repo}/scripts/linux/ci-python-bindings.sh" "${workspace}/scripts/linux/ci-python-bindings.sh"
touch "${workspace}/hub/linux/scripts/02-toolchain/python/free-threaded-wheel.py"
cat > "${workspace}/scripts/linux/ci-common.sh" <<'STUB'
info() { :; }
die() { printf '%s\n' "$*" >&2; exit 1; }
ci_parse_value_options() {
  shift
  while (($#)); do
    case "$1" in
      --workspace-dir) WORKSPACE_DIR="$2" ;;
      --build-root) BUILD_ROOT="$2" ;;
      --out-dir) OUT_DIR="$2" ;;
      *) return 1 ;;
    esac
    shift 2
  done
}
STUB
cat > "${workspace}/bin/uv" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
if [[ "$1" == python ]]; then printf '/fake/%s\n' "$4"; exit; fi
printf 'uv %s\n' "$*" >> "${UV_TEST_LOG}"
case "$1" in
  build)
    out='' python=''
    while (($#)); do
      case "$1" in --out-dir) out="$2";; --python) python="$2";; esac
      shift
    done
    abi=cp314; [[ "$python" != *t ]] || abi=cp314t
    mkdir -p "$out"
    touch "$out/kataglyphis_inference-0.0.3-cp314-${abi}-linux_x86_64.whl"
    ;;
  venv)
    venv="${@: -1}"
    mkdir -p "$venv/bin"
    cat > "$venv/bin/python" <<'SHELL_STUB'
#!/usr/bin/env bash
printf 'python %s\n' "$*" >> "${UV_TEST_LOG}"
SHELL_STUB
    chmod +x "$venv/bin/python"
    ;;
  export)
    [[ "${UV_TEST_FAIL_EXPORT}" == 0 ]] || exit 23
    while (($#)); do
      if [[ "$1" == --output-file ]]; then touch "$2"; break; fi
      shift
    done
    ;;
esac
STUB
chmod +x "${workspace}/bin/uv"
export PATH="${workspace}/bin:${PATH}" ANTFRASTRUCTURE_DIR="${workspace}/hub" PYTHON_MAJOR_MINOR=3.14
export UV_TEST_LOG="${tmp}/calls" UV_TEST_FAIL_EXPORT=0
cd "${workspace}"
args=(--workspace-dir "${workspace}" --build-root "${tmp}/build root" --out-dir 'dist wheels')
bash scripts/linux/ci-python-bindings.sh "${args[@]}"
mapfile -t calls < "${UV_TEST_LOG}"
[[ ${#calls[@]} -eq 13 ]] || { printf 'expected both wheel lifecycles\n' >&2; exit 1; }
[[ "${calls[0]}" == 'uv build '* && "${calls[2]}" == *' --no-deps '*cp314-linux* &&
   "${calls[3]}" == 'uv export '* && "${calls[4]}" == *' --no-deps -r '* &&
   "${calls[5]}" == 'python -m pytest '* && "${calls[6]}" == 'uv build '* &&
   "${calls[8]}" == *' --no-deps '*cp314t-linux* && "${calls[9]}" == 'python -I '* &&
   "${calls[10]}" == 'uv export '* && "${calls[11]}" == *' --no-deps -r '* &&
   "${calls[12]}" == 'python -m pytest '* ]] || { printf 'wheel lifecycle changed\n' >&2; exit 1; }
: > "${UV_TEST_LOG}"
export UV_TEST_FAIL_EXPORT=1
if bash scripts/linux/ci-python-bindings.sh "${args[@]}"; then
  printf 'failed lock export was accepted\n' >&2; exit 1
fi
[[ "$(< "${UV_TEST_LOG}")" != *'python -m pytest '* ]] || { printf 'tests ran after failed lock export\n' >&2; exit 1; }
printf 'wheel lock lifecycle passed for GIL and free-threaded ABIs\n'
