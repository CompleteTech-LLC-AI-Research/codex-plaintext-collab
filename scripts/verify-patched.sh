#!/usr/bin/env bash
#
# Verify that the active managed Codex binary is the patched, plaintext-collab
# build. Read-only: this never modifies the installation.
#
# Exit codes: 0 = patched/correct, 1 = not patched, 3 = no managed install.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

CODEX_HOME="${CODEX_HOME:-$HOME/.codex}"
QUIET=0
AS_JSON=0

usage() {
  cat <<'EOF'
Usage: verify-patched.sh [--codex-home DIR] [--quiet] [--json]

  --codex-home DIR   Codex home to verify (default: $CODEX_HOME or ~/.codex)
  --quiet            Print nothing on success
  --json             Print a JSON result
  -h, --help         Show this help
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --codex-home) CODEX_HOME="${2:-}"; shift 2 ;;
    --quiet) QUIET=1; shift ;;
    --json) AS_JSON=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "error: unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

fail() {
  local reason="$1"
  if [[ "$AS_JSON" -eq 1 ]]; then
    printf '{"patched":false,"reason":"%s"}\n' "$reason"
  elif [[ "$QUIET" -ne 1 ]]; then
    echo "unpatched: $reason" >&2
  fi
  exit 1
}

if ! plaintext_resolve_release "$CODEX_HOME"; then
  if [[ "$AS_JSON" -eq 1 ]]; then
    printf '{"patched":false,"reason":"no-managed-install"}\n'
  elif [[ "$QUIET" -ne 1 ]]; then
    echo "unpatched: no managed Codex install under $CODEX_HOME/packages/standalone" >&2
  fi
  exit 3
fi

PATCH_FILE="$SCRIPT_DIR/../patches/0001-disable-collab-message-encryption.patch"
[[ -f "$PATCH_FILE" ]] || plaintext_die "patch not found: $PATCH_FILE"

EXPECTED_PATCH_HASH="$(plaintext_file_hash "$PATCH_FILE")"

[[ -f "$PLAINTEXT_BIN" ]] || fail "missing managed binary"
[[ -f "$PLAINTEXT_MARKER" ]] || fail "no patch marker (not patched, or Codex updated)"

IFS=: read -r marker_version marker_patch marker_bin < "$PLAINTEXT_MARKER" || true
[[ -n "${marker_version:-}" && -n "${marker_patch:-}" && -n "${marker_bin:-}" ]] \
  || fail "malformed marker"

[[ "$marker_version" == "$PLAINTEXT_VERSION" ]] \
  || fail "marker version $marker_version != active version $PLAINTEXT_VERSION"
[[ "$marker_patch" == "$EXPECTED_PATCH_HASH" ]] \
  || fail "patch changed since install (${marker_patch:0:12} != ${EXPECTED_PATCH_HASH:0:12})"

ACTUAL_BIN_HASH="$(plaintext_file_hash "$PLAINTEXT_BIN")"
[[ -n "$marker_bin" && "$ACTUAL_BIN_HASH" == "$marker_bin" ]] \
  || fail "installed binary is not the patched build (hash mismatch)"

if [[ "$AS_JSON" -eq 1 ]]; then
  printf '{"patched":true,"version":"%s","binary_sha256":"%s","patch_sha256":"%s"}\n' \
    "$PLAINTEXT_VERSION" "$ACTUAL_BIN_HASH" "$EXPECTED_PATCH_HASH"
elif [[ "$QUIET" -ne 1 ]]; then
  echo "patched: Codex $PLAINTEXT_VERSION ($PLAINTEXT_BIN)"
fi

exit 0
