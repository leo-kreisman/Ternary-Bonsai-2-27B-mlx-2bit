#!/usr/bin/env python3
"""Split MLX safetensors shards into <2 GiB parts for GitHub Releases.

GitHub caps individual files at 2 GiB for both Git LFS and Release assets, and
these shards are ~5 GB each, so each is cut into equal byte-range parts. The
parts concatenate back to a byte-identical copy of the Hugging Face original.

Single streaming pass: reads each shard once, hashing the whole file and each
part as it writes them, so a 5 GB shard is never held in memory.

Also rewrites the generated hash block in an assemble.sh so the client-side
assembler can verify every part independently and self-heal bad downloads.
With --emit-assembler it writes a complete standalone assembler for a variant
(from --template), so each published quant gets its own self-contained script.

Usage:
    split_weights.py --src DIR --out DIR [--assembler PATH]
    split_weights.py --src DIR --out DIR --variant NAME --tag TAG \\
        --source-repo REPO --shards NAME=HASH [--shards ...] \\
        --parts N --emit-assembler PATH --template PATH

Exits non-zero if any source file's hash disagrees with the published
Hugging Face hash, so a corrupted local download is caught before publishing.
"""

from __future__ import annotations

import argparse
import hashlib
import math
import re
import sys
from pathlib import Path

# Defaults describe this repo's mirror; every one of these is overridable.
DEFAULT_MODEL_NAME = "Ternary-Bonsai-2-27B-mlx-2bit"
DEFAULT_SOURCE_REPO = "prism-ml/Ternary-Bonsai-2-27B-mlx-2bit"
DEFAULT_TAG = "weights-v1"

# Whole-file sha256 as published on Hugging Face, read from the LFS pointer
# etag (lfs.oid) on the API/resolve endpoint. This pack is a single-file model
# (no model.safetensors.index.json), so there is one entry.
DEFAULT_SHARDS: dict[str, str] = {
    "model.safetensors": (
        "130de5925082c168b7866b2e91b52e44abbafc99017e3ca352b77b5b55a269ed"
    ),
}

DEFAULT_PARTS = 5
CHUNK = 8 << 20  # 8 MiB

BEGIN = "# --- BEGIN GENERATED HASHES ---"
END = "# --- END GENERATED HASHES ---"


def split_shard(src: Path, out_dir: Path, parts: int) -> tuple[str, list[tuple[str, str, int]]]:
    """Split one shard; return (whole_file_hash, [(part_name, part_hash, size)])."""
    size = src.stat().st_size
    part_size = math.ceil(size / parts)

    whole = hashlib.sha256()
    results: list[tuple[str, str, int]] = []

    with src.open("rb") as fh:
        for idx in range(parts):
            part_name = f"{src.name}.part-{idx}"
            ph = hashlib.sha256()
            written = 0
            dest = out_dir / part_name
            with dest.open("wb") as out:
                remaining = min(part_size, size - idx * part_size)
                while remaining > 0:
                    chunk = fh.read(min(CHUNK, remaining))
                    if not chunk:
                        raise IOError(f"{src} ended early at part {idx}")
                    out.write(chunk)
                    ph.update(chunk)
                    whole.update(chunk)
                    written += len(chunk)
                    remaining -= len(chunk)
            results.append((part_name, ph.hexdigest(), written))

    return whole.hexdigest(), results


def render_block(
    shard_hashes: dict[str, str],
    part_hashes: dict[str, str],
) -> str:
    lines = [BEGIN]
    lines.append("# Regenerate with scripts/split_weights.py after re-splitting. Do not edit by hand.")

    lines.append("shard_expected_sha() {")
    lines.append('  case "$1" in')
    for name, digest in shard_hashes.items():
        lines.append(f'    {name}) echo "{digest}" ;;')
    lines.append('    *) echo "unknown shard: $1" >&2; return 1 ;;')
    lines.append("  esac")
    lines.append("}")
    lines.append("")

    lines.append("part_expected_sha() {")
    lines.append('  case "$1" in')
    for name, digest in part_hashes.items():
        lines.append(f'    {name}) echo "{digest}" ;;')
    lines.append('    *) echo "unknown part: $1" >&2; return 1 ;;')
    lines.append("  esac")
    lines.append("}")
    lines.append(END)
    return "\n".join(lines)


def patch_assembler(path: Path, block: str) -> None:
    text = path.read_text()
    pattern = re.compile(re.escape(BEGIN) + r".*?" + re.escape(END), re.DOTALL)
    if not pattern.search(text):
        raise SystemExit(f"markers not found in {path}")
    path.write_text(pattern.sub(lambda _: block, text, count=1))


