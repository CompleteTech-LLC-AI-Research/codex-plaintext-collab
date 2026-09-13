#!/usr/bin/env bash
#
# Register a Codex SessionStart hook that verifies the patched binary and
# repairs it from the build cache after an update.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

CODEX_HOME="${CODEX_HOME:-$HOME/.codex}"
AUTO_BUILD=0
QUIET=0

usage() {
  cat <<'EOF'
Usage: install-hook.sh [--codex-home DIR] [--auto-build] [--quiet]

  --codex-home DIR   Codex home whose hooks.json should be updated
  --auto-build       Allow the hook to start a background rebuild when no
                     cached patched build exists for a new version
  --quiet            Suppress non-error output
  -h, --help         Show this help
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --codex-home) CODEX_HOME="${2:-}"; shift 2 ;;
    --auto-build) AUTO_BUILD=1; shift ;;
    --quiet) QUIET=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "error: unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

command -v python3 >/dev/null 2>&1 || plaintext_die "python3 is required to edit hooks.json"

HOOKS_JSON="$CODEX_HOME/hooks.json"
mkdir -p "$CODEX_HOME"

hook_cmd="bash '$SCRIPT_DIR/hook-verify.sh' --codex-home '$CODEX_HOME'"
[[ "$AUTO_BUILD" -eq 1 ]] && hook_cmd="$hook_cmd --auto-build"

HOOK_CMD="$hook_cmd" HOOKS_JSON="$HOOKS_JSON" NEEDLE="$PLAINTEXT_HOOK_NEEDLE" \
HOOK_BACKUP="$PLAINTEXT_HOOK_BACKUP" python3 - <<'PY'
import json, os, shutil, sys, tempfile

hooks_path = os.environ["HOOKS_JSON"]
needle = os.environ["NEEDLE"]
backup = os.environ["HOOK_BACKUP"]
command = os.environ["HOOK_CMD"]

data = {}
if os.path.exists(hooks_path) and os.path.getsize(hooks_path) > 0:
    try:
        with open(hooks_path, encoding="utf-8") as fh:
            data = json.load(fh)
    except json.JSONDecodeError as exc:
        sys.exit(f"error: {hooks_path} is not valid JSON: {exc}")
    if not os.path.exists(hooks_path + "." + backup):
        shutil.copy2(hooks_path, hooks_path + "." + backup)

if not isinstance(data, dict):
    sys.exit("error: hooks.json must contain a JSON object")
hooks = data.setdefault("hooks", {})
session_start = hooks.setdefault("SessionStart", [])
if not isinstance(session_start, list):
    sys.exit("error: hooks.SessionStart must be a list")

# Drop any previous entry managed by this project.
session_start[:] = [
    group for group in session_start
    if not (isinstance(group, dict) and any(
        needle in str(h.get("command", ""))
        for h in group.get("hooks", []) if isinstance(h, dict)
    ))
]

session_start.append({
    "hooks": [{"type": "command", "command": command, "timeout": 30}]
})

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

index = len(session_start) - 1
print(f"{hooks_path}:session_start:{index}:0")
PY

if [[ "$QUIET" -ne 1 ]]; then
  echo "Registered SessionStart verification hook in $HOOKS_JSON"
  echo "Codex may ask you to trust the new hook (or set bypass_hook_trust = true)."
  echo "Remove it with: $SCRIPT_DIR/remove-hook.sh --codex-home $CODEX_HOME"
fi
