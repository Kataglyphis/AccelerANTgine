#!/usr/bin/env bash
# The local WebRTC signalling server three checks start; each caller keeps its own messages and cleanup.

# Usage: start_local_signalling PORT LOG PID_VAR; sets PID_VAR at once, so a caller's cleanup ends the server even when it never listened.
start_local_signalling() {
  local port=$1 log=$2 attempt
  gst-webrtc-signalling-server --host 127.0.0.1 --port "$port" > "$log" 2>&1 &
  printf -v "$3" '%s' "$!"
  for ((attempt = 0; attempt < 50; attempt++)); do
    sleep 0.2
    if ! kill -0 "${!3}" 2>/dev/null; then
      echo "the signalling server exited before it listened on 127.0.0.1:$port" >&2
      return 1
    fi
    if (exec 3<>"/dev/tcp/127.0.0.1/$port") 2>/dev/null; then return 0; fi
  done
  echo "the signalling server did not listen on 127.0.0.1:$port within 10 s" >&2
  return 1
}

# Usage: stop_local_signalling PID; nothing to do for an empty PID, and a server that already exited is no failure.
stop_local_signalling() {
  [[ -n $1 ]] || return 0
  kill "$1" 2>/dev/null || true
  wait "$1" 2>/dev/null || true
}
