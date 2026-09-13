#!/usr/bin/env bash
#
# Build a patched Codex CLI binary for a given upstream version.
#
# The resulting binary is cached at:
#   ${CODEX_PLAINTEXT_CACHE:-${XDG_CACHE_HOME:-$HOME/.cache}/codex-plaintext-collab}/bin/codex-<version>
#
set -euo pipefail

REPO_URL="${CODEX_SOURCE_URL:-https://github.com/openai/codex.git}"
CACHE_DIR="${CODEX_PLAINTEXT_CACHE:-${XDG_CACHE_HOME:-$HOME/.cache}/codex-plaintext-collab}"
VERSION=""
JOBS=""
FORCE=0

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PATCH_FILE="$REPO_ROOT/patches/0001-disable-collab-message-encryption.patch"

usage() {
  cat <<'EOF'
Usage: build-patched-codex.sh [--version X.Y.Z] [--jobs N] [--cache-dir DIR] [--force]

  --version X.Y.Z   Upstream Codex version to build (default: detect from `codex --version`)
  --jobs N          Pass -j N to cargo
  --cache-dir DIR   Override the source/binary cache directory
  --force           Rebuild even if a cached patched binary exists
  -h, --help        Show this help

On success the path to the patched binary is printed on the last line of stdout.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --version) VERSION="${2:-}"; shift 2 ;;
    --jobs|-j) JOBS="${2:-}"; shift 2 ;;
    --cache-dir) CACHE_DIR="${2:-}"; shift 2 ;;
    --force) FORCE=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "error: unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

for tool in git cargo rustc; do
  command -v "$tool" >/dev/null 2>&1 || { echo "error: missing required tool: $tool" >&2; exit 1; }
done

if [[ -z "$VERSION" ]]; then
  if command -v codex >/dev/null 2>&1; then
    VERSION="$(codex --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -n1 || true)"
  fi
fi
if [[ -z "$VERSION" ]]; then
  echo "error: could not determine Codex version; pass --version X.Y.Z" >&2
  exit 2
fi

TAG="rust-v$VERSION"
SRC_DIR="$CACHE_DIR/src"
OUT_DIR="$CACHE_DIR/bin"
OUT_BIN="$OUT_DIR/codex-$VERSION"
TARGET_TRIPLE="$(rustc -vV | awk '/^host:/ {print $2}')"

mkdir -p "$CACHE_DIR" "$OUT_DIR"

if [[ -x "$OUT_BIN" && "$FORCE" -ne 1 ]]; then
  echo "Cached patched binary: $OUT_BIN" >&2
  echo "$OUT_BIN"
  exit 0
fi

if [[ ! -d "$SRC_DIR/.git" ]]; then
  echo "Cloning $REPO_URL ..." >&2
  rm -rf "$SRC_DIR"
  git clone --filter=blob:none --no-checkout "$REPO_URL" "$SRC_DIR"
fi

echo "Fetching $TAG ..." >&2
if ! git -C "$SRC_DIR" fetch --depth 1 origin "refs/tags/$TAG:refs/tags/$TAG"; then
  git -C "$SRC_DIR" fetch --tags origin
fi
git -C "$SRC_DIR" checkout -f "$TAG"
git -C "$SRC_DIR" clean -fdx -e codex-rs/target

if git -C "$SRC_DIR" apply --reverse --check "$PATCH_FILE" >/dev/null 2>&1; then
  echo "Patch already applied." >&2
else
  echo "Applying $(basename "$PATCH_FILE") ..." >&2
  git -C "$SRC_DIR" apply "$PATCH_FILE"
fi

build_args=(build --release --locked -p codex-cli --bin codex
  --manifest-path "$SRC_DIR/codex-rs/Cargo.toml")
if [[ -n "$JOBS" ]]; then
  build_args+=(-j "$JOBS")
fi

echo "Building patched Codex $VERSION ($TARGET_TRIPLE) ..." >&2
cargo "${build_args[@]}"

install -m 0755 "$SRC_DIR/codex-rs/target/release/codex" "$OUT_BIN"
echo "Built patched Codex $VERSION: $OUT_BIN" >&2
echo "$OUT_BIN"
