#!/usr/bin/env bash
#
# Reassemble the Bonsai 2 GGUF bands from GitHub Release parts.
#
#   ./assemble-gguf.sh              fetch, verify, place (resumable)
#   ./assemble-gguf.sh --verify     verify what is already on disk; fetch nothing
#   ./assemble-gguf.sh --dest DIR   place the files somewhere else
#
# GitHub caps a single file at 2 GiB for Release assets. The PTQ1_0 band is
# 5,946,648,928 bytes (5.54 GiB), so it ships as three byte-range parts; the
# Q8_0 vision projector is 629,246,976 bytes and ships whole. Concatenating the
# parts reproduces the Hugging Face original byte for byte.
#
# The files land in upstream-demo/models/bonsai2-gguf/27B/, which is the
# directory the demo's own scripts look in. That is the whole point: with the
# bytes here, ./scripts/start_llama_server.sh finds the model and the projector
# with no environment variables, and nothing in the llama.cpp path touches
# Hugging Face.
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
SHARDS="Ternary-Bonsai-2-27B-PTQ1_0.gguf Ternary-Bonsai-2-27B-mmproj-Q8_0.gguf"

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
    Ternary-Bonsai-2-27B-mmproj-Q8_0.gguf) echo "1" ;;
    *) echo "unknown shard: $1" >&2; return 1 ;;
  esac
}

shard_expected_sha() {
  case "$1" in
    Ternary-Bonsai-2-27B-PTQ1_0.gguf) echo "53107f530aa52eb00912263ab1ee29bd199261c87cd7b4ad4ca1318c1fe33ee3" ;;
    Ternary-Bonsai-2-27B-mmproj-Q8_0.gguf) echo "6807ede61d570bb86ba34b756a0fa109edc33668604de867c6ea6d8f1d631903" ;;
    *) echo "unknown shard: $1" >&2; return 1 ;;
  esac
}

part_expected_sha() {
  case "$1" in
    Ternary-Bonsai-2-27B-PTQ1_0.gguf.part-0) echo "c4ae8f5b2d15eb660abc4ed66e891f21a59a64c3c188d57434672205e7b0aebf" ;;
    Ternary-Bonsai-2-27B-PTQ1_0.gguf.part-1) echo "a677e95cf176833829ed410014e4e711635e07f5bbbf039e440078e14d37102e" ;;
    Ternary-Bonsai-2-27B-PTQ1_0.gguf.part-2) echo "c52897d69863a87f90cfced1d67449aab1bc596c3f881042da504f2ebe067e7c" ;;
    Ternary-Bonsai-2-27B-mmproj-Q8_0.gguf) echo "6807ede61d570bb86ba34b756a0fa109edc33668604de867c6ea6d8f1d631903" ;;
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
  target="$DEST/$shard"
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
note "placed in $DEST"
ls -l "$DEST"/*.gguf 2>/dev/null | awk '{printf "    %14s  %s\n", $5, $9}'
printf '\n'
note "Serve it, with no Hugging Face access:"
note "    cd upstream-demo"
note "    sh scripts/download_binaries.sh   # prebuilt llama.cpp, from GitHub"
note "    ./scripts/start_llama_server.sh  # finds both files here automatically"
printf '\n'
