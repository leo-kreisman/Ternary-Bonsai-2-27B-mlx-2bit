#!/usr/bin/env bash
#
# One command from a fresh clone to a served llama.cpp endpoint, with no
# Hugging Face access at any point.
#
#   ./serve-gguf.sh                 set up if needed, smoke-test, then serve on :8080
#   ./serve-gguf.sh --check         set up and smoke-test only; do not serve
#   ./serve-gguf.sh --port 7777     serve elsewhere
#   ./serve-gguf.sh --host 0.0.0.0  bind to the LAN instead of loopback
#   ./serve-gguf.sh --no-vision     serve without the image projector
#
# Idempotent. Re-running it when everything is in place does almost nothing.
#
# Why this exists next to serve-mlx.sh: this path touches no host that needs a
# token, no Python virtualenv, and no compiler. The whole install is a 12 MB
# prebuilt binary tarball from GitHub plus the two GGUF files, and the demo's
# own start_llama_server.sh finds them because they sit exactly where its
# downloader would have put them:
#
#   upstream-demo/models/bonsai2-gguf/27B/
#
# Three things this absorbs, all seen as real failures on a Mac:
#
#   1. `./setup.sh` calls scripts/download_models.sh (setup.sh:274), which is
#      the only step in the whole demo that talks to Hugging Face. It prompts
#      for a token and pulls ~7.8 GB. None of that is needed for the llama.cpp
#      backend, so this script never calls setup.sh.
#
#   2. The 5.95 GB PTQ1_0 band is over GitHub's 2 GiB per-file cap and is not
#      in git, so it ships as three release parts. ./assemble-gguf.sh fetches,
#      verifies and concatenates them, and this script calls it.
#
#   3. Bonsai 2's band needs the Prism fork's kernels. A mainline llama.cpp
#      build will not read PTQ1_0 at all, so the prebuilt binary is fetched
#      from PrismML-Eng/llama.cpp at the pinned tag rather than built or
#      borrowed from PATH.
#
# And it will not start the server until a known-answer prompt comes back
# correct. The failure this model produces when it is loaded wrongly is fluent
# nonsense, not a traceback, and serving that to an agent is worse than
# serving nothing.
#
set -euo pipefail

PROBE="What is the capital of France? Answer in one short sentence."
PORT=8080
HOST=127.0.0.1
DO_SERVE=1
VISION=1

usage() { sed -n '3,10p' "$0" | sed -e 's/^# \{0,1\}//'; }

while [ $# -gt 0 ]; do
  case "$1" in
    --port)      PORT="${2:?--port needs a value}"; shift 2 ;;
    --host)      HOST="${2:?--host needs a value}"; shift 2 ;;
    --check)     DO_SERVE=0; shift ;;
    --no-vision) VISION=0; shift ;;
    -h|--help)   usage; exit 0 ;;
    *)           printf 'unknown argument: %s\n\n' "$1" >&2; usage; exit 2 ;;
  esac
done

say()  { printf '\n==> %s\n' "$*"; }
note() { printf '    %s\n' "$*"; }
warn() { printf '    [warn] %s\n' "$*" >&2; }
die()  { printf '\n[STOP] %s\n' "$*" >&2; exit 1; }

ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT"

DEMO="$ROOT/upstream-demo"
GGUF_DIR="$DEMO/models/bonsai2-gguf/27B"
MODEL="$GGUF_DIR/Ternary-Bonsai-2-27B-PTQ1_0.gguf"
MMPROJ="$GGUF_DIR/Ternary-Bonsai-2-27B-mmproj-Q8_0.gguf"

for f in assemble-gguf.sh runtime/requirements.txt; do
  [ -e "$f" ] || die "$f is missing. Run this from the root of the cloned repository."
done
[ -d "$DEMO" ] || die "upstream-demo/ is missing. Run this from the root of the cloned repository."

# ---------------------------------------------------------------- 1. platform
say "1/5  platform"
case "$(uname -s)" in
  Darwin)
    note "macOS $(sw_vers -productVersion 2>/dev/null || echo '?') on $(uname -m)"
    [ "$(uname -m)" = "arm64" ] || warn "not Apple Silicon; the macos-x64 build will be used and will be slow."
    ;;
  Linux)
    note "Linux $(uname -m); the ubuntu build will be used (CPU unless you have CUDA/ROCm)."
    ;;
  *)
    warn "$(uname -s) $(uname -m) is not a platform with a prebuilt binary."
    warn "Download the weights with ./assemble-gguf.sh and build llama.cpp yourself."
    ;;
esac

