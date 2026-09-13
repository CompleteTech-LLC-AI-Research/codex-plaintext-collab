# Reproduction and maintenance prompt

A self-contained prompt for a fresh coding agent to reproduce this project, plus
the short prompt used to maintain it for a new upstream Codex release.

## Build prompt

```text
Build and publish `codex-plaintext-collab` under the GitHub org
`CompleteTech-LLC-AI-Research` (public, MIT).

GOAL
Stop OpenAI Codex CLI from encrypting inter-agent (subagent) messages, and keep
that patch applied across Codex updates — without ever attempting to decrypt
existing ciphertext.

BACKGROUND (already verified; do not re-litigate)
- Codex's multi-agent v2 marks the collaboration `message` tool parameter as an
  encrypted parameter. The marker is `JsonSchema::with_encrypted()` in
  `codex-rs/core/src/tools/handlers/multi_agents_spec.rs`:
    - `create_send_message_tool()` -> `message`
    - `create_followup_task_tool()` -> `message`
    - `spawn_agent_common_properties_v2()` -> `message`
  It serializes as `"encrypted": true`; the OpenAI backend then returns the
  model's tool call with the message replaced by a Fernet-style `gAAAAA...`
  token. Codex stores/forwards it opaquely via
  `InterAgentCommunication::new_encrypted` (`codex-rs/protocol/src/protocol.rs`).
- `codex-rs/core/src/tools/router.rs`, `ToolCall::direct_source()`, only treats
  collaboration calls as `DirectPlaintextMessage` when
  `encrypted_function_args == Some([])`.
- The ciphertext key is server-side. Never try to decrypt; only affect new
  messages.

DELIVERABLES (repo layout)
- README.md, LICENSE (MIT, CompleteTech LLC), .gitignore
- patches/0001-disable-collab-message-encryption.patch
- scripts/lib.sh                      # release/version/entrypoint resolution, hashing
- scripts/apply-patch.py              # semantic patcher + diff fallback + fail-closed verify
- scripts/build-patched-codex.sh      # fetch tag, patch, cargo build, cache per version
- scripts/verify-patched.sh           # read-only, hash-based verification
- scripts/ensure-patched.sh           # idempotent install/repair
- scripts/hook-verify.sh              # SessionStart hook body
- scripts/install-hook.sh             # register hook in $CODEX_HOME/hooks.json
- scripts/remove-hook.sh              # remove hook
- scripts/codex-patched               # update-aware launcher
- scripts/install.sh                  # symlink launcher into ~/.local/bin
- scripts/uninstall.sh                # restore original, remove hook, purge cache
- tests/run.sh                        # no real CODEX_HOME touched

REQUIREMENTS
1. Source change (two edits):
   - Remove the three `.with_encrypted()` calls above.
   - In `direct_source()`, treat collaboration calls with empty OR absent
     `encrypted_function_args` as `DirectPlaintextMessage` (e.g. replace
     `.is_some_and(Vec::is_empty)` with `.map_or(true, |args| args.is_empty())`).
2. Patch application must be future-proof:
   - Apply semantically (regex/keyword based), fall back to the bundled diff
     with `git apply` then `git apply --3way`.
   - Verify afterwards and exit non-zero with an actionable message if upstream
     reworked the collaboration code. Fail closed; never ship an unpatched build.
3. Detection is data-driven, not hardcoded:
   - Read version and `entrypoint` from `packages/standalone/<...>/codex-package.json`.
   - Cache builds per version; key the marker on `version:patch_sha256:binary_sha256`.
   - `verify-patched.sh` exits 0 patched, 1 not patched, 3 no managed install.
   - `ensure-patched.sh` backs up `bin/codex.orig` once and swaps atomically
     (temp file + `mv`), with `--check`, `--no-build`, `--quiet`, `--force`.
4. Update trigger:
   - `install-hook.sh` adds a SessionStart hook running `hook-verify.sh`;
     preserve existing hooks; be idempotent; print the resulting `hooks.state`
     trust key; back up hooks.json.
   - `hook-verify.sh` never blocks/fails a session: verify, fast-reinstall from
     cache, else print one actionable line; `--auto-build` opts into a detached
     rebuild.
5. Uninstall: restore `bin/codex.orig`, delete the marker, remove the hook;
   `--all`, `--purge-cache`, `--remove-wrapper`.
6. Build robustness: if system OpenSSL development files are missing, enable the
   vendored OpenSSL build; retry without `--locked` when the lockfile drifts;
   strip the release binary to match upstream packaging.
7. Tests: `tests/run.sh` must cover baseline, ensure/idempotency, update
   detection, no-build failure, hook install/remove/body, uninstall, and the
   semantic patcher (including a "refactor fails closed" case). All green.

ACCEPTANCE
- `git apply --check` of the patch succeeds on the current upstream `rust-v*` tag.
- `tests/run.sh` passes.
- `scripts/build-patched-codex.sh --help`, `verify-patched.sh --help`,
  `uninstall.sh --help` work.
- README has a "Future Codex versions" section documenting what is dynamic and
  what needs manual re-validation.

STEPS
1. Create the repo locally, implement all files, make scripts executable.
2. Run tests and the help/syntax checks; fix until green.
3. `git init -b main`, commit with a clear message.
4. `gh repo create CompleteTech-LLC-AI-Research/codex-plaintext-collab --public --source=. --remote=origin --push`.
5. Confirm via `gh api` that it is public and the files landed.

CONSTRAINTS
- Do not attempt to decrypt existing messages.
- Do not expose secrets/tokens.
- Prefer POSIX-ish bash; require only git, cargo/rustc, python3, sha256sum.
```

## Maintenance prompt

```text
Update CompleteTech-LLC-AI-Research/codex-plaintext-collab for Codex rust-v<X.Y.Z>.
Fetch a clean checkout of the new tag, run scripts/apply-patch.py against it,
adapt the semantic transform if it fails closed, keep the marker's version field
current, run tests/run.sh, and push. Do not weaken fail-closed verification.
```
