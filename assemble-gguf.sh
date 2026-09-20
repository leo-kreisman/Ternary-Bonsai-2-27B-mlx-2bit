#!/usr/bin/env bash
#
# Reassemble the Bonsai 2 GGUF bands from GitHub Release parts.
#
#   ./assemble-gguf.sh              fetch, verify, place (resumable)
#   ./assemble-gguf.sh --verify     verify what is already on disk; fetch nothing
#   ./assemble-gguf.sh --dest DIR   place the files somewhere else
#
# GitHub caps a single file at 2 GiB for Release assets, so both main bands ship
# as byte-range parts: PTQ1_0 is 5,946,648,928 bytes (5.54 GiB) and ships as
# three, PQ2_0 is 7,206,168,928 bytes (6.71 GiB) and ships as four. Both vision
# projectors ship whole -- mmproj-Q8_0 at 629,246,976 bytes and mmproj-BF16 at
# 931,145,856 bytes. Concatenating the parts reproduces the Hugging Face original
# byte for byte.
#
# Both bands need the Prism fork of llama.cpp. PTQ1_0 and PQ2_0 use ggml type
# ids past upstream's GGML_TYPE_COUNT, so stock mainline refuses them outright.
# There is no stock-llama.cpp band here, and the Q2_0 file is NOT a substitute:
# mainline knows that type id and loads it silently into gibberish.
#
# The model and the tested projector land in
# upstream-demo/models/bonsai2-gguf/27B/, the directory the demo's own scripts
# look in: ./scripts/start_llama_server.sh finds both with no environment
# variables, and nothing in the llama.cpp path touches Hugging Face.
#
# mmproj-BF16 lands in 27B-projectors/ instead, one directory over. That is
# deliberate, not an oversight: start_llama_server.sh picks its projector with
# `for _mp in $GGUF_MODEL_DIR/*mmproj*.gguf; do ...; break; done`, so the first
# glob match wins -- and "mmproj-BF16" sorts before "mmproj-Q8_0". Dropping it
# beside the model would silently switch every run from the tested Q8_0
# projector to an untested one, and the smoke-test probe is text-only, so it
# would not catch it. Use it with BONSAI_MMPROJ=<path> if you want it.
#
# A part that fails its sha256 is a bad download, not a wrong hash: it is
# deleted and re-fetched. Do not edit the expected hashes to match a download.
#
set -euo pipefail

REPO="${REPO:-leo-kreisman/Ternary-Bonsai-2-27B-mlx-2bit}"
TAG="${TAG:-gguf-v1}"
# Overridable mainly so the script can be tested against a local fixture.
BASE_URL="${BASE_URL:-https://github.com/${REPO}/releases/download/${TAG}}"

# Name, in reassembly order. Each one is either a whole asset or the base name
# of a set of .part-N assets; shard_parts() below says which, and it is
# generated from the actual split, not assumed here.
#
# This list itself is NOT generated -- split_gguf.py only rewrites the block
# between the GENERATED HASHES markers. Add a band to DEFAULT_SHARDS there and
# you must add it here by hand, or it is silently never fetched. A band missing
# from this list is invisible: the script still runs clean and prints "ready".
SHARDS="Ternary-Bonsai-2-27B-PTQ1_0.gguf Ternary-Bonsai-2-27B-PQ2_0.gguf Ternary-Bonsai-2-27B-mmproj-Q8_0.gguf Ternary-Bonsai-2-27B-mmproj-BF16.gguf"

MAX_ATTEMPTS=3

say()  { printf '\n==> %s\n' "$*"; }
note() { printf '    %s\n' "$*"; }
warn() { printf '    [warn] %s\n' "$*" >&2; }
die()  { printf '\n[STOP] %s\n' "$*" >&2; exit 1; }

ROOT="$(cd "$(dirname "$0")" && pwd)"
DEST="$ROOT/upstream-demo/models/bonsai2-gguf/27B"
FETCH=1

while [ $# -gt 0 ]; do
  case "$1" in
    --verify)  FETCH=0; shift ;;
    --dest)    DEST="${2:?--dest needs a directory}"; shift 2 ;;
    -h|--help) sed -n '3,8p' "$0" | sed -e 's/^# \{0,1\}//'; exit 0 ;;
    *)         printf 'unknown argument: %s\n' "$1" >&2; exit 2 ;;
  esac
done

# --- BEGIN GENERATED HASHES ---
# Regenerate with scripts/split_gguf.py after re-splitting. Do not edit by hand.

shard_parts() {
  case "$1" in
    Ternary-Bonsai-2-27B-PTQ1_0.gguf) echo "3" ;;
    Ternary-Bonsai-2-27B-PQ2_0.gguf) echo "4" ;;
    Ternary-Bonsai-2-27B-mmproj-Q8_0.gguf) echo "1" ;;
    Ternary-Bonsai-2-27B-mmproj-BF16.gguf) echo "1" ;;
    *) echo "unknown shard: $1" >&2; return 1 ;;
  esac
}

