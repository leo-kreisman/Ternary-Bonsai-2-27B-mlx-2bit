#!/usr/bin/env python3
"""Split the Bonsai 2 GGUF bands into <2 GiB Release parts and hash-pin the assembler.

GitHub caps a single file at 2 GiB for Release assets, so both main bands are cut
into equal byte-range parts: PTQ1_0 (5,946,648,928 bytes, 5.54 GiB) into three,
and PQ2_0 (7,206,168,928 bytes, 6.71 GiB) into four. Both vision projectors ship
whole -- mmproj-Q8_0 at 629,246,976 bytes and mmproj-BF16 at 931,145,856 bytes.
Concatenating the parts reproduces the Hugging Face original byte for byte.

There is deliberately no 4-bit, 6-bit or 8-bit band here, and there is nothing to
add: these weights are natively ternary (~1.58 bpw), so a Q4_K_M/Q6_K/Q8_0 of
them would store ternary values in larger containers -- roughly three times the
bytes for the same information. No such build is published upstream, by prism-ml
or by anyone else.

Single streaming pass: each source is read once while its whole-file hash and
every part's hash are computed, so a 5.5 GB file is never held in memory.

Exits non-zero if a source file disagrees with the hash published on Hugging
Face, so a corrupt local download is caught before it is split, uploaded, and
published as if it were good.

The generated block in assemble-gguf.sh is the only place these hashes live on
the client side. Regenerate with this script after re-splitting; never edit it
by hand.

Usage:
    scripts/split_gguf.py --src DIR --out DIR [--assembler PATH] [--verify-only]
"""

from __future__ import annotations

import argparse
import hashlib
import math
import os
import re
import shutil
import sys
from pathlib import Path

# Defaults describe this repo's GGUF mirror; all are overridable.
DEFAULT_VARIANT = "Ternary-Bonsai-2-27B-gguf"
DEFAULT_SOURCE_REPO = "prism-ml/Ternary-Bonsai-2-27B-gguf"
DEFAULT_SOURCE_REV = "6ed5e12bf84b7a63069882c91dd9e9218647d17b"
DEFAULT_TAG = "gguf-v1"

# (file name, whole-file sha256 as published on Hugging Face, part count,
#  destination subdirectory under DEST -- "" for the model directory itself).
#
# The sha256 is the LFS oid from
#   /api/models/<repo>/tree/<rev>?recursive=true   ->  entry.lfs.oid
# which is the file's own content hash. Do NOT take it from the resolve
# endpoint's ETag: for this repo that header is a CDN cache tag, not the
# content hash, and pinning it here rejects every correct download (it did,
# for both files, before this was corrected).
# Order is the order the assembler lists them in.
#
# Why mmproj-BF16 gets a subdirectory: start_llama_server.sh picks the projector
# with `for _mp in $GGUF_MODEL_DIR/*mmproj*.gguf; do ...; break; done`
# (:72-74), i.e. the FIRST glob match wins. Sorted, "mmproj-BF16" sorts before
# "mmproj-Q8_0", so dropping BF16 beside the model would silently switch every
# run from the tested Q8_0 projector to the untested BF16 one -- and the
# smoke-test probe is text-only, so it would not catch it. Keeping BF16 one
# directory over leaves the tested path exactly as it was while still shipping
# the bytes; point BONSAI_MMPROJ at it to use it.
DEFAULT_SHARDS: list[tuple[str, str, int, str]] = [
    (
        "Ternary-Bonsai-2-27B-PTQ1_0.gguf",
        "53107f530aa52eb00912263ab1ee29bd199261c87cd7b4ad4ca1318c1fe33ee3",
        3,
        "",
    ),
    (
        "Ternary-Bonsai-2-27B-PQ2_0.gguf",
        "3907dc1658db1f78a9826bf8d5bcb8dc65db0d466388937af57f2294fae62ec1",
        4,
        "",
    ),
    (
        "Ternary-Bonsai-2-27B-mmproj-Q8_0.gguf",
        "6807ede61d570bb86ba34b756a0fa109edc33668604de867c6ea6d8f1d631903",
        1,
        "",
    ),
    (
        "Ternary-Bonsai-2-27B-mmproj-BF16.gguf",
        "e287342d92332fa3577ed1d42e921dac9370c08da58ba9337fa450f6cc76cfd7",
        1,
        "27B-projectors",
    ),
]

GIB = 2 * 1024**3
CHUNK = 8 << 20  # 8 MiB

BEGIN = "# --- BEGIN GENERATED HASHES ---"
END = "# --- END GENERATED HASHES ---"


def split_shard(src: Path, out_dir: Path, parts: int) -> tuple[str, list[tuple[str, str, int]]]:
    """Split one shard; return (whole_file_hash, [(asset_name, part_hash, size)]).

    With parts == 1 the source is published whole, so the asset is the file
    itself. It is linked (or copied) into out_dir under its own name so the
    uploader sees one uniform directory.
    """
    size = src.stat().st_size
    whole = hashlib.sha256()

    if parts == 1:
        dest = out_dir / src.name
        if dest.exists():
            dest.unlink()
        try:
            os.link(src, dest)  # same filesystem: no extra 600 MB
        except OSError:
            shutil.copyfile(src, dest)
        with src.open("rb") as fh:
            for chunk in iter(lambda: fh.read(CHUNK), b""):
                whole.update(chunk)
        return whole.hexdigest(), [(src.name, whole.hexdigest(), size)]

    part_size = math.ceil(size / parts)
    results: list[tuple[str, str, int]] = []

    with src.open("rb") as fh:
        for idx in range(parts):
            name = f"{src.name}.part-{idx}"
            ph = hashlib.sha256()
            written = 0
            with (out_dir / name).open("wb") as out:
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
            results.append((name, ph.hexdigest(), written))

    return whole.hexdigest(), results


