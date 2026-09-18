#!/usr/bin/env bash
#
# One command from a fresh clone to a served MLX endpoint.
#
#   ./serve-mlx.sh                 set up if needed, smoke-test, then serve on :8080
#   ./serve-mlx.sh --check         set up and smoke-test only; do not serve
#   ./serve-mlx.sh --port 7777     serve elsewhere
#   ./serve-mlx.sh --host 0.0.0.0  bind to the LAN instead of loopback
#   ./serve-mlx.sh --fast          size-check the weights only, skip the 8.6 GB hash
#   ./serve-mlx.sh --rebuild       throw the venv away and build it again
#
# Idempotent. Re-running it when everything is already in place does almost
# nothing and costs almost nothing. There is no copy-paste step, by design:
# every command below was a place a human or an agent got it wrong.
#
# The five traps this script exists to absorb, all seen on a real Mac:
#
#   1. `uv` verifies downloads against its own bundled Mozilla root list and
#      does not read the macOS keychain. Behind a TLS-inspecting proxy
#      (corporate VPN, Zscaler/Netskope, some antivirus) the proxy's root CA is
#      invisible to it, so every download dies as
#          invalid peer certificate: UnknownIssuer
#      which reads as "the file is broken". It is not. Fixed with UV_NATIVE_TLS=1.
#
#   2. `UV_PYTHON=python3 uv venv` resolves to whatever `python3` is. On a Mac
#      with Homebrew that can be 3.14, outside the pack's declared >=3.11,<3.13.
#      `uv` prints a warning and builds it anyway, so you get a 3.14 venv full of
#      cp314 wheels for a runtime that never claimed to support them. Pinned here.
#
#   3. `uv venv` on an existing venv asks "Do you want to replace it?" and waits
#      for a human. An agent will sit there or answer it wrongly. --allow-existing.
#
#   4. `config.json` is shipped and load-bearing, and an agent has already
#      "fixed" it by rewriting model_type. Reverted here before anything loads.
#
#   5. The 8.6 GB model.safetensors is not in git. Without it every loader dies
#      inside mx.load with a file error that reads like a corrupt pack.
#
# And it will not start the server until a known-answer prompt comes back
# correct, because the failure this pack produces is fluent nonsense, not a
# traceback. A wrong answer here means the Hadamard rotation is being skipped,
# and serving that to a coding agent is worse than serving nothing.
#
set -euo pipefail

# ---------------------------------------------------------------- constants
WANT_SIZE=8595477990
WANT_SHA=130de5925082c168b7866b2e91b52e44abbafc99017e3ca352b77b5b55a269ed
PROBE="What is the capital of France? Answer in one short sentence."

# ---------------------------------------------------------------- arguments
PORT=8080
HOST=127.0.0.1
DO_SERVE=1
FAST=0
REBUILD=0

usage() {
  sed -n '3,10p' "$0" | sed -e 's/^# \{0,1\}//'
}

while [ $# -gt 0 ]; do
  case "$1" in
    --port)      PORT="${2:?--port needs a value}"; shift 2 ;;
    --host)      HOST="${2:?--host needs a value}"; shift 2 ;;
    --check)     DO_SERVE=0; shift ;;
    --fast)      FAST=1; shift ;;
    --rebuild)   REBUILD=1; shift ;;
    -h|--help)   usage; exit 0 ;;
    *)           printf 'unknown argument: %s\n\n' "$1" >&2; usage; exit 2 ;;
  esac
done

say()  { printf '\n==> %s\n' "$*"; }
note() { printf '    %s\n' "$*"; }
warn() { printf '    [warn] %s\n' "$*" >&2; }
die() {
  printf '\n[STOP] %s\n' "$*" >&2
  exit 1
}

# A 503 from files.pythonhosted.org is transient, and it is not polite about it:
# in one real run the CDN served `mlx==0.32.0` and then refused `mlx-vlm` in the
# same install with "503 Service Unavailable". Retrying is the entire fix, and a
# human should not have to re-run the script to get it.
retry_install() {
  _attempt=1
  while [ "$_attempt" -le 4 ]; do
    if "$@"; then return 0; fi
    [ "$_attempt" -eq 4 ] && break
    _wait=$(( _attempt * 10 ))
    note "attempt $_attempt failed; retrying in ${_wait}s"
    sleep "$_wait"
    _attempt=$(( _attempt + 1 ))
  done
  return 1
}

INSTALL_FAIL_HELP="the install failed on all 4 attempts.

  If the last error was '503 Service Unavailable' or 'HTTP status server error',
  that came from PyPI's CDN and is transient. Wait a minute and re-run:
      ./serve-mlx.sh --port $PORT
  Anything already installed is kept, so a re-run resumes rather than restarts.

  If the last error was 'invalid peer certificate: UnknownIssuer', then
  UV_NATIVE_TLS=1 did not take effect - send the output back.
  If it was a 404 for a specific wheel, send that URL back."

ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT"

