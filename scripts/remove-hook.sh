#!/usr/bin/env bash
#
# Remove the SessionStart verification hook installed by install-hook.sh.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

CODEX_HOME="${CODEX_HOME:-$HOME/.codex}"
QUIET=0

usage() {
  cat <<'EOF'
Usage: remove-hook.sh [--codex-home DIR] [--quiet]

  --codex-home DIR   Codex home whose hooks.json should be updated
  --quiet            Suppress non-error output
  -h, --help         Show this help
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --codex-home) CODEX_HOME="${2:-}"; shift 2 ;;
    --quiet) QUIET=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "error: unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

HOOKS_JSON="$CODEX_HOME/hooks.json"
if [[ ! -f "$HOOKS_JSON" ]]; then
  [[ "$QUIET" -eq 1 ]] || echo "No hooks.json found; nothing to remove."
  exit 0
fi

command -v python3 >/dev/null 2>&1 || plaintext_die "python3 is required to edit hooks.json"

HOOKS_JSON="$HOOKS_JSON" NEEDLE="$PLAINTEXT_HOOK_NEEDLE" python3 - <<'PY'
import json, os, sys, tempfile

hooks_path = os.environ["HOOKS_JSON"]
needle = os.environ["NEEDLE"]

with open(hooks_path, encoding="utf-8") as fh:
    data = json.load(fh)

hooks = data.get("hooks", {})
session_start = hooks.get("SessionStart", [])
if isinstance(session_start, list):
    kept = [
        group for group in session_start
        if not (isinstance(group, dict) and any(
            needle in str(h.get("command", ""))
            for h in group.get("hooks", []) if isinstance(h, dict)
        ))
    ]
    if kept:
        hooks["SessionStart"] = kept
    else:
        hooks.pop("SessionStart", None)

fd, tmp = tempfile.mkstemp(prefix=".hooks-", dir=os.path.dirname(hooks_path) or ".")
try:
    with os.fdopen(fd, "w", encoding="utf-8") as fh:
        json.dump(data, fh, indent=2)
        fh.write("\n")
        fh.flush()
        os.fsync(fh.fileno())
    os.replace(tmp, hooks_path)
finally:
    if os.path.exists(tmp):
        os.unlink(tmp)
PY

[[ "$QUIET" -eq 1 ]] || echo "Removed SessionStart verification hook from $HOOKS_JSON"
