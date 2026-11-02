#!/usr/bin/env bash
# Exercises the notice stager on synthetic trees; the CPack and MSIX wiring is proven by the release lanes.
set -euo pipefail
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
stager="${repo}/scripts/packaging/third_party_notices.py"
manifest="${repo}/packaging/third-party/components.json"
python="${PYTHON:-python3}"
tmp="$(mktemp -d)"
trap 'rm -rf -- "${tmp}"' EXIT
failures=0

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  failures=$((failures + 1))
}

expect_grep() {
  local file="$1" pattern="$2"
  if ! grep -q -F -e "${pattern}" "${file}"; then fail "${file##*/} lacks: ${pattern}"; fi
  return 0
}

# Reads one fixed-string pattern per stdin line.
expect_greps() {
  local file="$1" pattern
  while IFS= read -r pattern; do expect_grep "${file}" "${pattern}"; done
}

# Usage: if expect_accepted LOG MESSAGE COMMAND...; then checks; fi
expect_accepted() {
  local log="$1" message="$2"
  shift 2
  if "$@" > "${log}" 2>&1; then return 0; fi
  cat "${log}" >&2
  fail "${message}"
  return 1
}

expect_no_grep() {
  local file="$1" pattern="$2"
  if grep -q -F -e "${pattern}" "${file}"; then fail "${file##*/} unexpectedly has: ${pattern}"; fi
  return 0
}

fake_texts() {
  mkdir -p "${tmp}/absl"
  printf 'Apache abseil\n' > "${tmp}/absl/LICENSE"
}

# A Windows install tree shaped like the Release lane's.
windows_tree() {
  local root="$1"
  mkdir -p "${root}/bin" "${root}/licenses/onnxruntime" "${root}/share/licenses/AccelerANTgine"
  local name
  for name in AccelerANTgine.exe AccelerANTgine.dll onnxruntime.dll onnxruntime_providers_shared.dll DirectML.dll \
    glib-2.0-0.dll gobject-2.0-0.dll ffi-7.dll intl-8.dll gstreamer-1.0-0.dll gstapp-1.0-0.dll msvcp140.dll \
    vcruntime140_1.dll concrt140.dll; do
    printf 'MZ' > "${root}/bin/${name}"
  done
  printf 'ort license\n' > "${root}/licenses/onnxruntime/LICENSE"
  printf 'ort notices\n' > "${root}/licenses/onnxruntime/ThirdPartyNotices.txt"
  cp "${repo}/LICENSE" "${root}/share/licenses/AccelerANTgine/LICENSE"
}

# Usage: expect_tree_refused NAME MESSAGE REMOVED_PATH...; the refusal log stays at ${tmp}/NAME.log.
expect_tree_refused() {
  local tree="${tmp}/$1" log="${tmp}/$1.log" message="$2" removed
  shift 2
  windows_tree "${tree}"
  for removed in "$@"; do rm -f "${tree}/${removed}"; done
  if run_windows "${tree}" > "${log}" 2>&1; then fail "${message}"; fi
}

stage_windows() {
  local root="$1"
  shift
  "${python}" "${stager}" --manifest "${manifest}" --root "${root}" --dest "${root}/licenses" --platform windows \
    --repo "${repo}" --project-license share/licenses/AccelerANTgine/LICENSE --text-root "abseil=${tmp}/absl" "$@"
}

run_windows() {
  local root="$1"
  shift
  stage_windows "${root}" --define ONNXRUNTIME_VERSION=v9.9 --define GSTREAMER_VERSION=1.99 "$@"
}

fake_texts

# Every Windows closure DLL resolves, installed ORT texts are referenced in place and copies are real texts.
win="${tmp}/win"
windows_tree "${win}"
if expect_accepted "${tmp}/win.log" "a complete Windows tree was refused" run_windows "${win}"; then
  notices="${win}/licenses/THIRD-PARTY-NOTICES.txt"
  expect_greps "${notices}" <<'PATTERNS'
ONNX Runtime
  Version: v9.9