# Subdirectory under DEST this shard lands in; empty means DEST itself.
# Non-empty is used to keep a file out of start_llama_server.sh's
# `*mmproj*.gguf` glob, which takes the first match and would otherwise
# silently change which projector loads. See split_gguf.py.
shard_dest_subdir() {
  case "$1" in
    Ternary-Bonsai-2-27B-PTQ1_0.gguf) echo "" ;;
    Ternary-Bonsai-2-27B-PQ2_0.gguf) echo "" ;;
    Ternary-Bonsai-2-27B-mmproj-Q8_0.gguf) echo "" ;;
    Ternary-Bonsai-2-27B-mmproj-BF16.gguf) echo "27B-projectors" ;;
    *) echo "unknown shard: $1" >&2; return 1 ;;
  esac
}

shard_expected_sha() {
  case "$1" in
    Ternary-Bonsai-2-27B-PTQ1_0.gguf) echo "53107f530aa52eb00912263ab1ee29bd199261c87cd7b4ad4ca1318c1fe33ee3" ;;
    Ternary-Bonsai-2-27B-PQ2_0.gguf) echo "3907dc1658db1f78a9826bf8d5bcb8dc65db0d466388937af57f2294fae62ec1" ;;
    Ternary-Bonsai-2-27B-mmproj-Q8_0.gguf) echo "6807ede61d570bb86ba34b756a0fa109edc33668604de867c6ea6d8f1d631903" ;;
    Ternary-Bonsai-2-27B-mmproj-BF16.gguf) echo "e287342d92332fa3577ed1d42e921dac9370c08da58ba9337fa450f6cc76cfd7" ;;
    *) echo "unknown shard: $1" >&2; return 1 ;;
  esac
}

part_expected_sha() {
  case "$1" in
    Ternary-Bonsai-2-27B-PTQ1_0.gguf.part-0) echo "c4ae8f5b2d15eb660abc4ed66e891f21a59a64c3c188d57434672205e7b0aebf" ;;
    Ternary-Bonsai-2-27B-PTQ1_0.gguf.part-1) echo "a677e95cf176833829ed410014e4e711635e07f5bbbf039e440078e14d37102e" ;;
    Ternary-Bonsai-2-27B-PTQ1_0.gguf.part-2) echo "c52897d69863a87f90cfced1d67449aab1bc596c3f881042da504f2ebe067e7c" ;;
    Ternary-Bonsai-2-27B-PQ2_0.gguf.part-0) echo "c76cc27bf7b59c7f732b434fcd961a00baa8c78ac112e747a5b533b10bced2ed" ;;
    Ternary-Bonsai-2-27B-PQ2_0.gguf.part-1) echo "3bf4f8b26cad40df53a2627bb57c4c678ec5d3ca4d7d8f7ca7894acf9c0b76c4" ;;
    Ternary-Bonsai-2-27B-PQ2_0.gguf.part-2) echo "fd9779cb9010548fbb2086244b862dd36087d810f9546b2ee4afbacffc41d50f" ;;
    Ternary-Bonsai-2-27B-PQ2_0.gguf.part-3) echo "18b39c944e19ea4f0774e8342ffce632ede837772a3516dd44c21d1d0fe41717" ;;
    Ternary-Bonsai-2-27B-mmproj-Q8_0.gguf) echo "6807ede61d570bb86ba34b756a0fa109edc33668604de867c6ea6d8f1d631903" ;;
    Ternary-Bonsai-2-27B-mmproj-BF16.gguf) echo "e287342d92332fa3577ed1d42e921dac9370c08da58ba9337fa450f6cc76cfd7" ;;
    *) echo "unknown part: $1" >&2; return 1 ;;
  esac
}
# --- END GENERATED HASHES ---

sha256_of() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  else
    sha256sum "$1" | awk '{print $1}'
  fi
}

size_of() { wc -c < "$1" | tr -d ' '; }

