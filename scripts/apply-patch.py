#!/usr/bin/env python3
"""Apply the plaintext-collab changes to a Codex source checkout.

Two strategies are used, in order:

1. Semantic transform: remove ``.with_encrypted()`` calls from the collaboration
   tool spec and treat empty/absent ``encrypted_function_args`` as plaintext in
   the tool router, and update the tool-schema unit tests that assert the
   encrypted marker. This survives line-number and formatting drift.
2. Bundled unified diff (``patches/0001-...patch``) via ``git apply``.

The result is verified afterwards; the script exits non-zero when the checkout
does not end up in the expected state, so a future upstream refactor fails the
build loudly instead of silently shipping an unpatched binary.
"""

from __future__ import annotations

import argparse
import pathlib
import re
import subprocess
import sys

SPEC_REL = "codex-rs/core/src/tools/handlers/multi_agents_spec.rs"
TESTS_REL = "codex-rs/core/src/tools/handlers/multi_agents_spec_tests.rs"
ROUTER_REL = "codex-rs/core/src/tools/router.rs"

ENCRYPTED_CALL_RE = re.compile(r"[ \t]*\n[ \t]*\.with_encrypted\(\)")
ROUTER_ENCRYPTED_RE = ".is_some_and(Vec::is_empty)"
ROUTER_PLAINTEXT = ".map_or(true, |args| args.is_empty())"
# The tool-schema unit tests assert the encrypted marker on the collaboration
# `message` parameter. Removing the marker makes those assertions stale, so the
# transform carries them along; otherwise the patched tree fails `cargo test`.
TESTS_ENCRYPTED_ASSERTION_RE = re.compile(
    r"(\.and_then\(\|schema\| schema\.encrypted\),\n)([ \t]*)Some\(true\)"
)
# Verification is deliberately looser than the rewrite: any assertion that still
# expects an encrypted value next to `schema.encrypted` means the checkout is
# not in the expected state, even if upstream reshaped the assertion.
TESTS_STALE_ASSERTION_RE = re.compile(r"schema\.encrypted[\s\S]{0,40}?Some\(true\)")
TESTS_PLAINTEXT_NOTE = "collaboration messages must not advertise an encrypted parameter"


def _plaintext_assertion(match: re.Match[str]) -> str:
    indent = match.group(2)
    return f'{match.group(1)}{indent}None,\n{indent}"{TESTS_PLAINTEXT_NOTE}"'


def semantic_transform(root: pathlib.Path) -> bool:
    changed = False

    spec = root / SPEC_REL
    if spec.is_file():
        text = spec.read_text(encoding="utf-8")
        updated = ENCRYPTED_CALL_RE.sub("", text)
        if updated != text:
            spec.write_text(updated, encoding="utf-8")
            changed = True

    router = root / ROUTER_REL
    if router.is_file():
        text = router.read_text(encoding="utf-8")
        updated = text.replace(ROUTER_ENCRYPTED_RE, ROUTER_PLAINTEXT)
        if updated != text:
            router.write_text(updated, encoding="utf-8")
            changed = True

    tests = root / TESTS_REL
    if tests.is_file():
        text = tests.read_text(encoding="utf-8")
        updated, replaced = TESTS_ENCRYPTED_ASSERTION_RE.subn(
            _plaintext_assertion, text
        )
        if replaced:
            tests.write_text(updated, encoding="utf-8")
            changed = True

    return changed


def verify(root: pathlib.Path) -> list[str]:
    problems: list[str] = []

    spec = root / SPEC_REL
    if not spec.is_file():
        problems.append(f"missing {SPEC_REL}")
    elif ".with_encrypted()" in spec.read_text(encoding="utf-8"):
        problems.append(f"{SPEC_REL}: with_encrypted markers remain")

    router = root / ROUTER_REL
    if not router.is_file():
        problems.append(f"missing {ROUTER_REL}")
    else:
        text = router.read_text(encoding="utf-8")
        if ROUTER_PLAINTEXT not in text:
            if ROUTER_ENCRYPTED_RE in text:
                problems.append(f"{ROUTER_REL}: encrypted-args classification unchanged")
            else:
                problems.append(
                    f"{ROUTER_REL}: plaintext classification missing "
                    "(upstream direct_source may have changed)"
                )

    tests = root / TESTS_REL
    if not tests.is_file():
        problems.append(f"missing {TESTS_REL}")
    elif TESTS_STALE_ASSERTION_RE.search(tests.read_text(encoding="utf-8")):
        problems.append(
            f"{TESTS_REL}: tool-schema tests still assert an encrypted "
            "collaboration message"
        )

    return problems


def try_git_apply(root: pathlib.Path, patch: pathlib.Path) -> None:
    for args in (["apply", str(patch)], ["apply", "--3way", str(patch)]):
        result = subprocess.run(
            ["git", "-C", str(root), *args],
            capture_output=True, text=True,
        )
        if result.returncode == 0:
            return
    # Report the last error for diagnosis.
    raise SystemExit(f"error: git apply failed:\n{result.stderr.strip()}")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source", help="path to a Codex source checkout")
    parser.add_argument(
        "--patch",
        default=str(pathlib.Path(__file__).resolve().parent.parent
                    / "patches" / "0001-disable-collab-message-encryption.patch"),
        help="fallback unified diff to apply",
    )
    parser.add_argument(
        "--require-changes",
        action="store_true",
        help="fail if the checkout was already patched (used to assert a fresh apply)",
    )
    args = parser.parse_args()

    root = pathlib.Path(args.source).resolve()
    if not root.is_dir():
        raise SystemExit(f"error: source directory not found: {root}")

    already = not verify(root)
    if already:
        if args.require_changes:
            raise SystemExit("error: source checkout is already patched")
        print("source is already patched")
        return 0

    semantic_transform(root)
    problems = verify(root)

    if problems:
        print("semantic transform incomplete; falling back to bundled diff", file=sys.stderr)
        try_git_apply(root, pathlib.Path(args.patch))
        problems = verify(root)

    if problems:
        for problem in problems:
            print(f"error: {problem}", file=sys.stderr)
        print(
            "error: the upstream collaboration code changed; update the patch.",
            file=sys.stderr,
        )
        return 1

    print("applied plaintext-collab patch")
    return 0


if __name__ == "__main__":
    sys.exit(main())