License text: licenses/onnxruntime/ThirdPartyNotices.txt
File: bin/gstapp-1.0-0.dll
File: bin/ffi-7.dll
Microsoft DirectML
File: bin/concrt140.dll
Abseil C++ (flags)
License: LGPL-2.0-or-later
PATTERNS
  expect_no_grep "${notices}" "nanobind"
  cmp -s "${repo}/packaging/third-party/texts/libffi-LICENSE.txt" "${win}/licenses/third-party/libffi/libffi-LICENSE.txt" ||
    fail "libffi text was not copied verbatim"
  [[ ! -e "${win}/licenses/third-party/onnxruntime" ]] || fail "installed ORT texts were copied instead of referenced"
  "${python}" - "${win}/licenses/third-party-inventory.json" <<'PY' || fail "inventory is not the expected JSON"
import json
import sys

with open(sys.argv[1], encoding="utf-8") as stream:
    data = json.load(stream)
ids = {item["id"] for item in data["components"]}
expected = {"onnxruntime", "directml", "msvc-runtime", "glib", "libffi", "gettext-libintl", "gstreamer"}
assert expected <= ids, expected - ids
assert data["scope"] == "native" and data["platform"] == "windows"
PY
fi

# Model data is listed only when shipped, with its accompanying license and notice.
model_tree="${tmp}/model"
windows_tree "${model_tree}"
mkdir -p "${model_tree}/bin/models"
printf 'model\n' > "${model_tree}/bin/models/deim_dfine_n_coco.onnx"
printf 'license\n' > "${model_tree}/bin/models/deim_dfine_n_coco.LICENSE"
printf 'notice\n' > "${model_tree}/bin/models/deim_dfine_n_coco.NOTICE"
if expect_accepted "${tmp}/model.log" "the model and its notices were refused" run_windows "${model_tree}"; then
  expect_grep "${model_tree}/licenses/THIRD-PARTY-NOTICES.txt" "DEIM-D-FINE-N COCO demo model"
  expect_grep "${model_tree}/licenses/THIRD-PARTY-NOTICES.txt" "License text: licenses/third-party/deim-dfine-n-coco/deim_dfine_n_coco.NOTICE"
fi
rm "${model_tree}/bin/models/deim_dfine_n_coco.NOTICE"
if run_windows "${model_tree}" > "${tmp}/missing-model-notice.log" 2>&1; then fail "a model with no notice passed"; fi
expect_grep "${tmp}/missing-model-notice.log" "deim_dfine_n_coco.NOTICE"

# A DLL nobody declared fails the package and is named.
unknown="${tmp}/unknown"
windows_tree "${unknown}"
printf 'MZ' > "${unknown}/bin/mystery-1.dll"
if run_windows "${unknown}" > "${tmp}/unknown.log" 2>&1; then
  fail "an unaccounted DLL passed"
else
  expect_grep "${tmp}/unknown.log" "bin/mystery-1.dll"
fi

# A component whose installed text is missing fails instead of listing a dead path.
expect_tree_refused no-ort "a missing ORT notice passed" licenses/onnxruntime/ThirdPartyNotices.txt
expect_grep "${tmp}/no-ort.log" "ThirdPartyNotices.txt"

# Without the project license, or without a project binary, there is nothing honest to list.
expect_tree_refused no-license "a tree without the project license passed" share/licenses/AccelerANTgine/LICENSE
expect_tree_refused no-project "a tree without project binaries passed" bin/AccelerANTgine.exe bin/AccelerANTgine.dll

# An unknown version variable fails rather than printing an empty version.
if stage_windows "${win}" > "${tmp}/novar.log" 2>&1; then
  fail "an undefined version variable passed"
fi
expect_grep "${tmp}/novar.log" "is not defined"

# Linux: Debian-owned libraries bring their copyright and cited common licenses; /opt builds match the inventory.
lin="${tmp}/lin/usr"
mkdir -p "${lin}/lib/accelerantgine/gstreamer-1.0" "${lin}/share/licenses/AccelerANTgine/licenses/onnxruntime" \
  "${lin}/share/licenses/onnxruntime" "${tmp}/distro" "${tmp}/opt-gst" "${tmp}/doc/libz1" "${tmp}/common" "${tmp}/bin"
