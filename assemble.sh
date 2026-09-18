#!/usr/bin/env bash
#
# Reassemble Ternary-Bonsai-2-27B-mlx-2bit weights from GitHub Release parts.
#
# The single weight file is ~8.6 GB, which exceeds GitHub's 2 GiB per-file
# cap for both Git LFS and Release assets, so it is shipped as five <2 GiB
# byte-range parts and concatenated back here.
#
# Usage:
#   ./assemble.sh              # download + reassemble into this directory
#   ./assemble.sh --verify     # only re-verify existing files
#   DEST=~/models ./assemble.sh
#
# Requires: bash, curl. Uses `shasum -a 256` (present on macOS by default).
# Written for bash 3.2 so it runs on stock macOS without installing bash 5.
#
set -euo pipefail

REPO="${REPO:-leo-kreisman/Ternary-Bonsai-2-27B-mlx-2bit}"
TAG="${TAG:-weights-v1}"
# Default to the repo root: clone this repo, run ./assemble.sh, and the
# checkout itself becomes a loadable MLX model directory (the config files
# and tokenizer live here alongside the reassembled shards).
#   DEST=~/models ./assemble.sh   # to put them somewhere else instead
DEST="${DEST:-.}"
MAX_ATTEMPTS="${MAX_ATTEMPTS:-3}"

# Overridable mainly so the script can be tested against a local fixture.
BASE_URL="${BASE_URL:-https://github.com/${REPO}/releases/download/${TAG}}"

SHARDS="model.safetensors"
PARTS_PER_SHARD=5

# --- BEGIN GENERATED HASHES ---
# Regenerate with scripts/split_weights.py after re-splitting. Do not edit by hand.
shard_expected_sha() {
  case "$1" in
    model.safetensors) echo "130de5925082c168b7866b2e91b52e44abbafc99017e3ca352b77b5b55a269ed" ;;
    *) echo "unknown shard: $1" >&2; return 1 ;;
  esac
}

part_expected_sha() {
  case "$1" in
    model.safetensors.part-0) echo "7f9edef6d4c9cbaaab778f6089c388d5e910f805a549093609439fd0e42cd99b" ;;
    model.safetensors.part-1) echo "a46d1a47b762961a094d928a37c3cacba7e2d90c479a3eccf2b590ef9fee67b1" ;;
    model.safetensors.part-2) echo "aef84cf964cd5a4f3a0f69cfcafe664d52b2d92cd28a6873d12f56c1781d1ffc" ;;
    model.safetensors.part-3) echo "e6f3add026a192849905dc582e446ed1e17bc89c7fef003bc676117bcabcedac" ;;
    model.safetensors.part-4) echo "2464e72fedec333ad12c362d4e33f197cb7e63cc478800c3338610ddb026490d" ;;
    *) echo "unknown part: $1" >&2; return 1 ;;
  esac
}
# --- END GENERATED HASHES ---

sha256_of() { shasum -a 256 "$1" | awk '{print $1}'; }

for bin in curl shasum awk; do
  command -v "$bin" >/dev/null 2>&1 || { echo "Missing required tool: $bin" >&2; exit 1; }
done

VERIFY_ONLY=0
[ "${1:-}" = "--verify" ] && VERIFY_ONLY=1

mkdir -p "$DEST"
cd "$DEST"
parts_dir=".parts"
mkdir -p "$parts_dir"

# Download one part and require it to match its known hash. A part that is
# present but wrong (interrupted transfer, flaky link, bad cache) is deleted
# and fetched again, so a corrupt cache heals itself instead of wedging every
# future run on a checksum mismatch.
fetch_part() {
  part="$1"
  dest="$parts_dir/$part"
  url="${BASE_URL}/${part}"
  want="$(part_expected_sha "$part")"

  attempt=1
  while [ "$attempt" -le "$MAX_ATTEMPTS" ]; do
    if [ -f "$dest" ]; then
      if [ "$(sha256_of "$dest")" = "$want" ]; then
        echo "    [cached] $part"
        return 0
      fi
      echo "    [stale]  $part (bad checksum, discarding)"
      rm -f "$dest"
    fi

    echo "    [get]    $part (attempt $attempt/$MAX_ATTEMPTS)"
    rm -f "$dest"
    # -C - resumes a partial transfer; -f turns an HTTP error page into a
    # failure rather than silently saving it as "part of the model".
    if curl -fL -C - --retry 3 --retry-delay 2 -o "$dest" "$url" 2>/dev/null \
       && [ "$(sha256_of "$dest")" = "$want" ]; then
      echo "    [ok]     $part"
      return 0
    fi

    echo "    [warn]   $part did not verify on attempt $attempt" >&2
    attempt=$(( attempt + 1 ))
  done

  echo "    [FAIL] could not fetch a valid $part after $MAX_ATTEMPTS attempts" >&2
  echo "           url: $url" >&2
  rm -f "$dest"
  return 1
}

# ---------------------------------------------------------------- download
if [ "$VERIFY_ONLY" -eq 0 ]; then
  echo "==> Fetching weights from ${REPO}@${TAG}"
  for shard in $SHARDS; do
    i=0
    while [ "$i" -lt "$PARTS_PER_SHARD" ]; do
      fetch_part "$(printf '%s.part-%d' "$shard" "$i")" || exit 1
      i=$(( i + 1 ))
    done
  done
fi

# ---------------------------------------------------------------- reassemble
echo "==> Reassembling"
for shard in $SHARDS; do
  expected="$(shard_expected_sha "$shard")"

  if [ -f "$shard" ] && [ "$(sha256_of "$shard")" = "$expected" ]; then
    echo "    [ok]     $shard (already present, checksum matches)"
    continue
  fi

  # Build the list explicitly in numeric order. (Globbing would sort
  # part-10 before part-2; the counter loop cannot.)
  part_list=""
  i=0
  while [ "$i" -lt "$PARTS_PER_SHARD" ]; do
    p="$parts_dir/$(printf '%s.part-%d' "$shard" "$i")"
    [ -f "$p" ] || { echo "    [FAIL] missing part: $p" >&2; exit 1; }
    part_list="$part_list $p"
    i=$(( i + 1 ))
  done

  # Write to a temp file first so an interrupted run never leaves a
  # truncated shard that looks complete to a later invocation.
  # shellcheck disable=SC2086
  cat $part_list > "$shard.tmp"
  actual="$(sha256_of "$shard.tmp")"

  if [ "$actual" != "$expected" ]; then
    echo "    [FAIL] reassembled $shard does not match the published hash" >&2
    echo "           expected $expected" >&2
    echo "           actual   $actual" >&2
    echo "           Every part matched its own hash, so this points at a bug in" >&2
    echo "           this script or a tampered release — please report it." >&2
    rm -f "$shard.tmp"
    exit 1
  fi

  mv -f "$shard.tmp" "$shard"
  echo "    [ok]     $shard (reassembled, checksum verified)"
done

# ---------------------------------------------------------------- done
here="$(pwd)"
echo
echo "==> Weights ready in $here"
for shard in $SHARDS; do
  printf '    %-40s %s\n' "$shard" "$(ls -lh "$shard" | awk '{print $5}')"
done
echo
echo "Parts are kept in $parts_dir/ so re-runs are cheap. Remove with:"
echo "    rm -rf \"$here/$parts_dir\""