VENV="$ROOT/upstream-demo/.venv-vlm"
SERVER="$ROOT/upstream-demo/scripts/mlx_server_bonsai2.py"
GEN="$ROOT/upstream-demo/scripts/mlx_generate_bonsai2.py"
REQS="$ROOT/runtime/requirements.txt"

for f in config.json assemble.sh "$SERVER" "$GEN" "$REQS"; do
  [ -e "$f" ] || die "$f is missing. Run this from the root of the cloned repository."
done

# ---------------------------------------------------------------- 1. platform
say "1/6  platform"
case "$(uname -s)" in
  Darwin)
    note "macOS $(sw_vers -productVersion 2>/dev/null || echo '?') on $(uname -m)"
    if [ "$(uname -m)" != "arm64" ]; then
      warn "not Apple Silicon. MLX has no GPU here; this will be very slow or will fail."
    fi
    ;;
  *)
    warn "$(uname -s) $(uname -m), not macOS. MLX falls back to CPU or refuses."
    ;;
esac

# ---------------------------------------------------------------- 2. checkout
say "2/6  checkout"
command -v python3 >/dev/null 2>&1 \
  || die "no python3 on PATH. Install the Xcode command line tools: xcode-select --install"

if [ -d .git ] && command -v git >/dev/null 2>&1; then
  dirty="$(git status --porcelain || true)"
  if [ -n "$dirty" ]; then
    note "uncommitted changes in this checkout:"
    printf '%s\n' "$dirty" | sed 's/^/      /'
  fi
  # config.json is the dangerous one: a rewritten model_type loads fine and
  # skips the rotation, so the answer is fluent and wrong. Revert, do not patch.
  case "$dirty" in
    *config.json*)
      warn "config.json has been modified; restoring the shipped copy"
      git checkout -- config.json
      ;;
  esac
fi

read_config() {
  python3 -c "
import json
c = json.load(open('config.json'))
print(c.get('model_type', '?'), c.get('base_model_type', '?'))
"
}
CONFIG_VALS="$(read_config)"
MODEL_TYPE="${CONFIG_VALS%% *}"
BASE_TYPE="${CONFIG_VALS##* }"

[ "$MODEL_TYPE" = "prism_hadamard_qwen35" ] || die \
"config.json says model_type='$MODEL_TYPE', expected 'prism_hadamard_qwen35'.

  Both values are correct at the same time and neither needs fixing:
    model_type       prism_hadamard_qwen35   the pack's own loaders refuse anything else
    base_model_type  qwen3_5                 chat_config() swaps this in at load time

  A pack that says 'qwen3_5' here loads successfully under stock mlx_lm and
  answers nonsense, because the Hadamard rotation is skipped. Restore it; do not
  patch it:  git checkout -- config.json"

[ "$BASE_TYPE" = "qwen3_5" ] || die \
"config.json says base_model_type='$BASE_TYPE', expected 'qwen3_5'. Restore it: git checkout -- config.json"

note "config.json ok (model_type=$MODEL_TYPE, base_model_type=$BASE_TYPE)"

# ---------------------------------------------------------------- 3. weights
say "3/6  weights"
if [ ! -f model.safetensors ]; then
  note "model.safetensors is not here; fetching the five release parts (~8.6 GB)"
  ./assemble.sh
elif [ "$(wc -c < model.safetensors | tr -d ' ')" != "$WANT_SIZE" ]; then
  note "model.safetensors is the wrong size ($(wc -c < model.safetensors | tr -d ' ') bytes); re-fetching"
  ./assemble.sh
fi

if [ "$FAST" -eq 1 ]; then
  note "size ok, $(wc -c < model.safetensors | tr -d ' ') bytes (--fast: hash not checked)"
else
  note "hashing 8.6 GB (about 30 s; --fast skips this)"
  GOT_SHA="$(shasum -a 256 model.safetensors | awk '{print $1}')"
  if [ "$GOT_SHA" != "$WANT_SHA" ]; then
    die "model.safetensors does not match the published hash.

  expected $WANT_SHA
  actual   $GOT_SHA

  The parts are kept in .parts/. Delete both and re-run to refetch:
      rm -f model.safetensors && rm -rf .parts && ./serve-mlx.sh"
  fi
  note "sha256 ok"
fi

# ---------------------------------------------------------------- 4. venv
say "4/6  venv"
export UV_NATIVE_TLS=1   # uv ignores the macOS keychain; see trap 1 at the top

if [ "$REBUILD" -eq 1 ] && [ -d "$VENV" ]; then
  note "--rebuild: removing $VENV"
  rm -rf "$VENV"
fi

venv_py() { "$VENV/bin/python" -c 'import sys; print("%d.%d" % sys.version_info[:2])' 2>/dev/null || echo none; }

if [ -x "$VENV/bin/python" ]; then
  HAVE_PY="$(venv_py)"
  case "$HAVE_PY" in
    3.11|3.12) note "reusing $VENV (python $HAVE_PY)" ;;
    *) warn "the existing venv is on python $HAVE_PY, outside >=3.11,<3.13; rebuilding"
       rm -rf "$VENV" ;;
  esac
