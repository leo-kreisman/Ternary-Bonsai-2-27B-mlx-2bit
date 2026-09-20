#!/usr/bin/env bash
#
# Publish the split weight parts as GitHub Release assets.
#
# GitHub has no CLI here (no `gh`), so this drives the REST API directly.
# The token is read from the configured git credential helper and is never
# echoed. Re-running is safe: assets already uploaded at the right size are
# skipped, so an interrupted upload resumes instead of starting over.
#
# Usage:
#   scripts/upload_release.sh --parts DIR [--tag weights-v1] [--dry-run]
#   scripts/upload_release.sh --parts DIR --tag weights-4bit-v1 \
#       --name "…" --body-file release_body.md
#
set -euo pipefail

REPO="${REPO:-leo-kreisman/Ternary-Bonsai-2-27B-mlx-2bit}"
TAG="${TAG:-weights-v1}"
NAME="${NAME:-Ternary-Bonsai-2-27B MLX weights (split into <2 GiB parts)}"
BODY_FILE=""
PARTS_DIR=""
DRY_RUN=0

while [ $# -gt 0 ]; do
  case "$1" in
    --parts)     PARTS_DIR="$2"; shift 2 ;;
    --tag)       TAG="$2"; shift 2 ;;
    --name)      NAME="$2"; shift 2 ;;
    --body-file) BODY_FILE="$2"; shift 2 ;;
    --dry-run)   DRY_RUN=1; shift ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

[ -n "$PARTS_DIR" ] || { echo "need --parts DIR" >&2; exit 2; }
[ -d "$PARTS_DIR" ] || { echo "no such dir: $PARTS_DIR" >&2; exit 1; }

API="https://api.github.com/repos/${REPO}"
UPLOADS="https://uploads.github.com/repos/${REPO}"

# ------------------------------------------------------------------ token
# Pull the token from the credential helper without printing it.
TOKEN=""
if [ "$DRY_RUN" -eq 0 ]; then
  TOKEN="$(printf 'protocol=https\nhost=github.com\n\n' \
    | git-credential-manager get 2>/dev/null \
    | sed -n 's/^password=//p')"
  [ -n "$TOKEN" ] || { echo "no GitHub token from credential helper" >&2; exit 1; }
fi

api() {
  curl -sS -H "Authorization: Bearer ${TOKEN}" \
       -H "Accept: application/vnd.github+json" \
       -H "X-GitHub-Api-Version: 2022-11-28" "$@"
}

# ------------------------------------------------------------------ release
release_id=""
if [ "$DRY_RUN" -eq 0 ]; then
  release_id="$(api "${API}/releases/tags/${TAG}" | sed -n 's/.*"id": *\([0-9]*\).*/\1/p' | head -1)"
fi

if [ -z "$release_id" ] && [ "$DRY_RUN" -eq 0 ]; then
  echo "==> creating release ${TAG}"
  if [ -n "$BODY_FILE" ]; then
    [ -f "$BODY_FILE" ] || { echo "no such body file: $BODY_FILE" >&2; exit 1; }
    body="$(cat "$BODY_FILE")"
  else
  # Fallback body. Prefer --body-file so the release documents its own layout.
  body="Ternary MLX weights for prism-ml/Ternary-Bonsai-2-27B-mlx-2bit, split into <2 GiB parts.

