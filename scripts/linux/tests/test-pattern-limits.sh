#!/usr/bin/env bash
# The direct-stdout ban of quality-report.toml on a planted tree; run-lint-gates.sh grades the real Src/.
set -euo pipefail

# shellcheck source=suite-fixture.sh
source "$(dirname "${BASH_SOURCE[0]}")/suite-fixture.sh"
root=$SUITE_ROOT work=$SUITE_WORK
gate="${root}/third_party/ANTfrastructure/linux/scripts/verify_pattern_limits.py"

cp "${root}/quality-report.toml" "${work}/"
mkdir -p "${work}/Src"
printf 'int main() {\n  std::cout << "verdict";\n}\n' > "${work}/Src/cli_main.cpp"
printf 'void load() {\n  kataglyphis::log::info("ok");\n}\n' > "${work}/Src/engine.cpp"
git -C "${work}" init -q && git -C "${work}" add -A
grade() { python3 "${gate}" --root "${work}" >"${work}/out" 2>&1; }

suite_expect pass 'the CLI front end prints its output, and kataglyphis::log is no match' grade
for call in 'g_print ("x");' 'printf("x");' 'std::cout << x;'; do
  printf 'void load() {\n  %s\n}\n' "${call}" > "${work}/Src/engine.cpp"
  git -C "${work}" add -A
  suite_expect fail "a direct ${call%%[ (<]*} diagnostic in Src/ fails the lint gates" grade
  grep -q 'Src/engine.cpp:2:' "${work}/out" || fail "the finding for ${call} does not name file and line"
done

suite_finish pattern-limits
echo 'pattern limits: all cases passed'
