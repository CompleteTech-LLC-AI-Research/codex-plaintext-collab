#!/usr/bin/env bash
#
# Codex SessionStart hook body: verify the active Codex binary is the patched
# build and, when possible, repair it from the local build cache.
#
# This is designed to be registered by install-hook.sh. It never fails the
# session and never performs a (slow) build unless --auto-build is passed.
#
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CODEX_HOME="${CODEX_HOME:-$HOME/.codex}"
AUTO_BUILD=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --codex-home) CODEX_HOME="${2:-}"; shift 2 ;;
    --auto-build) AUTO_BUILD=1; shift ;;
    *) shift ;;
  esac
done

# Codex writes the hook payload to stdin; drain it so the process can exit.
cat >/dev/null 2>&1 || true

if "$SCRIPT_DIR/verify-patched.sh" --quiet --codex-home "$CODEX_HOME" 2>/dev/null; then
  exit 0
fi

if "$SCRIPT_DIR/ensure-patched.sh" --quiet --no-build --codex-home "$CODEX_HOME" 2>/dev/null; then
  echo "[codex-plaintext-collab] Codex was updated; the patched binary was reinstalled. Restart this session to use it."
  exit 0
fi

if [[ "$AUTO_BUILD" -eq 1 ]]; then
  log="${TMPDIR:-/tmp}/codex-plaintext-build.log"
  nohup "$SCRIPT_DIR/ensure-patched.sh" --quiet --codex-home "$CODEX_HOME" >>"$log" 2>&1 &
  echo "[codex-plaintext-collab] Codex was updated; building a patched binary in the background (log: $log)."
  exit 0
fi

echo "[codex-plaintext-collab] Codex is not patched for the active version. Run: $SCRIPT_DIR/ensure-patched.sh --codex-home $CODEX_HOME"
exit 0
