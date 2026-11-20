#!/usr/bin/env bash
# Usage: cli_stream_status_test.sh CLI. Does not cover the codec failure path, which only a finished package reproduces, or a finite source's end.
set -euo pipefail
# shellcheck source=scripts/linux/lib/signalling.sh
source "$(dirname "${BASH_SOURCE[0]}")/../../scripts/linux/lib/signalling.sh"

cli=$1
window=5
work="$(mktemp -d "${TMPDIR:-/tmp}/accelerantgine-cli-status.XXXXXXXX")"
signalling=""
cleanup() {
  stop_local_signalling "$signalling"
  rm -rf -- "$work"
}
trap cleanup EXIT

die() {
  cat "$work/out" >&2 2>/dev/null || true
  echo "FAILED: $*" >&2
  exit 1
}

free_port() {
  python3 -I -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])'
}

# Usage: stream PORT WINDOW; the outer bound ends a CLI that ignores the signal, and not -k, which uutils' timeout applies at once.
stream() {
  timeout -s KILL "$(($2 + 20))" timeout --preserve-status -s INT "$2" "$cli" --webrtc --source test \
    --server="ws://127.0.0.1:$1" > "$work/out" 2>&1 < /dev/null
}

status=0
# Nothing listens on a port just freed, so the signaller's connection is refused long before this window closes.
stream "$(free_port)" 60 || status=$?
[[ $status -eq 1 ]] || die "a stream with no signalling server exited $status, not 1"
grep -Fq 'Stream failed' "$work/out" || die 'the failed stream did not say so; another early exit satisfied the status'

command -v gst-webrtc-signalling-server > /dev/null || die 'gst-webrtc-signalling-server is not on PATH'
port="$(free_port)"
start_local_signalling "$port" "$work/signalling.log" signalling || die 'the signalling server did not start'
started=$SECONDS
status=0
stream "$port" "$window" || status=$?
elapsed=$((SECONDS - started))
[[ $status -eq 0 ]] || die "a healthy stream stopped by its window exited $status, not 0"
[[ $elapsed -ge $window ]] || die "the stream exited after ${elapsed}s, before its ${window}s window closed"
