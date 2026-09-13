#!/usr/bin/env bash
#
# Ensure the Codex managed (standalone) install for a CODEX_HOME is running the
# patched, plaintext-collaboration binary. Safe to run after every Codex update.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

CODEX_HOME="${CODEX_HOME:-$HOME/.codex}"
FORCE=0
NO_BUILD=0
QUIET=0
CHECK_ONLY=0

CACHE_DIR="${CODEX_PLAINTEXT_CACHE:-${XDG_CACHE_HOME:-$HOME/.cache}/codex-plaintext-collab}"
PATCH_FILE="$SCRIPT_DIR/../patches/0001-disable-collab-message-encryption.patch"

usage() {
  cat <<'EOF'
Usage: ensure-patched.sh [--codex-home DIR] [--force] [--no-build] [--quiet] [--check]

  --codex-home DIR   Codex home whose managed install should be patched
                     (default: $CODEX_HOME or ~/.codex)
  --force            Reinstall the patched binary even if already patched
  --no-build         Install only if a cached patched build exists; never build
  --quiet            Suppress non-error output
  --check            Only verify (same as verify-patched.sh)
  -h, --help         Show this help
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --codex-home) CODEX_HOME="${2:-}"; shift 2 ;;
    --force) FORCE=1; shift ;;
    --no-build) NO_BUILD=1; shift ;;
    --quiet) QUIET=1; shift ;;
    --check) CHECK_ONLY=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "error: unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

log() { [[ "$QUIET" -eq 1 ]] || echo "$@" >&2; }

if [[ "$CHECK_ONLY" -eq 1 ]]; then
  args=(--codex-home "$CODEX_HOME")
  [[ "$QUIET" -eq 1 ]] && args+=(--quiet)
  exec "$SCRIPT_DIR/verify-patched.sh" "${args[@]}"
fi

[[ -f "$PATCH_FILE" ]] || plaintext_die "patch not found: $PATCH_FILE"

if ! plaintext_resolve_release "$CODEX_HOME"; then
  plaintext_die "no managed Codex install at $CODEX_HOME/packages/standalone (run Codex once first)"
fi

PATCH_HASH="$(plaintext_file_hash "$PATCH_FILE")"

if [[ "$FORCE" -ne 1 && -f "$PLAINTEXT_MARKER" ]]; then
  current_marker="$(cat "$PLAINTEXT_MARKER" 2>/dev/null || true)"
  if [[ "$current_marker" == "$PLAINTEXT_VERSION:$PATCH_HASH:"* ]]; then
    recorded_bin_hash="${current_marker##*:}"
    actual_bin_hash="$(plaintext_file_hash "$PLAINTEXT_BIN" 2>/dev/null || true)"
    if [[ -n "$recorded_bin_hash" && "$recorded_bin_hash" == "$actual_bin_hash" ]]; then
      log "Codex $PLAINTEXT_VERSION is already patched."
      exit 0
    fi
  fi
fi

OUT_BIN="$CACHE_DIR/bin/codex-$PLAINTEXT_VERSION"
if [[ ! -x "$OUT_BIN" || "$FORCE" -eq 1 ]]; then
  if [[ "$NO_BUILD" -eq 1 ]]; then
    plaintext_die "no cached patched build for Codex $PLAINTEXT_VERSION ($CACHE_DIR/bin)"
  fi
  "$SCRIPT_DIR/build-patched-codex.sh" --version "$PLAINTEXT_VERSION" --cache-dir "$CACHE_DIR" >/dev/null
fi

[[ -x "$OUT_BIN" ]] || plaintext_die "patched build missing after build step: $OUT_BIN"

if [[ ! -f "$PLAINTEXT_BIN.orig" ]]; then
  cp -p "$PLAINTEXT_BIN" "$PLAINTEXT_BIN.orig"
fi

tmp="$PLAINTEXT_RELEASE_DIR/bin/.codex.patched.$$"
install -m 0755 "$OUT_BIN" "$tmp"
mv -f "$tmp" "$PLAINTEXT_BIN"

printf '%s\n' "$(plaintext_marker_value "$PATCH_HASH" "$(plaintext_file_hash "$PLAINTEXT_BIN")")" \
  > "$PLAINTEXT_MARKER"

log "Patched Codex $PLAINTEXT_VERSION -> $PLAINTEXT_BIN"
