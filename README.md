# codex-plaintext-collab

A small patch (and build/update tooling) that stops **OpenAI Codex CLI** from
encrypting inter-agent messages, so `spawn_agent`, `send_message`, and
`followup_task` payloads are stored and forwarded as plaintext.

- Patch: [`patches/0001-disable-collab-message-encryption.patch`](patches/0001-disable-collab-message-encryption.patch)
- Target: `openai/codex` (verified against `rust-v0.154.0`, works similarly on `rust-v0.153.4`)
- License: MIT

> This does **not** decrypt anything. The ciphertext Codex already wrote is
> encrypted with a server-side key and cannot be recovered locally. This only
> makes **new** collaboration messages plaintext.

## Background: why Codex messages are encrypted

For multi-agent v2, Codex declares the collaboration `message` parameter as an
encrypted tool parameter in the Responses API tool schema:

- `codex-rs/core/src/tools/handlers/multi_agents_spec.rs`
  - `create_send_message_tool()` — `message` -> `.with_encrypted()`
  - `create_followup_task_tool()` — `message` -> `.with_encrypted()`
  - `spawn_agent_common_properties_v2()` — `message` -> `.with_encrypted()`
- The marker itself is defined in `codex-rs/tools/src/json_schema/types.rs`
  (`JsonSchema::with_encrypted`, serialized as `"encrypted": true`).

When the OpenAI backend sees `"encrypted": true`, it returns the model's tool
call with the `message` value replaced by an opaque Fernet-style token
(`gAAAAA...`). Codex never sees the plaintext; it only stores and forwards the
token (`codex-rs/core/src/tools/handlers/multi_agents_v2.rs`,
`InterAgentCommunication::new_encrypted` in `codex-rs/protocol/src/protocol.rs`).

Notes:

- The v1 collaboration tools and non-OpenAI providers do not mark the parameter
  encrypted, so their subagent messages are already plaintext.
- Because the marker is added client-side, it can be removed client-side.

## What the patch changes

1. Removes the three `.with_encrypted()` calls above, so Codex no longer asks the
   backend to encrypt the collaboration `message` parameter.
2. Relaxes `ToolCall::direct_source()` in `codex-rs/core/src/tools/router.rs` so
   collaboration calls whose `encrypted_function_args` are empty **or absent**
   are treated as `DirectPlaintextMessage`. This makes Codex render/store the
   message as plaintext instead of wrapping it as `encrypted_content`.

The result: `spawn_agent`/`send_message`/`followup_task` arguments and the
recipient agent's `agent_message` contain readable text.

## Requirements

- A Rust toolchain (`rustc`/`cargo`), `git`, and a C toolchain as needed by Codex
- Network access to clone `github.com/openai/codex` and fetch crates
- A Codex installation that uses the **managed/standalone** layout
  (`$CODEX_HOME/packages/standalone/...`), which is how the CLI installs its
  native binary

## Build

```bash
# Build the patched binary for the upstream version you have installed.
scripts/build-patched-codex.sh --version 0.154.0
```

The binary is cached at
`${CODEX_PLAINTEXT_CACHE:-${XDG_CACHE_HOME:-$HOME/.cache}/codex-plaintext-collab}/bin/codex-<version>`.

Build notes:

- Requires `git`, `cargo`/`rustc` (the repo's pinned toolchain is installed by
  rustup if needed), `python3`, and a C toolchain.
- If the system has no OpenSSL development files, the script automatically
  enables the vendored OpenSSL build (needs `cc`, `make`, and `perl`).
- If the pinned `--locked` build fails due to `Cargo.lock` drift, it retries
  without `--locked`; pass `--no-locked` to skip the pinned attempt.
- The release binary is stripped after building to match upstream packaging
  (upstream ships unstripped release artifacts).

## Install and survive updates

Codex replaces its native binary when it updates, which would discard a
one-off patch. The tooling below detects and repairs that automatically.

