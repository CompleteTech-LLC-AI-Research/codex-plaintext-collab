#!/usr/bin/env bash
#
# Tooling tests for codex-plaintext-collab. Uses a fake managed Codex install
# and a fake cached patched binary; never builds or touches a real CODEX_HOME.
#
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPTS="$REPO_ROOT/scripts"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/codex-plaintext-test.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

PASS=0
FAIL=0

ok()   { PASS=$((PASS + 1)); printf '  ok  %s\n' "$1"; }
bad()  { FAIL=$((FAIL + 1)); printf ' FAIL %s\n' "$1"; }
check() { # check <desc> <expected-exit> <cmd...>
  local desc="$1" expected="$2"; shift 2
  local actual=0
  "$@" >/dev/null 2>&1 || actual=$?
  if [[ "$actual" -eq "$expected" ]]; then ok "$desc"; else bad "$desc (exit $actual, want $expected)"; fi
}

make_release() { # make_release <home> <version> <bin-text>
  local home="$1" version="$2" text="$3"
  local rel="$home/packages/standalone/releases/$version-x86_64-unknown-linux-musl"
  mkdir -p "$rel/bin"
  printf '#!/bin/sh\necho %s\n' "$text" > "$rel/bin/codex"
  chmod +x "$rel/bin/codex"
  printf '{"layoutVersion":1,"version":"%s","target":"x86_64-unknown-linux-musl","variant":"codex","entrypoint":"bin/codex"}\n' "$version" > "$rel/codex-package.json"
  printf '%s' "$rel"
}

HOME_DIR="$WORK/home"
CACHE="$WORK/cache"
mkdir -p "$HOME_DIR/packages/standalone/releases" "$CACHE/bin"

V1=1.2.3
V2=1.2.4
REL1="$(make_release "$HOME_DIR" "$V1" official-1)"
ln -sfn "$REL1" "$HOME_DIR/packages/standalone/current"

# Cached patched builds (distinct content => distinct hash).
printf '#!/bin/sh\necho patched-1\n' > "$CACHE/bin/codex-$V1"
printf '#!/bin/sh\necho patched-2\n' > "$CACHE/bin/codex-$V2"
chmod +x "$CACHE/bin/codex-$V1" "$CACHE/bin/codex-$V2"

export CODEX_PLAINTEXT_CACHE="$CACHE"

echo "== baseline =="
check "verify fails before patch" 1 "$SCRIPTS/verify-patched.sh" --quiet --codex-home "$HOME_DIR"

echo "== ensure =="
check "ensure installs patched binary" 0 "$SCRIPTS/ensure-patched.sh" --quiet --codex-home "$HOME_DIR"
check "verify passes after patch" 0 "$SCRIPTS/verify-patched.sh" --quiet --codex-home "$HOME_DIR"
check "ensure --check passes" 0 "$SCRIPTS/ensure-patched.sh" --check --quiet --codex-home "$HOME_DIR"
check "ensure is idempotent" 0 "$SCRIPTS/ensure-patched.sh" --quiet --codex-home "$HOME_DIR"
check "original backed up" 0 test -f "$REL1/bin/codex.orig"
if grep -q patched-1 <("$REL1/bin/codex" 2>/dev/null); then ok "patched binary is active"; else bad "patched binary is active"; fi

echo "== update detection =="
REL2="$(make_release "$HOME_DIR" "$V2" official-2)"
ln -sfn "$REL2" "$HOME_DIR/packages/standalone/current"
check "verify fails after update" 1 "$SCRIPTS/verify-patched.sh" --quiet --codex-home "$HOME_DIR"
check "no-build fails when cache missing" 1 env CODEX_PLAINTEXT_CACHE="$WORK/empty" \
  "$SCRIPTS/ensure-patched.sh" --quiet --no-build --codex-home "$HOME_DIR"
check "ensure re-patches new version" 0 "$SCRIPTS/ensure-patched.sh" --quiet --codex-home "$HOME_DIR"
check "verify passes on new version" 0 "$SCRIPTS/verify-patched.sh" --quiet --codex-home "$HOME_DIR"