def emit_assembler(
    template: Path,
    dest: Path,
    model_name: str,
    tag: str,
    shards: list[str],
    parts: int,
    block: str,
) -> None:
    """Write a standalone assembler for one variant from the shared template.

    Keeps the download/reassemble logic in a single place: only the shard list,
    part count, tag, title comment and hash block differ per variant.
    """
    template, dest = Path(template), Path(dest)
    text = template.read_text()

    text, n = re.subn(
        r"# Reassemble .*? weights from GitHub Release parts\.",
        f"# Reassemble {model_name} weights from GitHub Release parts.",
        text, count=1,
    )
    if n != 1:
        raise SystemExit(f"title comment not found in template {template}")

    text, n = re.subn(
        r'^TAG="\$\{TAG:-[^}]*\}"$',
        f'TAG="${{TAG:-{tag}}}"',
        text, count=1, flags=re.MULTILINE,
    )
    if n != 1:
        raise SystemExit(f"TAG line not found in template {template}")

    text, n = re.subn(
        r'^SHARDS=".*?"$',
        'SHARDS="' + " ".join(shards) + '"',
        text, count=1, flags=re.MULTILINE,
    )
    if n != 1:
        raise SystemExit(f"SHARDS line not found in template {template}")

    text, n = re.subn(
        r"^PARTS_PER_SHARD=\d+$",
        f"PARTS_PER_SHARD={parts}",
        text, count=1, flags=re.MULTILINE,
    )
    if n != 1:
        raise SystemExit(f"PARTS_PER_SHARD line not found in template {template}")

    patched = re.sub(
        re.escape(BEGIN) + r".*?" + re.escape(END),
        lambda _: block, text, count=1, flags=re.DOTALL,
    )
    if patched == text:
        raise SystemExit(f"markers not found in template {template}")

    dest.write_text(patched)
    dest.chmod(0o755)


def parse_shards(specs: list[str] | None) -> dict[str, str]:
    if not specs:
        return dict(DEFAULT_SHARDS)
    out: dict[str, str] = {}
    for spec in specs:
        name, _, digest = spec.partition("=")
        if not name or len(digest) != 64:
            raise SystemExit(f"--shards wants NAME=<64-hex sha256>, got: {spec}")
        out[name] = digest
    return out


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--src", required=True, type=Path, help="dir holding the original shards")
    ap.add_argument("--out", required=True, type=Path, help="dir to write parts into")
    ap.add_argument("--assembler", type=Path, default=None, help="assemble.sh to patch in place")
    ap.add_argument("--emit-assembler", type=Path, default=None,
                    help="write a complete standalone assembler for this variant")
    ap.add_argument("--template", type=Path, default=None,
                    help="assemble.sh to copy the logic from (with --emit-assembler)")
    ap.add_argument("--variant", default=None, help="model name for the manifest/assembler")
    ap.add_argument("--source-repo", default=None, help="Hugging Face repo the parts mirror")
    ap.add_argument("--tag", default=None, help="release tag the assembler should fetch from")
    ap.add_argument("--shards", action="append", default=None,
                    help="NAME=<sha256>; repeat per shard. Order is the reassembly order.")
    ap.add_argument("--parts", type=int, default=None, help="parts per shard")
    ap.add_argument("--verify-only", action="store_true", help="hash sources, write nothing")
    args = ap.parse_args()

    model_name = args.variant or DEFAULT_MODEL_NAME
    source_repo = args.source_repo or DEFAULT_SOURCE_REPO
    tag = args.tag or DEFAULT_TAG
    shards = parse_shards(args.shards)
    parts = args.parts or DEFAULT_PARTS

    if args.emit_assembler and not args.template:
        raise SystemExit("--emit-assembler needs --template")

    args.out.mkdir(parents=True, exist_ok=True)

    for name in shards:
        if not (args.src / name).is_file():
            print(f"missing source shard: {args.src / name}", file=sys.stderr)
            return 1

    shard_hashes: dict[str, str] = {}
    part_hashes: dict[str, str] = {}

    for name, expected in shards.items():
        src = args.src / name
        size = src.stat().st_size
        print(f"==> {name} ({size:,} bytes)")

        if args.verify_only:
            h = hashlib.sha256()
            with src.open("rb") as fh:
                for chunk in iter(lambda: fh.read(CHUNK), b""):
                    h.update(chunk)
            digest = h.hexdigest()
            ok = digest == expected
            print(f"    {'ok  ' if ok else 'FAIL'} {digest}")
            if not ok:
                print(f"    expected {expected}", file=sys.stderr)
                return 1
            continue

        digest, parts_out = split_shard(src, args.out, parts)
        if digest != expected:
            print(
                f"    FAIL source hash mismatch\n"
                f"    expected {expected}\n"
                f"    actual   {digest}\n"
                f"    Refusing to publish parts from a corrupt source.",
                file=sys.stderr,
            )
            return 1

        shard_hashes[name] = digest
        for part_name, part_digest, written in parts_out:
            if written > 2 * 1024**3:
                print(f"    FAIL {part_name} is {written} bytes, over the 2 GiB cap", file=sys.stderr)
                return 1
            part_hashes[part_name] = part_digest
            print(f"    {part_name}  {written:>13,} bytes  {part_digest[:16]}...")

    if args.verify_only:
        print(f"\nAll source shards match the published {source_repo} hashes.")
        return 0

    manifest = args.out / "MANIFEST.sha256"
    with manifest.open("w") as fh:
        fh.write(f"# {model_name} — release part checksums (sha256)\n")
        fh.write(f"# Source: huggingface.co/{source_repo}\n")
        fh.write("# Reassemble with assemble.sh; parts concatenate in part-N order.\n\n")
        for name, digest in part_hashes.items():
            fh.write(f"{digest}  {name}\n")
        fh.write("\n# Reassembled whole-file hashes (match Hugging Face)\n")
        for name, digest in shard_hashes.items():
            fh.write(f"{digest}  {name}\n")
    print(f"\n==> wrote {manifest}")

    block = render_block(shard_hashes, part_hashes)

    if args.assembler:
        patch_assembler(args.assembler, block)
        print(f"==> patched {args.assembler}")

    if args.emit_assembler:
        emit_assembler(
            args.template, args.emit_assembler, model_name, tag,
            list(shard_hashes), parts, block,
        )
        print(f"==> wrote {args.emit_assembler}")

    print(f"\n{len(part_hashes)} parts in {args.out}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
