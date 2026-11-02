#!/usr/bin/env bash
# quality-report.sh --perf-host inside :latest: `setup` builds the Release binaries and the wheel, `text-cpp` is one CLI run; it times no build.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "${REPO_ROOT}"
BUILD_DIR="${REPO_ROOT}/build-perf"
WHEEL_BUILD="${BUILD_DIR}/wheel"
WHEEL_OUT="${REPO_ROOT}/logs/code-quality/perf/wheel"
VENV="${REPO_ROOT}/.venv-perf-host"
LLM_MODEL="resources/models/smollm2-perf"

setup() {
  # shellcheck source=/dev/null
  source "${REPO_ROOT}/scripts/linux/lib/antfrastructure.sh"
  local fetcher wheels
  fetcher="$(antfrastructure_path linux/scripts/lib/fetch-data-lock.py)"
  python3 -I "${fetcher}" --lock models/models.lock
  python3 -I "${fetcher}" --lock resources/models/llm.lock --extract
  python3 -I "$(antfrastructure_path linux/scripts/lib/genai-model-threads.py)" \
    --model resources/models/smollm2_135m_instruct-cpu --out "${LLM_MODEL}" --threads 7
  cmake --preset linux-release-clang -B "${BUILD_DIR}"
  cmake --build "${BUILD_DIR}" --target AccelerANTgine_demo AccelerANTgine_cli
  rm -rf "${WHEEL_OUT}" "${VENV}"
  # scikit-build-core configures the whole project; Ninja because the module scanning needs it.
  CMAKE_GENERATOR=Ninja CC=clang CXX=clang++ uv build --wheel --python python3 --out-dir "${WHEEL_OUT}" \
    -C "build-dir=${WHEEL_BUILD}" "${REPO_ROOT}"
  wheels=("${WHEEL_OUT}"/*.whl)
  [ "${#wheels[@]}" -eq 1 ] || { echo "expected one wheel in ${WHEEL_OUT}" >&2; return 1; }
  uv venv --python python3 "${VENV}"
  uv pip install --python "${VENV}/bin/python" --no-deps "${wheels[0]}"
}

# A fresh process's first reply is noisy, so one run is the per-metric median of five; the CLI prints `<n> tokens, <ms> ms to the first, <rate> tokens/s` to stderr.
text_cpp() {
  local prompt tokens figures ttft rate
  prompt="$(python3 -I scripts/linux/perf_host_text.py --print-prompt)"
  tokens="$(python3 -I scripts/linux/perf_host_text.py --print-tokens)"
  figures="$(for _ in 1 2 3 4 5; do
    "${BUILD_DIR}/bin/AccelerANTgine" --chat_model "${LLM_MODEL}" --prompt "${prompt}" --max_new_tokens "${tokens}" 2>&1 >/dev/null |
      sed -nE 's/^[0-9]+ tokens, ([0-9.e+-]+) ms to the first, ([0-9.e+-]+) tokens\/s$/\1 \2/p' | tail -1
  done)"
  ttft="$(cut -d' ' -f1 <<< "${figures}" | sort -g | sed -n 3p)"
  rate="$(cut -d' ' -f2 <<< "${figures}" | sort -g | sed -n 3p)"
  printf '{"ttft_ms": %s, "decode_tok_s": %s}\n' "${ttft}" "${rate}"
}

case "${1:-}" in
  setup) setup ;;
  text-cpp) text_cpp ;;
  *) echo "usage: perf-host.sh setup|text-cpp" >&2; exit 2 ;;
esac