echo "== hooks =="
check "install hook" 0 "$SCRIPTS/install-hook.sh" --quiet --codex-home "$HOME_DIR"
check "install hook idempotent" 0 "$SCRIPTS/install-hook.sh" --quiet --codex-home "$HOME_DIR"
hook_groups="$(python3 -c 'import json,sys;print(len(json.load(open(sys.argv[1])).get("hooks",{}).get("SessionStart",[])))' "$HOME_DIR/hooks.json")"
if [[ "$hook_groups" == "1" ]]; then ok "exactly one managed hook group"; else bad "hook group count=$hook_groups"; fi
check "remove hook" 0 "$SCRIPTS/remove-hook.sh" --quiet --codex-home "$HOME_DIR"
hook_groups="$(python3 -c 'import json,sys;print(len(json.load(open(sys.argv[1])).get("hooks",{}).get("SessionStart",[])))' "$HOME_DIR/hooks.json")"
if [[ "$hook_groups" == "0" ]]; then ok "hook group removed"; else bad "hook group count after remove=$hook_groups"; fi

echo "== uninstall =="
check "uninstall restores original" 0 "$SCRIPTS/uninstall.sh" --quiet --codex-home "$HOME_DIR"
if grep -q official-2 <("$REL2/bin/codex" 2>/dev/null); then ok "original binary restored"; else bad "original binary restored"; fi
check "verify fails after uninstall" 1 "$SCRIPTS/verify-patched.sh" --quiet --codex-home "$HOME_DIR"

echo "== hook body =="
check "hook repairs from cache, exits 0" 0 bash -c "CODEX_PLAINTEXT_CACHE='$CACHE' '$SCRIPTS/hook-verify.sh' --codex-home '$HOME_DIR' </dev/null"
check "verify passes after hook repair" 0 "$SCRIPTS/verify-patched.sh" --quiet --codex-home "$HOME_DIR"
check "hook without cache still exits 0" 0 bash -c "CODEX_PLAINTEXT_CACHE='$WORK/empty' '$SCRIPTS/hook-verify.sh' --codex-home '$HOME_DIR' </dev/null"

echo "== semantic patcher =="
SRC="$WORK/src"
mkdir -p "$SRC/codex-rs/core/src/tools/handlers"
cat > "$SRC/codex-rs/core/src/tools/handlers/multi_agents_spec.rs" <<'RS'
fn make() {
    let properties = BTreeMap::from([
        (
            "message".to_string(),
            JsonSchema::string(Some(
                "Message text to queue on the target agent.".to_string(),
            ))
            .with_encrypted(),
        ),
    ]);
}
RS
cat > "$SRC/codex-rs/core/src/tools/router.rs" <<'RS'
impl ToolCall {
    pub(crate) fn direct_source(&self) -> ToolCallSource {
        if self.tool_name.namespace.as_deref() == Some("collaboration")
            && self
                .encrypted_function_args
                .as_ref()
                .is_some_and(Vec::is_empty)
        {
            ToolCallSource::DirectPlaintextMessage
        } else {
            ToolCallSource::Direct
        }
    }
}
RS
check "semantic apply succeeds" 0 python3 "$SCRIPTS/apply-patch.py" "$SRC"
check "semantic apply idempotent" 0 python3 "$SCRIPTS/apply-patch.py" "$SRC"
check "with_encrypted removed" 1 grep -q 'with_encrypted' "$SRC/codex-rs/core/src/tools/handlers/multi_agents_spec.rs"
check "router plaintext classification added" 0 grep -q 'map_or(true, |args| args.is_empty())' "$SRC/codex-rs/core/src/tools/router.rs"

REFACTOR="$WORK/refactor"
mkdir -p "$REFACTOR/codex-rs/core/src/tools/handlers"
printf 'fn make() {\n    let x = JsonSchema::string(Some(\n        "m".to_string(),\n    ))\n    .with_encrypted();\n}\n' \
  > "$REFACTOR/codex-rs/core/src/tools/handlers/multi_agents_spec.rs"
printf 'fn direct_source() {\n    let _ = self.encrypted_function_args.rewritten_api();\n}\n' \
  > "$REFACTOR/codex-rs/core/src/tools/router.rs"
check "semantic patcher fails closed on refactor" 1 python3 "$SCRIPTS/apply-patch.py" "$REFACTOR"

echo
echo "passed: $PASS, failed: $FAIL"
[[ "$FAIL" -eq 0 ]]