elf() { printf '\177ELF' > "$1"; }
elf "${lin}/lib/libAccelerANTgine.so"
elf "${lin}/lib/accelerantgine/libz.so.1"
elf "${lin}/lib/accelerantgine/libgstreamer-1.0.so.0"
elf "${lin}/lib/accelerantgine/libonnxruntime.so.1"
elf "${lin}/lib/accelerantgine/gstreamer-1.0/libgstrswebrtc.so"
elf "${lin}/lib/accelerantgine/gstreamer-1.0/libgstcoreelements.so"
ln -s libz.so.1 "${lin}/lib/accelerantgine/libz.so"
printf '#!/bin/sh\n' > "${lin}/lib/accelerantgine/launcher.sh"
cp "${repo}/LICENSE" "${lin}/share/licenses/AccelerANTgine/LICENSE"
printf 'ort\n' > "${lin}/share/licenses/onnxruntime/LICENSE"
printf 'ort tpn\n' > "${lin}/share/licenses/onnxruntime/ThirdPartyNotices.txt"
elf "${tmp}/distro/libz.so.1"
elf "${tmp}/opt-gst/libgstreamer-1.0.so.0"
printf 'zlib license; the text is in /usr/share/common-licenses/Zlib-Test.\n' > "${tmp}/doc/libz1/copyright"
printf 'common zlib text\n' > "${tmp}/common/Zlib-Test"
cat > "${tmp}/bin/dpkg" <<SHELL
#!/usr/bin/env bash
[[ "\$1" == -S ]] || exit 2
case "\$2" in
  ${tmp}/distro/libz.so.1) printf 'libz1:amd64: %s\n' "\$2" ;;
  *) exit 1 ;;
esac
SHELL
cat > "${tmp}/bin/dpkg-query" <<'SHELL'
#!/usr/bin/env bash
[[ "${*: -1}" == libz1 ]] && printf '1:1.3.dfsg-1'
SHELL
chmod +x "${tmp}/bin/dpkg" "${tmp}/bin/dpkg-query"
run_linux() {
  "${python}" "${stager}" --manifest "${manifest}" --root "${lin}" --dest "${lin}/share/licenses/AccelerANTgine" \
    --platform linux --repo "${repo}" --project-license share/licenses/AccelerANTgine/LICENSE \
    --define ONNXRUNTIME_VERSION=v9.9 --define GSTREAMER_VERSION=1.99 --text-root "abseil=${tmp}/absl" \
    --search "${tmp}/opt-gst" --search "${tmp}/distro" --dpkg "${tmp}/bin/dpkg" --dpkg-query "${tmp}/bin/dpkg-query" \
    --doc-root "${tmp}/doc" --common-licenses "${tmp}/common"
}
if expect_accepted "${tmp}/lin.log" "a complete Linux tree was refused" run_linux; then
  notices="${lin}/share/licenses/AccelerANTgine/THIRD-PARTY-NOTICES.txt"
  expect_greps "${notices}" <<'PATTERNS'
libz1
  Version: 1:1.3.dfsg-1
File: lib/accelerantgine/libz.so.1
License text: share/licenses/AccelerANTgine/third-party/common-licenses/Zlib-Test
License text: share/licenses/onnxruntime/LICENSE
File: lib/accelerantgine/libgstreamer-1.0.so.0
PATTERNS
  expect_no_grep "${notices}" "launcher.sh"
  [[ -s "${lin}/share/licenses/AccelerANTgine/third-party/common-licenses/Zlib-Test" ]] || fail "cited common license not copied"
  [[ -s "${lin}/share/licenses/AccelerANTgine/third-party/deb-libz1/copyright" ]] || fail "Debian copyright not copied"
  "${python}" - "${lin}/share/licenses/AccelerANTgine/third-party-inventory.json" <<'PY' || fail "first match did not win"
import json
import sys

with open(sys.argv[1], encoding="utf-8") as stream:
    components = {item["id"]: item for item in json.load(stream)["components"]}
assert "lib/accelerantgine/gstreamer-1.0/libgstrswebrtc.so" in components["gst-plugins-rs"]["files"]
assert "lib/accelerantgine/gstreamer-1.0/libgstrswebrtc.so" not in components["gstreamer"]["files"]
assert "lib/accelerantgine/gstreamer-1.0/libgstcoreelements.so" in components["gstreamer"]["files"]
assert components["deb-libz1"]["files"] == ["lib/accelerantgine/libz.so.1"], components["deb-libz1"]["files"]
PY
fi

# A Debian copyright that is missing fails the package.
rm -f "${tmp}/doc/libz1/copyright"
if run_linux > "${tmp}/lin-nocopy.log" 2>&1; then fail "a missing Debian copyright passed"; fi
printf 'zlib license\n' > "${tmp}/doc/libz1/copyright"