def render_block(
    shards: list[tuple[str, int, str]],
    shard_hashes: dict[str, str],
    part_hashes: dict[str, str],
) -> str:
    lines = [BEGIN]
    lines.append("# Regenerate with scripts/split_gguf.py after re-splitting. Do not edit by hand.")
    lines.append("")
    lines.append("shard_parts() {")
    lines.append('  case "$1" in')
    for name, parts, _sub in shards:
        lines.append(f'    {name}) echo "{parts}" ;;')
    lines.append('    *) echo "unknown shard: $1" >&2; return 1 ;;')
    lines.append("  esac")
    lines.append("}")
    lines.append("")
    lines.append("# Subdirectory under DEST this shard lands in; empty means DEST itself.")
    lines.append("# Non-empty is used to keep a file out of start_llama_server.sh's")
    lines.append("# `*mmproj*.gguf` glob, which takes the first match and would otherwise")
    lines.append("# silently change which projector loads. See split_gguf.py.")
    lines.append("shard_dest_subdir() {")
    lines.append('  case "$1" in')
    for name, _parts, sub in shards:
        lines.append(f'    {name}) echo "{sub}" ;;')
    lines.append('    *) echo "unknown shard: $1" >&2; return 1 ;;')
    lines.append("  esac")
    lines.append("}")
    lines.append("")
    lines.append("shard_expected_sha() {")
    lines.append('  case "$1" in')
    for name, _parts, _sub in shards:
        lines.append(f'    {name}) echo "{shard_hashes[name]}" ;;')
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


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--src", required=True, type=Path, help="dir holding the originals")
    ap.add_argument("--out", required=True, type=Path, help="dir to write parts into")
    ap.add_argument("--assembler", type=Path, default=None,
                    help="assemble-gguf.sh to patch in place")
    ap.add_argument("--variant", default=DEFAULT_VARIANT)
    ap.add_argument("--source-repo", default=DEFAULT_SOURCE_REPO)
    ap.add_argument("--source-rev", default=DEFAULT_SOURCE_REV)
    ap.add_argument("--tag", default=DEFAULT_TAG)
    ap.add_argument("--verify-only", action="store_true", help="hash sources, write nothing")
    args = ap.parse_args()

    args.out.mkdir(parents=True, exist_ok=True)

    for name, _, _, _ in DEFAULT_SHARDS:
        if not (args.src / name).is_file():
            print(f"missing source file: {args.src / name}", file=sys.stderr)
            return 1

    shards_meta: list[tuple[str, int, str]] = []
    shard_hashes: dict[str, str] = {}
    part_hashes: dict[str, str] = {}
    total = 0

    for name, expected, parts, sub in DEFAULT_SHARDS:
        src = args.src / name
        size = src.stat().st_size
        print(f"==> {name} ({size:,} bytes, {parts} part{'s' if parts != 1 else ''}"
              f"{', -> ' + sub + '/' if sub else ''})")

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

        digest, assets = split_shard(src, args.out, parts)
        if digest != expected:
            print(
                f"    FAIL source hash mismatch\n"
                f"    expected {expected}\n"
                f"    actual   {digest}\n"
                f"    Refusing to publish parts from a corrupt source.",
                file=sys.stderr,
            )
            return 1

        shards_meta.append((name, parts, sub))
        shard_hashes[name] = digest
        for asset_name, asset_digest, written in assets:
            if written > GIB:
                print(f"    FAIL {asset_name} is {written} bytes, over the 2 GiB cap",
                      file=sys.stderr)
                return 1
            part_hashes[asset_name] = asset_digest
            total += written
            print(f"    {asset_name}  {written:>13,} bytes  {asset_digest[:16]}...")

    if args.verify_only:
        print(f"\nAll sources match the published {args.source_repo} hashes.")
        return 0

    manifest = args.out / "MANIFEST.sha256"
    with manifest.open("w") as fh:
        fh.write(f"# {args.variant} — release asset checksums (sha256)\n")
        fh.write(f"# Source: huggingface.co/{args.source_repo} @ {args.source_rev}\n")
        fh.write("# PTQ1_0 and PQ2_0 ship as .part-N; concatenate in part-N order.\n")
        fh.write("# Both projectors ship whole. The model and mmproj-Q8_0 land in\n")
        fh.write("# upstream-demo/models/bonsai2-gguf/27B/ via assemble-gguf.sh;\n")
        fh.write("# mmproj-BF16 lands in 27B-projectors/ beside it, kept out of the\n")
        fh.write("# projector glob on purpose -- see the comment in assemble-gguf.sh.\n\n")
        for name, digest in part_hashes.items():
            fh.write(f"{digest}  {name}\n")
        fh.write("\n# Reassembled whole-file hashes (match Hugging Face)\n")
        for name, digest in shard_hashes.items():
            fh.write(f"{digest}  {name}\n")
    print(f"\n==> wrote {manifest}")

    if args.assembler:
        patch_assembler(args.assembler, render_block(shards_meta, shard_hashes, part_hashes))
        print(f"==> patched {args.assembler}")

    print(f"\n{len(part_hashes)} assets, {total:,} bytes in {args.out}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
