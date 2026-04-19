#!/bin/bash
# lib/util.sh — Portable utility helpers (ADR-010)
#
# op_timeout: single cross-platform timeout wrapper for all external calls
# js_string:  safe JSON string quoting via stdin to avoid shell injection

# op_timeout <seconds> <command...>
# Wraps command in a timeout. Tries: timeout (Linux) → gtimeout (Homebrew coreutils) → perl alarm.
op_timeout() {
  local secs="$1"; shift
  if command -v timeout &>/dev/null; then
    timeout "$secs" "$@"
  elif command -v gtimeout &>/dev/null; then
    gtimeout "$secs" "$@"
  else
    # perl fallback — available on every macOS installation
    perl -e "alarm $secs; exec @ARGV" -- "$@"
  fi
}

# js_string <value>
# Returns JSON-safe double-quoted string for <value>.
# Passes value via stdin so single quotes and backslashes in the value
# cannot break out of the JS literal — no shell injection vector.
js_string() {
  local val="$1"
  printf '%s' "$val" | node -e "
    let s = '';
    process.stdin.on('data', d => s += d);
    process.stdin.on('end', () => process.stdout.write(JSON.stringify(s)));
  " 2>/dev/null || printf '""'
}