# The wheel lists what its binaries link statically: nanobind yes, the CLI's Abseil no.
wheel="${tmp}/wheel/kataglyphis_inference"
mkdir -p "${wheel}/licenses" "${tmp}/fakerepo/third_party/nanobind/ext/robin_map"
elf "${wheel}/_core.cpython-315-x86_64-linux-gnu.so"
elf "${wheel}/libAccelerANTgine.so"
cp "${repo}/LICENSE" "${wheel}/licenses/LICENSE"
cp -R "${repo}/packaging" "${tmp}/fakerepo/packaging"
mkdir -p "${tmp}/fakerepo/third_party/NLOHMANN_JSON" "${tmp}/fakerepo/third_party/tomlplusplus"
printf 'json mit\n' > "${tmp}/fakerepo/third_party/NLOHMANN_JSON/LICENSE.MIT"
printf 'toml mit\n' > "${tmp}/fakerepo/third_party/tomlplusplus/LICENSE"
printf 'nanobind bsd\n' > "${tmp}/fakerepo/third_party/nanobind/LICENSE"
printf 'robin mit\n' > "${tmp}/fakerepo/third_party/nanobind/ext/robin_map/LICENSE"
if "${python}" "${stager}" --manifest "${manifest}" --root "${wheel}" --dest "${wheel}/licenses" --platform linux \
  --scope wheel --repo "${tmp}/fakerepo" --project-license licenses/LICENSE > "${tmp}/wheel.log" 2>&1; then
  expect_grep "${wheel}/licenses/THIRD-PARTY-NOTICES.txt" "nanobind"
  expect_grep "${wheel}/licenses/THIRD-PARTY-NOTICES.txt" "robin-map"
  expect_grep "${wheel}/licenses/THIRD-PARTY-NOTICES.txt" "Rust standard library"
  expect_no_grep "${wheel}/licenses/THIRD-PARTY-NOTICES.txt" "Abseil"
else
  cat "${tmp}/wheel.log" >&2
  fail "the wheel tree was refused"
fi

# Cargo crates come from the collector's manifest; a failing collector fails the package.
cat > "${tmp}/cargo-stager.py" <<'PY'
import json
import sys
from pathlib import Path

args = sys.argv[1:]
output = Path(args[args.index("--output-dir") + 1])
if "--fail" in Path(args[args.index("--policy") + 1]).read_text():
    sys.exit("FAIL: compound license without review")
(output / "cxx@1.0.0" / "package").mkdir(parents=True)
(output / "cxx@1.0.0" / "package" / "LICENSE-MIT").write_text("cxx mit\n")
(output / "manifest.json").write_text(json.dumps({"packages": [
    {"name": "rusty_code", "version": "0.1.0", "license": "MIT", "files": []},
    {"name": "cxx", "version": "1.0.0", "license": "MIT OR Apache-2.0", "repository": "https://github.com/dtolnay/cxx",
     "files": [{"path": "cxx@1.0.0/package/LICENSE-MIT"}]},
]}))
PY
printf '{}' > "${tmp}/policy-ok.json"
printf '{"--fail": 1}' > "${tmp}/policy-fail.json"
cargo_args=(--cargo-stager "${tmp}/cargo-stager.py" --cargo-workspace "${tmp}" --cargo-root-package rusty_code
  --cargo-target x86_64-pc-windows-msvc)
if expect_accepted "${tmp}/cargo.log" "the Cargo crates were refused" run_windows "${win}" "${cargo_args[@]}" --cargo-policy "${tmp}/policy-ok.json"; then
  expect_grep "${win}/licenses/THIRD-PARTY-NOTICES.txt" "cxx (Rust crate)"
  expect_grep "${win}/licenses/THIRD-PARTY-NOTICES.txt" "License text: licenses/third-party/crate-cxx/LICENSE-MIT"
  expect_no_grep "${win}/licenses/THIRD-PARTY-NOTICES.txt" "rusty_code"
fi
if run_windows "${win}" "${cargo_args[@]}" --cargo-policy "${tmp}/policy-fail.json" > "${tmp}/cargo-fail.log" 2>&1; then
  fail "a failing Cargo collector passed"
fi
expect_grep "${tmp}/cargo-fail.log" "compound license without review"