fi

if [ -x "$VENV/bin/python" ] && "$VENV/bin/python" -c 'import mlx.core, mlx_vlm, transformers' 2>/dev/null; then
  note "mlx, mlx-vlm and transformers are already installed"
else
  if command -v uv >/dev/null 2>&1; then
    note "uv venv --python 3.11 (UV_NATIVE_TLS=1, --allow-existing)"
    uv venv "$VENV" --python 3.11 --allow-existing || die \
"uv could not provide a Python 3.11.

  If it failed fetching an interpreter, install one and re-run:
      brew install python@3.11 && uv venv '$VENV' --python 3.11 --allow-existing
  If it failed with 'invalid peer certificate: UnknownIssuer', UV_NATIVE_TLS=1
  is already set here, so the proxy is blocking the interpreter download itself;
  use a local 3.11 via the brew line above."
    note "uv pip install -r runtime/requirements.txt (4 attempts; 503s are transient)"
    retry_install uv pip install --python "$VENV/bin/python" -r "$REQS" \
      || die "$INSTALL_FAIL_HELP"
  else
    PY311="$(command -v python3.11 || command -v python3.12 || true)"
    [ -n "$PY311" ] || die \
"no uv, and no python3.11 or python3.12 on PATH.

  Install either one:
      brew install uv
      brew install python@3.11"
    note "$PY311 -m venv $VENV"
    "$PY311" -m venv "$VENV"
    "$VENV/bin/pip" install --quiet --upgrade pip
    note "pip install -r runtime/requirements.txt (4 attempts; 503s are transient)"
    retry_install "$VENV/bin/pip" install -r "$REQS" \
      || die "$INSTALL_FAIL_HELP"
  fi
fi

HAVE_PY="$(venv_py)"
case "$HAVE_PY" in
  3.11|3.12) note "python $HAVE_PY" ;;
  *) die "the venv ended up on python $HAVE_PY. The pack declares >=3.11,<3.13.
  Rebuild it against a supported interpreter:  ./serve-mlx.sh --rebuild" ;;
esac

# ---------------------------------------------------------------- 5. smoke test
say "5/6  smoke test -- one real prompt, before any server exists"
note "asking: $PROBE"
set +e
PROBE_OUT="$("$VENV/bin/python" "$GEN" --model "$ROOT" -p "$PROBE" 2>&1)"
PROBE_RC=$?
set -e

printf '%s\n' "$PROBE_OUT" | sed 's/^/      /'

if [ "$PROBE_RC" -ne 0 ]; then
  die "the one-shot runner failed (exit $PROBE_RC). The output above is the reason.

  Send that output back to whoever set this repository up. Do not start the server."
fi

case "$(printf '%s' "$PROBE_OUT" | tr '[:upper:]' '[:lower:]')" in
  *paris*)
    note "correct: mentions Paris, so the rotation is being applied"
    ;;
  *)
    die "the model answered, but not 'Paris'.

  That is the failure this repository exists to catch. A Bonsai 2 pack whose
  Hadamard rotation is skipped does not error -- it answers fluently and wrongly.
  Do not serve this to a coding agent, and do not go looking for a GGUF: the
  GGUF is a different artifact and is not the fix.

  Check, in this order:
    1. git status --short           any modified file, especially config.json
    2. ./serve-mlx.sh --fast        confirms the weights, rechecks config.json
    3. the model_type line above    must read prism_hadamard_qwen35"
    ;;
esac

# ---------------------------------------------------------------- 6. serve
say "6/6  serve"

if [ "$DO_SERVE" -eq 0 ]; then
  note "--check: everything is installed and the model answers correctly."
  note "Serve it with:  ./serve-mlx.sh --port $PORT"
  exit 0
fi

printf '\n'
printf '  endpoint    http://%s:%s/v1\n' "$HOST" "$PORT"
printf '  model id    bonsai2-27b-mlx\n'
printf '  health      http://%s:%s/health\n' "$HOST" "$PORT"
printf '\n'
printf '  This MLX server is new and this may be its first run. Validate it in\n'
printf '  another terminal before pointing an agent at it:\n'
printf '\n'
printf "    curl http://%s:%s/v1/chat/completions -H 'Content-Type: application/json' \\\\\n" "$HOST" "$PORT"
printf "      -d '{\"messages\":[{\"role\":\"user\",\"content\":\"What is the capital of France?\"}]}'\n"
printf '\n'
printf '  Mentions Paris  -> point your CLI at http://%s:%s/v1\n' "$HOST" "$PORT"
printf '  Fluent nonsense -> stop. That is the rotation being skipped.\n'
printf '\n'
printf '  Ctrl-C to stop.\n'
printf '\n'

exec "$VENV/bin/python" "$SERVER" --model "$ROOT" --host "$HOST" --port "$PORT"
