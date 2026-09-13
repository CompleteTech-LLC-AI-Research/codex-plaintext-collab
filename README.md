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

## Install and survive updates

Codex replaces its native binary when it updates, which would discard a
one-off patch. Two scripts handle that:

```bash
# Patch the managed install for the active CODEX_HOME (idempotent).
scripts/ensure-patched.sh --codex-home "$HOME/.codex"

# Update-aware launcher: re-applies the patch if an update replaced the binary,
# then execs Codex.
scripts/install.sh          # links ~/.local/bin/codex-plaintext -> scripts/codex-patched
codex-plaintext --version
```

Recommended setup:

1. Point your Codex entrypoint at `codex-patched` (alias or PATH), **or** run
   `ensure-patched.sh` from a shell hook/after-update step.
2. `ensure-patched.sh` detects the active version, rebuilds the patched binary
   for that version if it is not cached, backs up the original once as
   `bin/codex.orig`, and atomically swaps in the patched binary.
3. After a Codex update, the next launch rebuilds/reinstalls for the new version
   so normal `codex update` flows keep working.

For fully hands-off updates, wire `ensure-patched.sh` into a shell `PROMPT_COMMAND`
or a small timer that runs it before launching Codex.

## Limitations

- Existing `gAAAAA...` messages remain encrypted; the key is server-side.
- The patch must be maintained across upstream releases: if OpenAI renames the
  tool-schema marker or changes the collaboration transport, update the patch.
- The binary is rebuilt from source and is not an official, signed OpenAI build.
- If the vendor later encrypts the parameter server-side regardless of the
  schema marker, this client-side patch will not help.

## License

MIT — see [LICENSE](LICENSE).
