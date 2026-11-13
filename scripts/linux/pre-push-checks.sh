#!/usr/bin/env bash
# This repo's script suites, run by the hub's pre-push hook after the lint gates: a pin move that turns one red stops the push.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/../.."
for suite in scripts/linux/tests/test-*.sh; do
  # This one needs a built demo, a model and a fixture as arguments; the lane that has them runs it.
  [ "${suite##*/}" != test-demo-detector-safety.sh ] || continue
  bash "${suite}"
done
for suite in scripts/linux/tests/test-*.py; do python3 "${suite}"; done
