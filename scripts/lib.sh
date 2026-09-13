#!/usr/bin/env bash
#
# Shared helpers for codex-plaintext-collab scripts. This file is meant to be
# sourced, not executed.
#

PLAINTEXT_MARKER_NAME=".plaintext-collab-patched"
PLAINTEXT_HOOK_NEEDLE="hook-verify.sh"
PLAINTEXT_HOOK_BACKUP="hooks.json.plaintext-collab.bak"

plaintext_die() {
  echo "error: $*" >&2
  exit 1
}

plaintext_realpath() {
  local target="$1"
  if command -v python3 >/dev/null 2>&1; then
    python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$target"
  elif readlink -f "$target" >/dev/null 2>&1; then
    readlink -f "$target"
  else
    echo "$target"
  fi
}

plaintext_file_hash() {
  sha256sum "$1" | awk '{print $1}'
}

# Resolve the active managed Codex release for a CODEX_HOME.
#
# Sets:
#   PLAINTEXT_RELEASE_DIR  absolute path to the release directory
#   PLAINTEXT_VERSION      upstream version string
#   PLAINTEXT_BIN          path to the managed codex binary
#   PLAINTEXT_MARKER       path to the patch marker file
#
# Returns 3 when there is no managed install or the version cannot be read.
plaintext_resolve_release() {
  local codex_home="${1:-${CODEX_HOME:-$HOME/.codex}}"
  local standalone current version=""

  standalone="$codex_home/packages/standalone"
  [[ -d "$standalone" ]] || return 3

  if [[ -L "$standalone/current" || -e "$standalone/current" ]]; then
    current="$(plaintext_realpath "$standalone/current")"
  fi
  if [[ -z "$current" || ! -d "$current" ]]; then
    current="$(find "$standalone/releases" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort -V | tail -n1 || true)"
  fi
  [[ -n "$current" && -d "$current" ]] || return 3

  if [[ -f "$current/codex-package.json" ]] && command -v python3 >/dev/null 2>&1; then
    version="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["version"])' \
      "$current/codex-package.json" 2>/dev/null || true)"
  fi
  if [[ -z "$version" ]]; then
    version="$(basename "$current" | sed -E 's/^([0-9]+\.[0-9]+\.[0-9]+).*/\1/')"
  fi
  [[ -n "$version" ]] || return 3

  PLAINTEXT_RELEASE_DIR="$current"
  PLAINTEXT_VERSION="$version"
  PLAINTEXT_BIN="$current/bin/codex"
  PLAINTEXT_MARKER="$current/$PLAINTEXT_MARKER_NAME"
  return 0
}

# Print the expected marker contents for a release, given the patch and the
# hash of the patched binary that was installed.
plaintext_marker_value() {
  local patch_hash="$1"
  local binary_hash="$2"
  printf '%s:%s:%s' "$PLAINTEXT_VERSION" "$patch_hash" "$binary_hash"
}