# ONNX Runtime's texts: the chain build's own first, a same-version chain wheel second, never an unrelated library.
ort_stager="${repo}/scripts/packaging/stage_ort_texts.py"
chain="${tmp}/ort/onnxruntime-cpu/lib"
mkdir -p "${chain}" "${tmp}/ort/wheels" "${tmp}/ort/pkg"
printf '\177ELF chain' > "${chain}/libonnxruntime.so.1.31.0"
ln -s libonnxruntime.so.1.31.0 "${chain}/libonnxruntime.so.1"
cp "${chain}/libonnxruntime.so.1.31.0" "${tmp}/ort/pkg/libonnxruntime.so.1"
printf '#!/usr/bin/env python3\nimport sys\nsys.exit(1)\n' > "${tmp}/ort/no-byte-match.py"
make_wheel() {
  "${python}" - "$1" "$2" <<'PY'
import sys
import zipfile

with zipfile.ZipFile(sys.argv[1], "w") as archive:
    archive.writestr("onnxruntime/LICENSE", f"MIT {sys.argv[2]}\n")
    archive.writestr("onnxruntime/ThirdPartyNotices.txt", "notices\n")
PY
}
run_ort() {
  "${python}" "${ort_stager}" --library "${tmp}/ort/pkg/libonnxruntime.so.1" --chain-dir "${chain}" \
    --wheel-dir "${tmp}/ort/wheels" --wheel-stager "${tmp}/ort/no-byte-match.py" --destination "$1"
}
if run_ort "${tmp}/ort/out-none" > "${tmp}/ort-none.log" 2>&1; then fail "ORT texts passed with no source"; fi
make_wheel "${tmp}/ort/wheels/onnxruntime_dnnl-1.31.0-cp315-cp315-linux_x86_64.whl" a
make_wheel "${tmp}/ort/wheels/onnxruntime_dnnl-1.30.0-cp315-cp315-linux_x86_64.whl" old
if expect_accepted "${tmp}/ort-wheel.log" "a same-version chain wheel was refused" run_ort "${tmp}/ort/out-wheel"; then
  expect_grep "${tmp}/ort-wheel.log" "WARN: ONNX Runtime 1.31.0 texts from the chain wheel"
  expect_grep "${tmp}/ort/out-wheel/LICENSE" "MIT a"
fi
make_wheel "${tmp}/ort/wheels/onnxruntime_gpu-1.31.0-cp315-cp315-linux_x86_64.whl" b
if run_ort "${tmp}/ort/out-disagree" > "${tmp}/ort-disagree.log" 2>&1; then fail "disagreeing chain wheels passed"; fi
rm -f "${tmp}/ort/wheels/onnxruntime_gpu-1.31.0-cp315-cp315-linux_x86_64.whl"
mkdir -p "${tmp}/ort/onnxruntime-cpu/licenses"
printf 'MIT chain\n' > "${tmp}/ort/onnxruntime-cpu/licenses/LICENSE"
printf 'chain notices\n' > "${tmp}/ort/onnxruntime-cpu/licenses/ThirdPartyNotices.txt"
if expect_accepted "${tmp}/ort-chain.log" "the chain build's own texts were refused" run_ort "${tmp}/ort/out-chain"; then
  expect_grep "${tmp}/ort/out-chain/LICENSE" "MIT chain"
fi
printf '\177ELF other' > "${tmp}/ort/pkg/libonnxruntime.so.1"
if run_ort "${tmp}/ort/out-foreign" > "${tmp}/ort-foreign.log" 2>&1; then fail "a foreign ORT library passed"; fi
expect_grep "${tmp}/ort-foreign.log" "is not the chain build"

# Every tracked text the inventory names exists, and the crate's license is the project's.
"${python}" - "${repo}" <<'PY' || fail "the inventory names a missing tracked text"
import json
import sys
from pathlib import Path

repo = Path(sys.argv[1])
inventory = json.loads((repo / "packaging/third-party/components.json").read_text(encoding="utf-8"))
for entry in inventory["components"]:
    texts = entry.get("texts", [])
    lists = texts.values() if isinstance(texts, dict) else [texts]
    for text in (item for group in lists for item in group):
        if text["root"] == "repo" and text["path"].startswith("packaging/"):
            assert (repo / text["path"]).stat().st_size > 0, text["path"]
PY
cmp -s "${repo}/LICENSE" "${repo}/Src/rusty_code/LICENSE" || fail "Src/rusty_code/LICENSE differs from LICENSE"

if [[ "${failures}" -ne 0 ]]; then
  printf '%d third-party notice check(s) failed\n' "${failures}" >&2
  exit 1
fi
printf 'third-party notices: all checks passed\n'