\`model.safetensors\` is cut into five parts because GitHub caps files at
2 GiB. Concatenate \`part-0\` through \`part-4\` in order to reproduce the
original file; \`MANIFEST.sha256\` lists the sha256 of every part and of the
reassembled file. Run \`./assemble.sh\` in the repository to do this
automatically with verification.

Mirror of https://huggingface.co/prism-ml/Ternary-Bonsai-2-27B-mlx-2bit (Apache-2.0)."
  fi

  payload="$(python3 -c '
import json,sys
print(json.dumps({"tag_name":sys.argv[1],"name":sys.argv[2],"body":sys.argv[3]}))
' "$TAG" "$NAME" "$body")"

  resp="$(api -X POST "${API}/releases" -d "$payload")"
  release_id="$(printf '%s' "$resp" | sed -n 's/.*"id": *\([0-9]*\).*/\1/p' | head -1)"
  [ -n "$release_id" ] || { echo "failed to create release: $resp" >&2; exit 1; }
  echo "    release id ${release_id}"
fi

# ------------------------------------------------------------------ upload
upload_asset() {
  file="$1"
  base="$(basename "$file")"
  size="$(stat -c %s "$file")"

  if [ "$DRY_RUN" -eq 1 ]; then
    printf '    [dry]    %-48s %14d bytes\n' "$base" "$size"
    return 0
  fi

  # Skip only if an asset of this name is fully UPLOADED at the right size.
  #
  # Size alone is not evidence. A record whose upload never finished -- state
  # "starter", or anything else that is not "uploaded" -- still reports the full
  # intended size while holding no bytes. Skipping on size alone therefore
  # publishes a zero-byte part and prints "[skip] already uploaded", which reads
  # like success. Gate on state, and delete a stale record so the re-upload is
  # not rejected on the name.
  have="$(api "${API}/releases/${release_id}/assets?per_page=100" \
    | python3 -c '
import json,sys
name=sys.argv[1]
for a in json.load(sys.stdin):
    if a.get("name")==name:
        print(a.get("state","?"), a.get("size",0), a.get("id",0)); break
' "$base")"
  if [ -n "$have" ]; then
    read -r _state _size _id <<< "$have"
    if [ "$_state" = "uploaded" ] && [ "$_size" = "$size" ]; then
      printf '    [skip]   %-48s already uploaded\n' "$base"
      return 0
    fi
    printf '    [stale]  %-48s state=%s size=%s -> deleting\n' "$base" "$_state" "$_size"
    # The endpoint is /releases/assets/{id} -- NOT /releases/{release_id}/assets/{id}.
    # The latter 404s, and because it was unguarded the stale record stayed put and
    # the re-upload below failed with 422 already_exists, leaving the release
    # serving the OLD file under the new name. Observed exactly that on gguf-v1.
    _del="$(api -o /dev/null -w '%{http_code}' -X DELETE "${API}/releases/assets/${_id}")"
    if [ "$_del" != "204" ]; then
      printf '    [FAIL]   %s -> could not delete the stale asset (HTTP %s)\n' "$base" "$_del" >&2
      return 1
    fi
  fi

  printf '    [upload] %-48s %14d bytes\n' "$base" "$size"
  # --upload-file streams from disk. Do NOT use --data-binary @file here:
  # curl buffers that form in memory, which fails outright ("out of memory")
  # on multi-GB parts and would also balloon the process on smaller ones.
  code="$(curl -sS -o /tmp/gh_asset_resp.$$ -w '%{http_code}' \
    -X POST "${UPLOADS}/releases/${release_id}/assets?name=${base}" \
    -H "Authorization: Bearer ${TOKEN}" \
    -H "Content-Type: application/octet-stream" \
    --upload-file "${file}")"

  if [ "$code" != "201" ]; then
    echo "    [FAIL]   ${base} -> HTTP ${code}" >&2
    head -c 400 /tmp/gh_asset_resp.$$ >&2; echo >&2
    rm -f /tmp/gh_asset_resp.$$
    return 1
  fi
  rm -f /tmp/gh_asset_resp.$$
  printf '    [ok]     %s\n' "$base"
}

echo "==> uploading from ${PARTS_DIR}"
# Parts first (large), then whole-file assets, then the manifest.
#
# The patterns matter. The MLX release ships only `*.safetensors.part-N`, but
# the GGUF release ships `*.gguf.part-N` for the model *and* a whole `*.gguf`
# asset for the vision projector, which has no parts at all. Matching only the
# safetensors pattern uploads the manifest and silently skips every weight,
# then prints "done" and a valid-looking release URL. A given file matches at
# most one pattern here, so nothing is uploaded twice.
rc=0
for pat in '*.safetensors.part-*' '*.gguf.part-*' '*.gguf' '*.safetensors'; do
  for f in "${PARTS_DIR}"/$pat; do
    [ -e "$f" ] || continue
    upload_asset "$f" || rc=1
  done
done
if [ -f "${PARTS_DIR}/MANIFEST.sha256" ]; then
  upload_asset "${PARTS_DIR}/MANIFEST.sha256" || rc=1
fi

[ "$rc" -eq 0 ] && echo "==> done: https://github.com/${REPO}/releases/tag/${TAG}"
exit "$rc"