# ---------------------------------------------------------------- 2. weights
say "2/5  weights"
if [ -f "$MODEL" ] && [ -f "$MMPROJ" ]; then
  note "both files are present; verifying (hashes 6.6 GB, about 30 s)"
else
  note "GGUF files are not here; fetching the release parts (~6.6 GB)"
fi
./assemble-gguf.sh || die "the GGUF fetch or verification failed. Nothing above is usable."

# ---------------------------------------------------------------- 3. binaries
say "3/5  llama.cpp binaries"
BIN="$DEMO/bin/mac/llama-server"
[ -x "$BIN" ] || BIN="$DEMO/bin/cpu/llama-server"
[ -x "$BIN" ] || BIN="$DEMO/bin/vulkan/llama-server"

if [ -x "$BIN" ]; then
  note "reusing $BIN"
else
  note "fetching the prebuilt Prism llama.cpp for this platform (about 12 MB)"
  ( cd "$DEMO" && sh scripts/download_binaries.sh ) || die \
"download_binaries.sh failed.

  It fetches a tarball from github.com/PrismML-Eng/llama.cpp at a pinned tag.
  A 404 there means the release was moved; send back the URL it printed.
  A mainline llama.cpp is not a substitute: it cannot read PTQ1_0 at all."
fi

LLAMA_CLI="$(dirname "$BIN")/llama-cli"
[ -x "$LLAMA_CLI" ] || die "llama-cli is missing next to $BIN. The tarball looks incomplete."

# ---------------------------------------------------------------- 4. smoke test
say "4/5  smoke test -- one real prompt, before any server exists"
note "asking: $PROBE"

set +e
if [ "$VISION" -eq 1 ]; then
  PROBE_OUT="$("$LLAMA_CLI" -m "$MODEL" -mm "$MMPROJ" -ngl 99 -st -rea off -n 96 \
      --temp 1.0 --top-p 0.95 --top-k 20 -p "$PROBE" 2>&1)"
else
  PROBE_OUT="$("$LLAMA_CLI" -m "$MODEL" -ngl 99 -st -rea off -n 96 \
      --temp 1.0 --top-p 0.95 --top-k 20 -p "$PROBE" 2>&1)"
fi
PROBE_RC=$?
set -e

printf '%s\n' "$PROBE_OUT" | tail -20 | sed 's/^/      /'

if [ "$PROBE_RC" -ne 0 ]; then
  die "the one-shot runner failed (exit $PROBE_RC). The output above is the reason.

  Send that output back to whoever set this repository up. Do not start the server.
  If it complains about an unknown quantisation type, the binary is not the Prism
  fork -- re-run:  rm -rf upstream-demo/bin && ./serve-gguf.sh"
fi

case "$(printf '%s' "$PROBE_OUT" | tr '[:upper:]' '[:lower:]')" in
  *paris*)
    note "correct: mentions Paris"
    ;;
  *)
    die "the model loaded and answered, but not 'Paris'.

  That is the failure this repository exists to catch. Do not serve it, and do
  not conclude the setup is broken: check, in this order,
    1. git status --short          any modified file, especially config.json
    2. ./assemble-gguf.sh --verify the two GGUF files against the published hashes
    3. the 'Model:' line the server prints -- it must be the PTQ1_0 band"
    ;;
esac

# ---------------------------------------------------------------- 5. serve
say "5/5  serve"
if [ "$DO_SERVE" -eq 0 ]; then
  note "--check: the model answers correctly. Serve it with:  ./serve-gguf.sh --port $PORT"
  exit 0
fi

printf '\n'
printf '  endpoint    http://%s:%s/v1\n' "$HOST" "$PORT"
printf '  chat ui     http://%s:%s\n' "$HOST" "$PORT"
printf '\n'
printf '  This is the tested llama.cpp backend: tool calling and image input are\n'
printf '  both wired (llama-server is started with --jinja and --mmproj).\n'
printf '\n'
printf '  Ctrl-C to stop.\n\n'

# Default: export nothing. start_llama_server.sh then picks the band with
# select_model_gguf (which knows *-PTQ1_0.gguf) and finds the projector with its
# own *mmproj*.gguf glob -- the exact path a normal upstream install would take,
# because the files sit where its downloader would have put them.
#
# With --no-vision there is no way to suppress a glob, so name the model
# explicitly instead. That is upstream's supported custom-model branch: same
# launch profile, no projector.
if [ "$VISION" -eq 0 ]; then
  export BONSAI_GGUF="$MODEL"
fi
export BONSAI_HOST="$HOST" PORT="$PORT"

cd "$DEMO"
exec sh scripts/start_llama_server.sh
