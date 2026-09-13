#!/usr/bin/env bash
#
# Ensure the Codex managed (standalone) install for a CODEX_HOME is running the
# patched, plaintext-collaboration binary. Safe to run after every Codex update.
#
set -euo pipefail

CODEX_HOME="${CODEX_HOME:-$HOME/.codex}"
FORCE=0

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PATCH_FILE="$SCRIPT_DIR/../patches/0001-disable-collab-message-encryption.patch"
CACHE_DIR="${CODEX_PLAINTEXT_CACHE:-${XDG_CACHE_HOME:-$HOME/.cache}/codex-plaintext-collab}"
MARKER_NAME=".plaintext-collab-patched"

usage() {
  cat <<'EOF'
Usage: ensure-patched.sh [--codex-home DIR] [--force]

  --codex-home DIR   Codex home whose managed install should be patched
                     (default: $CODEX_HOME or ~/.codex)
  --force            Re-install the patched binary even if marked as patched
  -h, --help         Show this help
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --codex-home) CODEX_HOME="${2:-}"; shift 2 ;;
    --force) FORCE=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "error: unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

[[ -f "$PATCH_FILE" ]] || { echo "error: patch not found: $PATCH_FILE" >&2; exit 1; }

STANDALONE="$CODEX_HOME/packages/standalone"
if [[ ! -d "$STANDALONE" ]]; then
  echo "error: no managed Codex install at $STANDALONE" >&2
  echo "Run Codex once so it installs its managed package, then retry." >&2
  exit 3
fi

CURRENT="$(readlink -f "$STANDALONE/current" 2>/dev/null || true)"
if [[ -z "$CURRENT" || ! -d "$CURRENT" ]]; then
  CURRENT="$(find "$STANDALONE/releases" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort -V | tail -n1 || true)"
fi
if [[ -z "$CURRENT" || ! -d "$CURRENT" ]]; then
  echo "error: no Codex release found under $STANDALONE" >&2
  exit 3
fi

VERSION=""
if [[ -f "$CURRENT/codex-package.json" ]] && command -v python3 >/dev/null 2>&1; then
  VERSION="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["version"])' \
    "$CURRENT/codex-package.json" 2>/dev/null || true)"
fi
if [[ -z "$VERSION" ]]; then
  VERSION="$(basename "$CURRENT" | sed -E 's/^([0-9]+\.[0-9]+\.[0-9]+).*/\1/')"
fi
[[ -n "$VERSION" ]] || { echo "error: could not determine Codex version for $CURRENT" >&2; exit 3; }

BIN="$CURRENT/bin/codex"
[[ -f "$BIN" ]] || { echo "error: missing managed binary: $BIN" >&2; exit 3; }

PATCH_HASH="$(sha256sum "$PATCH_FILE" | awk '{print $1}')"
MARKER="$CURRENT/$MARKER_NAME"

if [[ "$FORCE" -ne 1 && -f "$MARKER" && "$(cat "$MARKER" 2>/dev/null)" == "$VERSION:$PATCH_HASH" ]]; then
  echo "Codex $VERSION is already patched."
  exit 0
fi

OUT_BIN="$CACHE_DIR/bin/codex-$VERSION"
if [[ ! -x "$OUT_BIN" || "$FORCE" -eq 1 ]]; then
  "$SCRIPT_DIR/build-patched-codex.sh" --version "$VERSION" --cache-dir "$CACHE_DIR" >/dev/null
fi

if [[ ! -f "$BIN.orig" ]]; then
  cp -p "$BIN" "$BIN.orig"
fi

tmp="$CURRENT/bin/.codex.patched.$$"
install -m 0755 "$OUT_BIN" "$tmp"
mv -f "$tmp" "$BIN"
printf '%s' "$VERSION:$PATCH_HASH" > "$MARKER"

echo "Patched Codex $VERSION -> $BIN"