```bash
# Patch the managed install for the active CODEX_HOME (idempotent; builds if needed).
scripts/ensure-patched.sh --codex-home "$HOME/.codex"

# Verify only (read-only, hash based). Exit 0 = patched, 1 = not patched, 3 = no install.
scripts/verify-patched.sh --codex-home "$HOME/.codex"

# Update-aware launcher: verifies/repairs, then execs Codex.
scripts/install.sh          # links ~/.local/bin/codex-plaintext -> scripts/codex-patched
codex-plaintext --version
```

### Verification is hash based

`ensure-patched.sh` records `version:patch_sha256:binary_sha256` next to the
release. `verify-patched.sh` fails if the version changed (an update landed), if
the patch file changed, or if `bin/codex` is no longer the exact patched build.

### On-update trigger (Codex SessionStart hook)

Register a hook that verifies on every session start and reinstalls instantly
from the local build cache when an update was applied:

```bash
scripts/install-hook.sh --codex-home "$HOME/.codex"
# optional: allow a detached background rebuild when no cached build exists yet
scripts/install-hook.sh --codex-home "$HOME/.codex" --auto-build
```

The hook never blocks or fails a session. If a patched build for the new version
is not cached yet, it prints one actionable line (or starts a background build
with `--auto-build`). Note that Codex may ask you to trust a newly added hook;
the installer prints the expected `hooks.state` key. Remove it with
`scripts/remove-hook.sh`.

If you launch Codex through `codex-patched`, the hook is optional: the launcher
already verifies and repairs before every run. The hook is what catches updates
when you invoke Codex through another entrypoint.

### Uninstall

```bash
# Restore the original binary, drop the marker, remove the hook.
scripts/uninstall.sh --codex-home "$HOME/.codex"

# Also clean every release and remove the wrapper/cache:
scripts/uninstall.sh --codex-home "$HOME/.codex" --all --remove-wrapper --purge-cache
```

### Tests

```bash
tests/run.sh
```

Runs the tooling against a fake managed install and fake build cache.

## Future Codex versions

The tooling is built to keep working across upstream releases, with a
fail-closed boundary around the one thing that can genuinely change.

Version-agnostic by design:

- The active version and binary path are read from the release manifest
  (`codex-package.json`, including its `entrypoint`), not hardcoded.
- Patched builds are cached and keyed by upstream version, so a new version
  builds once and reinstalls instantly thereafter.
- The marker is keyed by the patch hash, so any change to the patch forces a
  rebuild/reinstall rather than silently reusing a stale binary.
- The update hook verifies on every session and repairs from cache.

Source patch application (`scripts/apply-patch.py`):

- Applies the change **semantically** — removes `.with_encrypted()` calls from
  the collaboration tool spec and rewrites the `direct_source()` encrypted-args
  condition — so line-number and formatting drift across versions do not matter.
- Falls back to the bundled unified diff (`git apply`, then `--3way`) if the
  semantic transform does not fully apply.
- Verifies the result and exits non-zero if the collaboration code was
  refactored in a way it does not recognize, with a message telling you to
  update the patch.

The remaining assumptions, which would require a patch update if they ever
change:

- Release tags are named `rust-vX.Y.Z`.
- The collaboration `message` parameters are still what triggers encryption, and
  the `DirectPlaintextMessage` distinction still exists.
- `bin/codex` (or the manifest `entrypoint`) is the binary to replace.

In short: the install/update/verify/uninstall plumbing is dynamic; the code
patch auto-adapts to drift but is expected to be re-validated (and occasionally
tweaked) when upstream reworks multi-agent collaboration.

## Limitations

- Existing `gAAAAA...` messages remain encrypted; the key is server-side.
- The patch must be maintained across upstream releases: if OpenAI renames the
  tool-schema marker or changes the collaboration transport, update the patch.
- The binary is rebuilt from source and is not an official, signed OpenAI build.
- If the vendor later encrypts the parameter server-side regardless of the
  schema marker, this client-side patch will not help.

## License

MIT — see [LICENSE](LICENSE).