# Fetch one asset to one path. curl -C - asks for the remaining byte range, so a
# transfer that died mid-part resumes rather than starting the 1.9 GB over.
fetch_asset() {
  _url="$1"; _dest="$2"; _sha="$3"
  _attempt=1
  while [ "$_attempt" -le "$MAX_ATTEMPTS" ]; do
    if [ -f "$_dest" ] && [ "$(sha256_of "$_dest")" = "$_sha" ]; then
      note "$(basename "$_dest"): ok (already here)"
      return 0
    fi
    note "$(basename "$_dest"): fetching (attempt $_attempt/$MAX_ATTEMPTS)"
    # -C - resumes a partial transfer rather than starting a 1.9 GB part over.
    # A resumed-but-wrong file cannot pass the check below, and is deleted so
    # the next attempt starts clean; a partial kept after a *connection*
    # failure is kept precisely so the next attempt can resume into it.
    if curl -fL -C - --retry 3 --retry-delay 2 --progress-bar -o "$_dest" "$_url"; then
      _got="$(sha256_of "$_dest")"
      if [ "$_got" = "$_sha" ]; then
        note "$(basename "$_dest"): sha256 ok"
        return 0
      fi
      warn "$(basename "$_dest"): sha256 mismatch"
      warn "  expected $_sha"
      warn "  actual   $_got"
      rm -f "$_dest"
    else
      warn "$(basename "$_dest"): transfer failed; keeping the partial to resume"
    fi
    _attempt=$(( _attempt + 1 ))
  done
  rm -f "$_dest"
  return 1
}

mkdir -p "$DEST"

rc=0
for shard in $SHARDS; do
  parts="$(shard_parts "$shard")" || die "no part count for $shard; this script is out of step with the release."
  sub="$(shard_dest_subdir "$shard")" || die "no destination for $shard; this script is out of step with the release."
  if [ -n "$sub" ]; then target="$DEST/$sub/$shard"; else target="$DEST/$shard"; fi
  mkdir -p "$(dirname "$target")"
  want="$(shard_expected_sha "$shard")"

  if [ "$parts" -le 1 ]; then
    say "$shard  (1 asset, ships whole)"
    [ "$FETCH" -eq 1 ] || { [ -f "$target" ] || die "$target is not here."; }
    if [ "$FETCH" -eq 1 ]; then
      fetch_asset "$BASE_URL/$shard" "$target" "$want" || { rc=1; continue; }
    fi
  else
    say "$shard  ($parts parts)"
    work="$DEST/.parts/$shard"
    mkdir -p "$work"
    idx=0
    failed=0
    while [ "$idx" -lt "$parts" ]; do
      part="$shard.part-$idx"
      psha="$(part_expected_sha "$part")" || die "no hash for $part."
      if [ "$FETCH" -eq 1 ]; then
        fetch_asset "$BASE_URL/$part" "$work/$part" "$psha" || { failed=1; break; }
      else
        [ -f "$work/$part" ] || { warn "$work/$part is not here"; failed=1; break; }
        [ "$(sha256_of "$work/$part")" = "$psha" ] || { warn "$work/$part: sha256 mismatch"; failed=1; break; }
      fi
      idx=$(( idx + 1 ))
    done
    [ "$failed" -eq 0 ] || { rc=1; continue; }

    if [ "$FETCH" -eq 1 ]; then
      # Concatenate into $target.tmp and then move it into place, so an
      # interrupted run never leaves a truncated file that a later run would
      # mistake for a complete one. (Same pattern as assemble.sh.)
      note "concatenating $parts parts -> $shard"
      idx=0
      while [ "$idx" -lt "$parts" ]; do
        cat "$work/$shard.part-$idx"
        idx=$(( idx + 1 ))
      done > "$target.tmp" || { warn "could not write $target.tmp"; rc=1; continue; }
      mv -f "$target.tmp" "$target"
    fi
  fi

  if [ ! -f "$target" ]; then
    warn "$target is missing"; rc=1; continue
  fi
  got="$(sha256_of "$target")"
  if [ "$got" != "$want" ]; then
    warn "$shard: whole-file sha256 mismatch"
    warn "  expected $want"
    warn "  actual   $got"
    warn "  The parts are kept in $DEST/.parts/. Delete both and re-run:"
    warn "      rm -f '$target' && rm -rf '$DEST/.parts' && ./assemble-gguf.sh"
    rc=1
    continue
  fi
  note "$shard: $(size_of "$target") bytes, sha256 ok"
done

if [ "$rc" -ne 0 ]; then
  die "one or more files did not verify. Nothing above is usable; re-run to retry."
fi

say "done"
note "model files in $DEST"
ls -l "$DEST"/*.gguf 2>/dev/null | awk '{printf "    %14s  %s\n", $5, $9}'
# Extra projectors deliberately live one directory over, so they cannot win the
# first-match glob start_llama_server.sh uses to pick a projector. They are
# still fetched and verified; use them with BONSAI_MMPROJ=<path>.
for _extra in "$DEST"/*/; do
  [ -d "$_extra" ] || continue
  case "$_extra" in */.parts/) continue ;; esac
  ls -l "$_extra"*.gguf 2>/dev/null | awk '{printf "    %14s  %s\n", $5, $9}'
done
printf '\n'
note "Serve it, with no Hugging Face access:"
note "    cd upstream-demo"
note "    sh scripts/download_binaries.sh   # prebuilt llama.cpp, from GitHub"
note "    ./scripts/start_llama_server.sh  # finds the model + projector here automatically"
printf '\n'
