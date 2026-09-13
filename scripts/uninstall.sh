#!/usr/bin/env bash
#
# Uninstall the plaintext-collab patch: restore the original Codex binary, drop
# the patch marker, remove the verification hook, and optionally purge caches.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

CODEX_HOME="${CODEX_HOME:-$HOME/.codex}"
ALL_RELEASES=0
PURGE_CACHE=0
REMOVE_WRAPPER=0
QUIET=0

usage() {
  cat <<'EOF'
Usage: uninstall.sh [--codex-home DIR] [--all] [--purge-cache] [--remove-wrapper] [--quiet]

  --codex-home DIR   Codex home to clean (default: $CODEX_HOME or ~/.codex)
  --all              Restore every release under packages/standalone/releases,
                     not just the active one
  --purge-cache      Delete the downloaded source and built binaries cache
  --remove-wrapper   Remove ~/.local/bin/codex-plaintext if it points at this repo
  --quiet            Suppress non-error output
  -h, --help         Show this help
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --codex-home) CODEX_HOME="${2:-}"; shift 2 ;;
    --all) ALL_RELEASES=1; shift ;;
    --purge-cache) PURGE_CACHE=1; shift ;;
    --remove-wrapper) REMOVE_WRAPPER=1; shift ;;
    --quiet) QUIET=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "error: unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

log() { [[ "$QUIET" -eq 1 ]] || echo "$@"; }

restore_release() {
  local release="$1"
  local bin="$release/bin/codex"
  local orig="$release/bin/codex.orig"
  local marker="$release/$PLAINTEXT_MARKER_NAME"
  local changed=0

  if [[ -f "$orig" ]]; then
    tmp="$release/bin/.codex.restore.$$"
    install -m 0755 "$orig" "$tmp"
    mv -f "$tmp" "$bin"
    rm -f "$orig"
    log "Restored original binary: $bin"
    changed=1
  fi
  if [[ -f "$marker" ]]; then
    rm -f "$marker"
    changed=1
  fi
  [[ "$changed" -eq 1 ]]
}

if [[ "$ALL_RELEASES" -eq 1 ]]; then
  releases_dir="$CODEX_HOME/packages/standalone/releases"
  if [[ -d "$releases_dir" ]]; then
    while IFS= read -r release; do
      restore_release "$release" || true
    done < <(find "$releases_dir" -mindepth 1 -maxdepth 1 -type d | sort -V)
  else
    log "No releases directory at $releases_dir"
  fi
else
  if plaintext_resolve_release "$CODEX_HOME"; then
    restore_release "$PLAINTEXT_RELEASE_DIR" || log "Nothing to restore for Codex $PLAINTEXT_VERSION."
  else
    log "No managed Codex install found under $CODEX_HOME/packages/standalone."
  fi
fi

"$SCRIPT_DIR/remove-hook.sh" --codex-home "$CODEX_HOME" --quiet

if [[ "$REMOVE_WRAPPER" -eq 1 ]]; then
  link="$HOME/.local/bin/codex-plaintext"
  if [[ -L "$link" ]] && [[ "$(plaintext_realpath "$link")" == "$SCRIPT_DIR/codex-patched" ]]; then
    rm -f "$link"
    log "Removed wrapper: $link"
  fi
fi

if [[ "$PURGE_CACHE" -eq 1 ]]; then
  cache="${CODEX_PLAINTEXT_CACHE:-${XDG_CACHE_HOME:-$HOME/.cache}/codex-plaintext-collab}"
  rm -rf "$cache"
  log "Purged cache: $cache"
fi

log "Uninstall complete."
