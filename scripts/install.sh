#!/usr/bin/env bash
#
# Install the patched-codex launcher into a directory on your PATH.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEST="${1:-$HOME/.local/bin}"
NAME="codex-plaintext"

mkdir -p "$DEST"
ln -sf "$SCRIPT_DIR/codex-patched" "$DEST/$NAME"

echo "Linked $DEST/$NAME -> $SCRIPT_DIR/codex-patched"
echo
echo "Use it directly:"
echo "  $DEST/$NAME --version"
echo
echo "Or make it your default Codex entrypoint (example for bash/zsh):"
echo "  alias codex='$DEST/$NAME'"
echo
echo "Run $SCRIPT_DIR/ensure-patched.sh after each Codex update to refresh the"
echo "patched binary (the launcher also does this automatically on next launch)."
