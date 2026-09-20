#!/usr/bin/env python3
"""Set an existing GitHub Release's name and body.

Why this exists: `upload_release.sh --body-file` only uses the body when it
*creates* the release (`upload_release.sh:63-79`). For a release that is already
published -- which is every release after the first upload, and every re-run --
that flag is silently ignored, so the published body drifts from the file in
`scripts/release_bodies/` and nobody notices. This applies the file to the live
release instead.

GitHub is the only place these bodies are mirrored, and there is no `gh` here, so
this drives the REST API directly. The token comes from the configured git
credential helper and is never printed or passed on a command line.

Usage:
    scripts/patch_release.py --tag gguf-v1 --body-file scripts/release_bodies/gguf-v1.md
    scripts/patch_release.py --tag gguf-v1 --body-file ... --name "..."   # also rename
    scripts/patch_release.py --tag gguf-v1 --dry-run                      # show, change nothing
"""

from __future__ import annotations

import argparse
import json
import subprocess
import sys
import urllib.error
import urllib.request

DEFAULT_REPO = "leo-kreisman/Ternary-Bonsai-2-27B-mlx-2bit"
UA = "Ternary-Bonsai-2-27B-mlx-2bit-release-patcher"


def token() -> str:
    """Read the GitHub token from the credential helper. Never echo it."""
    proc = subprocess.run(
        ["git-credential-manager", "get"],
        input="protocol=https\nhost=github.com\n\n",
        capture_output=True,
        text=True,
    )
    for line in proc.stdout.splitlines():
        if line.startswith("password="):
            value = line[len("password="):]
            if value:
                return value
    raise SystemExit("no GitHub token from the credential helper")


def api(url: str, tok: str, method: str = "GET", payload: dict | None = None):
    body = json.dumps(payload).encode() if payload is not None else None
    req = urllib.request.Request(url, data=body, method=method)
    req.add_header("Authorization", f"Bearer {tok}")
    req.add_header("Accept", "application/vnd.github+json")
    req.add_header("X-GitHub-Api-Version", "2022-11-28")
    req.add_header("User-Agent", UA)
    if body is not None:
        req.add_header("Content-Type", "application/json")
    with urllib.request.urlopen(req) as resp:
        return json.load(resp)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--repo", default=DEFAULT_REPO)
    ap.add_argument("--tag", required=True)
    ap.add_argument("--body-file", required=True)
    ap.add_argument("--name", default=None,
                    help="also set the release title (optional)")
    ap.add_argument("--dry-run", action="store_true")
    args = ap.parse_args()

    try:
        with open(args.body_file) as fh:
            body = fh.read()
    except OSError as exc:
        raise SystemExit(f"cannot read {args.body_file}: {exc}")

    if not body.strip():
        raise SystemExit(f"{args.body_file} is empty; refusing to blank the release body")

    base = f"https://api.github.com/repos/{args.repo}"
    tok = token()

    try:
        rel = api(f"{base}/releases/tags/{args.tag}", tok)
    except urllib.error.HTTPError as exc:
        if exc.code == 404:
            raise SystemExit(f"no release tagged {args.tag} in {args.repo}")
        raise

    current = rel.get("body") or ""
    print(f"release {args.tag}  id={rel['id']}")
    print(f"  name: {rel.get('name')!r}")
    print(f"  body: {len(current):,} chars currently, "
          f"{len(body):,} chars in {args.body_file}")
    if args.name is not None:
        print(f"  name -> {args.name!r}")

    if current == body and (args.name is None or args.name == rel.get("name")):
        print("  already up to date; nothing to do")
        return 0

    if args.dry_run:
        print("  [dry-run] would PATCH the release above")
        return 0

    payload: dict = {"body": body}
    if args.name is not None:
        payload["name"] = args.name

    try:
        updated = api(f"{base}/releases/{rel['id']}", tok, "PATCH", payload)
    except urllib.error.HTTPError as exc:
        detail = exc.read().decode(errors="replace")[:400]
        raise SystemExit(f"PATCH failed: HTTP {exc.code}\n{detail}")

    print(f"  PATCHed: body now {len(updated.get('body') or ''):,} chars, "
          f"name {updated.get('name')!r}")
    print(f"  {updated['html_url']}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
