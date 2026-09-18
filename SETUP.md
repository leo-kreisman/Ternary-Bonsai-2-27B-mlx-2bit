# Run Ternary Bonsai 2 27B on macOS — setup

**Two things on this page: the path, and the refutation.** Do the path. If
something argues with you, the refutation is in §2 and it covers every wrong
conclusion this model has caused so far.

Target machine: Apple Silicon, 18 GB (M3 Pro). Works on any Apple Silicon Mac.

---

# 1. THE PATH

One path. Copy-paste in order. Nothing here needs a decision from you.

## Step 1 — Get the repo

```bash
git clone https://github.com/leo-kreisman/Ternary-Bonsai-2-27B-mlx-2bit.git
cd Ternary-Bonsai-2-27B-mlx-2bit
```

This repo already contains the upstream demo at `upstream-demo/`. You do **not**
need to clone anything else.

## Step 2 — Install

```bash
cd upstream-demo
./setup.sh
```

This **downloads prebuilt binaries; it does not compile anything.** It installs
`uv` if missing, creates a Python 3.11 venv, pulls the PrismML `llama.cpp` fork
binaries (`prism-b10683-d8f26ee`, macOS arm64) into `bin/mac/`, then clears the
Gatekeeper quarantine flag and ad-hoc codesigns them. Skipping that last step is
why unsigned binaries get killed on first run.

> **It will ask for a Hugging Face token. Press Enter to skip it.** The prompt
> says so itself ("press Enter to skip"), and `setup.sh:133` guards it with
> `if [ -z "$BONSAI_TOKEN" ] && [ -r /dev/tty ]` — it is offered, never required.
> Step 3 asks the same thing. **You do not need a token, and you should not paste
> one.** Both repos this pulls from report `private: false, gated: false` and
> serve files anonymously. Upstream added the prompt because the 27B repos were
> private at one point; they are public now.
>
> If you *do* paste one, `setup.sh:143` writes it to `upstream-demo/.bonsai_token`
> (chmod 600, gitignored) and reuses it forever after. Pressing Enter leaves no
> file at all.

Takes a few minutes. It needs Xcode Command Line Tools (`xcode-select --install`
if you don't have them).

> **If it dies creating the venv, `uv` is trying to download a whole Python.**
> `setup.sh:250` runs `uv venv "$VENV_DIR" --python 3.11`. When no 3.11 exists
> locally, `uv` fetches a managed CPython build — and that fetch fails behind a
> proxy or firewall, killing setup for a reason that has nothing to do with the
> model. Tell `uv` to use the interpreter you already have:
>
> ```bash
> UV_PYTHON=python3 ./setup.sh
> ```
>
> That is a supported fix, not a hack: it says "do not fetch a Python." It was
> needed on the M3 Pro. If a 3.13 system Python later breaks a pinned wheel, use
> `brew install python@3.11 && UV_PYTHON=3.11 ./setup.sh` instead.
>
> Do **not** read this failure as "the model is broken" or "setup is
> unsupported" — it is a Python-provisioning detail, one line above the model
> code.

## Step 2-alt — Minimal MLX-only install (no `setup.sh`)

If all you want is the MLX one-shot command, **you do not need `setup.sh` at
all.** And there is a good reason to skip it: `setup.sh:274` ends by calling

```sh
BONSAI_FAMILY="$BONSAI_FAMILY" BONSAI_MODEL="$BONSAI_MODEL" sh "$SCRIPT_DIR/scripts/download_models.sh"
```

so **running `setup.sh` is what starts the ~7.8 GB GGUF download and the
Hugging Face token prompt.** If you have been trying to avoid both, this is
where they come from.

The MLX runner needs exactly one thing that is not in git: a venv holding `mlx`,
`mlx-vlm`, and `transformers`. This repo carries the pinned list at
`runtime/requirements.txt`, and `run_mlx.sh:63` names this exact command as the
supported by-hand alternative:

```bash
cd upstream-demo
UV_NATIVE_TLS=1 UV_PYTHON=3.11 uv venv .venv-vlm
UV_NATIVE_TLS=1 uv pip install --python .venv-vlm/bin/python -r ../runtime/requirements.txt
```

**`UV_PYTHON=3.11`, not `python3`.** The pack declares `requires-python >=3.11,
<3.13`, and `uv` will *warn* about a violating interpreter and then build the
venv anyway. On a Mac whose Homebrew `python3` is 3.14 that produces a 3.14 venv
holding `cp314` wheels for a runtime that never claimed to support them. Pin it.

**`UV_NATIVE_TLS=1` is not optional behind a TLS-inspecting proxy** (corporate
VPN, Zscaler/Netskope, some antivirus). `uv` verifies against its own bundled
Mozilla root list and ignores the macOS keychain, so a proxy's root CA is
invisible to it and every download dies as:

```
Caused by: invalid peer certificate: UnknownIssuer
```

`UV_NATIVE_TLS=1` makes `uv` use the system trust store instead. It is the fix
for that error, and it is nothing to do with this repo. (`pip` reads the keychain
already; if you fall back to `pip` and hit the same error, pass
`--cert /path/to/proxy-ca.pem`.)

**The whole path from nothing — five commands, no GGUF, no Hugging Face, no
llama.cpp binaries, no Xcode:**

```bash
git clone https://github.com/leo-kreisman/Ternary-Bonsai-2-27B-mlx-2bit.git
cd Ternary-Bonsai-2-27B-mlx-2bit
./assemble.sh          # ~8.6 GB; must print [ok] for model.safetensors
cd upstream-demo
UV_NATIVE_TLS=1 UV_PYTHON=3.11 uv venv .venv-vlm
UV_NATIVE_TLS=1 uv pip install --python .venv-vlm/bin/python -r ../runtime/requirements.txt
.venv-vlm/bin/python scripts/mlx_generate_bonsai2.py --model .. -p "What is the capital of France?"
```

Do not skip or "work around" `./assemble.sh` and then run the runner: without
`model.safetensors` in the repo root, every loader fails at `mx.load` with a file
error, which reads like a broken pack. Check it with
`ls -l model.safetensors` — it is 8,595,477,990 bytes.

If `uv` is missing or *its* Python fetch is what fails, a plain venv works
identically — no `uv` at all:

```bash
python3.11 -m venv .venv-vlm
.venv-vlm/bin/pip install -r ../runtime/requirements.txt
```

Prefer a Homebrew `python3.11` (`brew install python@3.11`; `uv` is
`brew install uv`). The reason is the *upper* bound as much as the lower: the
pinned `mlx-vlm==0.6.3` wheels want 3.11–3.12, and a modern Homebrew `python3`
is 3.14, which is outside the pack's declared range.

Use `setup.sh` when you want the **server**, Open WebUI, or the code
interpreter. Use this when you want the MLX prompt. They are different jobs and
you do not need both.

## Step 3 — Get the model

```bash
sh scripts/download_models.sh
```

Downloads into `models/bonsai2-gguf/27B/`:

| File | Size | Why |
| --- | ---: | --- |
| `*-PQ2_0.gguf` | ~7.2 GB | the model |
| `*mmproj-Q8_0.gguf` | ~0.63 GB | vision (images) |

> **This downloads from Hugging Face, and that is expected — it is the only
> source.** The GGUF bands are not in this GitHub repo. This repo mirrors the
> **MLX pack** (`model.safetensors`); the GGUF never was and is not here.
> `download_models.sh:96` pulls `prism-ml/Ternary-Bonsai-2-27B-gguf`.
>
> Step 3 offers the same optional token prompt as Step 2. **Press Enter.**
> Skipping the token does **not** skip the download — it makes it *anonymous*,
> which is what you want. Both repos report `private: false, gated: false` and
> serve files anonymously (verified: an anonymous `HEAD` on the GGUF resolves
> `200`). Expect ~7.8 GB total.
>
> **Want zero Hugging Face contact?** You do not have to download from it. If
> the GGUF files are already on disk, **Step 3-alt** below runs the server
> straight from them. Mirroring the GGUF into this repo's own releases would
> make that fully GitHub-only; it is not mirrored yet.

## Step 3-alt — Run with no Hugging Face contact at all

If the GGUF files are already on disk — from another machine, a colleague, a
backup, anywhere — **skip Step 3 entirely** and point the server at them:

```bash
BONSAI_GGUF=/path/to/Ternary-Bonsai-2-27B-PQ2_0.gguf \
BONSAI_MMPROJ=/path/to/Ternary-Bonsai-2-27B-mmproj-Q8_0.gguf \
./scripts/start_llama_server.sh
```

**This is a supported path, not a workaround.** `start_llama_server.sh:9` and
`:12` both short-circuit on `BONSAI_GGUF`:

```sh
[ -n "${BONSAI_GGUF:-}" ] || assert_valid_model
[ -n "${BONSAI_GGUF:-}" ] || assert_gguf_downloaded start_mlx_server.sh
```

So the family/size lookup and the "did you download it yet" assertion are both
skipped, `download_models.sh` is never run, and **no token, no HF, no network
call happens.** `BONSAI_MMPROJ` is optional — omit it for a text-only server.
This is upstream's own idiom: `scripts/fetch_gguf.sh:111` prints exactly this
command after it finishes downloading anything.

To skip only *half* of the Step 3 download instead:

| Command | Effect |
| --- | --- |
| `BONSAI_SKIP_GGUF=1 sh scripts/download_models.sh` | MLX weights only (saves ~7.8 GB) |
| `BONSAI_SKIP_MLX=1 sh scripts/download_models.sh` | GGUF only (what you want here) |

So even the ordinary path can be narrowed: `BONSAI_SKIP_MLX=1` stops it fetching
a second 8.6 GB MLX copy, since this repo already gives you that one.

## Step 4 — Serve it

```bash
./scripts/start_llama_server.sh
```

- OpenAI-compatible at **`http://localhost:8080/v1/chat/completions`**
- Flags it sets for you: `-ngl 99 -fa on -c 16384 --temp 1.0 --top-p 0.95
  --top-k 20 --jinja --mmproj ... --image-max-tokens 1024`
- `-c 16384` is chosen automatically for an 18 GB machine

## Step 4-alt — Serve with MLX (no GGUF, no llama.cpp)

**One command, from the repo root. This is the whole step:**

```bash
./serve-mlx.sh              # set up if needed, verify, smoke-test, serve on :8080
./serve-mlx.sh --check      # the same, but stop before serving
./serve-mlx.sh --port 7777  # serve elsewhere
```

`./serve-mlx.sh` exists so that none of this step is copy-paste. It checks the
checkout (`config.json` included, and it reverts a tampered one), fetches the
weights if they are missing, builds the venv with the two settings a fresh Mac
gets wrong, runs a known-answer prompt through the one-shot runner, and **only
starts the server if that answer is correct**. If it prints `[STOP]`, read the
message; it names the cause and the fix.

The two settings, since they are the whole reason the script exists:

| Setting | Without it |
| --- | --- |
| `UV_NATIVE_TLS=1` | `uv` checks against its bundled roots, not the macOS keychain, so a proxy's CA is invisible: `invalid peer certificate: UnknownIssuer` |
| `UV_PYTHON=3.11` | `python3` on a Homebrew Mac can be 3.14, outside the pack's `>=3.11,<3.13`; `uv` warns and builds it anyway |

It also passes `uv venv --allow-existing`, because otherwise `uv` asks
"Do you want to replace it?" and waits for a human — which stalls an agent.

**Manual equivalent**, if you want to see the pieces or the script will not run:

```bash
cd upstream-demo
UV_NATIVE_TLS=1 UV_PYTHON=3.11 uv venv .venv-vlm --allow-existing
UV_NATIVE_TLS=1 uv pip install --python .venv-vlm/bin/python -r ../runtime/requirements.txt
.venv-vlm/bin/python scripts/mlx_server_bonsai2.py --model .. --port 8080
```

```bash
curl http://127.0.0.1:8080/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"messages":[{"role":"user","content":"What is the capital of France?"}]}'
```

Point a coding agent at **`http://127.0.0.1:8080/v1`**. Text only — for images
use `run_mlx.sh --image`. Endpoints: `/v1/chat/completions`, `/v1/models`,
`/health`.

> **Read this before you trust it: the file has never been run.** It was written
> without an Apple Silicon machine available, so it is unverified. **The first
> command you run must be that `curl`** — which is exactly why `./serve-mlx.sh`
> runs a known-answer prompt before it serves anything.
>
> - Coherent answer → the server works. Wire your agent to it.
> - **Fluent nonsense → stop.** That is the rotation being skipped, and it means
>   this server is not applying the loader correctly. Do not use it, and say so;
>   it is a bug in a new file, not a property of the model.

**Why this file exists.** `mlx_vlm.server` and `mlx_lm.server` cannot serve this
pack: they load the rotated weights and return wrong output with no error, which
is why upstream's `start_mlx_server.sh` refuses `bonsai2`. This server calls
`vision_artifact.load_vl_model` and the same `mlx_vlm.generate` as
`scripts/mlx_generate_bonsai2.py`, so the transform is applied. It uses only the
standard library for HTTP, because `runtime/requirements.txt` pins exact versions
and carries no web framework.

Two known limits, both deliberate: generation is **not** token-by-token streamed
(a `stream: true` request replays the finished text as one SSE delta), and
requests serialise on a lock, because MLX generation is not safe to run
concurrently on one model instance.

## Step 5 — Use it

```bash
curl http://localhost:8080/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"messages":[{"role":"user","content":"What is the capital of France?"}]}'
```

Open WebUI: `./scripts/start_openwebui.sh`. Point it at `http://localhost:8080/v1`.

## Optional — one-off prompt, no server

```bash
./scripts/run_llama.sh -p "What is the capital of France?"
```

**On MLX it is also one command, and no script:**

```bash
.venv-vlm/bin/python scripts/mlx_generate_bonsai2.py --model .. -p "What is the capital of France?"
```

`scripts/mlx_generate_bonsai2.py` is the complete MLX driver. It applies the
Hadamard rotation through the bundled loader, verifies the runtime against
`bonsai2-runtime.sha256`, handles the thinking phase, and accepts images. **Do
not write your own Python to load this model.** See §2.

**That is the whole path.** Everything below is either the refutation or
reference material.

---

# 2. THE REFUTATION

Thirteen wrong conclusions this model reliably produces. If you or an agent reached
one of these, you were not being stupid — the documentation actively misleads on
several of them — but none of them is true, and none is worth another minute.

### ❌ "This isn't an MLX model" / "MLX is unsupported for it"

**False, and this is the one currently costing you time.** This **is** an MLX
model. `library_name` is `mlx`, the weights are MLX safetensors, the pack's
loader builds an `mlx_vlm` model, and Bonsai 2 runs on **stock MLX** — the
PrismML `mlx` fork is for the 1-bit family, not this pack. From `run_mlx.sh:56`:

```sh
# Bonsai 2 packs carry their own Hadamard-aware loader and run on stock MLX through
# mlx-vlm, which lives in .venv-vlm; the fork in .venv is for the 1-bit family.
```

The true statement is far narrower: the stock `mlx_lm` / `mlx_vlm` **server and
loader entry points** cannot be pointed at this pack, because they apply no
rotation transform. "No MLX server exists" is not "not an MLX model", and it is
not "MLX is broken here". One-shot MLX works right now:

```bash
cd upstream-demo && ./scripts/run_mlx.sh -p "What is the capital of France?"
```

If a summary of this repo told you MLX is out, that summary over-read §3's
"one-shot only" line — which is about the *server*, not the *model*.

### ❌ "`mlx_lm.server` would load these weights cleanly"

**False.** The weights are stored in a **blockwise Hadamard-rotated basis**. Every
projection was rotated before ternary quantization, and the runtime must apply the
matching transform to activations as it runs. `mlx_lm.load` / `mlx_lm.server`
apply no such transform.

Worse than failing: they can *succeed* and produce confident nonsense, because the
arithmetic stays numerically valid while being wrong.

This is upstream's design, not a broken machine. Their own
`scripts/start_mlx_server.sh` **hard-refuses `bonsai2`** and redirects you to
llama.cpp.

### ❌ "Use `artifact.load_model` — it's the easy path"

**False, and this one was my error — I published it.** The pack's own
`PACK-RUNTIME.md` says it too. It fails:

```python
# runtime/artifact.py:81-85
if config.get("schema_version") != 1 or config.get("model_type") != "prism_hadamard_qwen35":
    raise ValueError("Unsupported packed model schema")
```

This pack is **`schema_version: 2`**. So it raises before reading a single tensor.
The loader that matches is **`vision_artifact.load_vl_model`**, which has no
schema-version check and reads the schema-2 fields.

Check it yourself:

```bash
python3 -c "import json;print(json.load(open('config.json'))['schema_version'])"  # 2
grep -n schema_version runtime/artifact.py                                          # requires 1
```

### ❌ "So the download must be corrupt"

**False.** That error is a guard clause firing before any tensor is touched — it
says nothing about the file. Verify integrity properly instead:

```bash
./assemble.sh --verify
```

### ❌ "It's downloading from Hugging Face — that shouldn't be happening"

**It should, and it is the only source.** This GitHub repo mirrors the **MLX
pack**; the GGUF bands are not here and never were. `download_models.sh:96`
pulls `prism-ml/Ternary-Bonsai-2-27B-gguf`, and there is nowhere else to get
them. Contacting Hugging Face at Step 3 is the design, not a leak.

You can avoid the *call*, though — not the source. If the GGUF is already on
disk, **Step 3-alt** runs the server from it with no network access at all.

Related, and hit on this exact machine: **skipping the token prompt does not
skip the download.** The prompt (`setup.sh:133`) is about *authentication*, not
permission. Declining it makes the download run anonymously, which succeeds —
both repos are `private: false, gated: false`.

One more thing that is not the model's fault: if `setup.sh` dies **creating the
venv**, `uv` was fetching a managed CPython (`setup.sh:250`). That is a Python
provisioning failure one line above any model code. Run
`UV_PYTHON=python3 ./setup.sh` — see Step 2.

### ❌ "You have to write a Python script to run it on MLX"

**No. The runner is already written and shipped. Call it.** Agents that do not
notice `scripts/mlx_generate_bonsai2.py` write a 200-line loader from scratch,
which either duplicates it or skips the rotation. The whole interface is
`--model` and `-p`:

```bash
cd upstream-demo
.venv-vlm/bin/python scripts/mlx_generate_bonsai2.py --model .. -p "What is the capital of France?"
```

That is the entire invocation. **Do not write a loader, do not instantiate
`mlx_vlm` yourself, do not reimplement `generate`.** Everything it accepts, from
`scripts/mlx_generate_bonsai2.py:81-89`:

| Flag | Meaning |
| --- | --- |
| `-p`, `--prompt` | required |
| `--model` | required — the pack directory (`..` from `upstream-demo/`) |
| `--image PATH` | repeatable; pairs the vision tower |
| `-n`, `--max-tokens` | default 2048 |
| `--temp` | default 1.0 |
| `--top-p` | default 0.95 |
| `--top-k` | default 20 |
| `--no-think` | skip the thinking phase |

If you are authoring a Python file to run this model, stop — you have missed
this script.

### ❌ "You have to run `setup.sh`"

**Not for the MLX path, and running it is probably how you got here.**
`setup.sh:274` ends by invoking `download_models.sh`, so it is the thing that
starts the ~7.8 GB GGUF download and raises the Hugging Face token prompt. If
your goal is the MLX one-liner, `setup.sh` does a great deal you did not ask
for: `uv`, `.venv`, the llama.cpp fork binaries, the Gatekeeper fix, Open WebUI,
and a Jupyter venv.

Two commands replace it (Step 2-alt). This is not a shortcut around upstream:
`run_mlx.sh:63` prints those two commands itself as the by-hand equivalent when
`.venv-vlm` is missing.

Use `setup.sh` for the **server**. Use Step 2-alt for the **prompt**.

### ❌ "I need the GGUF file" (when you asked for the MLX path)

**Only if you want a *server*.** There are two separate artifacts and neither
one needs the other:

| You want | You need | You do **not** need |
| --- | --- | --- |
| MLX, one prompt | `model.safetensors` from `./assemble.sh` | any GGUF |
| An HTTP server on 8080 | a GGUF band + `mmproj` | `model.safetensors` |

So an agent demanding a GGUF while you asked for the inline MLX command is
answering a different question. For MLX: run `./assemble.sh` **once** at the repo
root, then the one-liner above. No GGUF, no `download_models.sh`, no Hugging
Face.

### ❌ "Vision isn't included in the MLX pack"

**False.** The pack's `components` are:

```json
{"text": true, "vision": true, "mtp": false}
```

Vision **is** there; only MTP is missing. `PACK-RUNTIME.md`'s line "Vision and MTP
are not included" describes the old text-only `artifact.py` path — half of it
applies to the wrong thing.

### ❌ "Prism built the MLX version to run in their llama.cpp fork"

**False. llama.cpp cannot open an MLX pack at all — it reads GGUF and nothing
else.** Disprove it in three greps against the vendored demo:

```bash
cd upstream-demo
grep -nE '\.gguf' scripts/start_llama_server.sh   # llama.cpp is fed GGUF, only
grep -nE 'venv|mlx' scripts/run_mlx.sh            # MLX runs under .venv-vlm python
grep -rn safetensors scripts/                     # -> no matches at all
```

That last one is the argument: **no demo script mentions `safetensors`.**

What's true is that **Prism maintains two forks**, both because the Hadamard
rotation needs a transform neither upstream project carries:

| Format | Runtime | Fork needed |
| --- | --- | --- |
| `model.safetensors` (MLX, 8.6 GB) | MLX / `mlx-vlm`, one-shot | **No** — stock MLX (`PrismML-Eng/mlx` is for the 1-bit family) |
| `*.gguf` (`PTQ1_0`, `PQ2_0`) | llama.cpp | **Yes** — `PrismML-Eng/llama.cpp` |

Two formats, two runtimes. Not one runtime loading the other's weights. Both are
real and both are supported; only the second can serve.

### ❌ "Stock llama.cpp is fine for the GGUF"

**False, and this is the dangerous one.** `PTQ1_0` and `PQ2_0` fail *safely* on
stock llama.cpp — their ggml type ids sit past upstream's `GGML_TYPE_COUNT`, so it
refuses them outright. But the **`Q2_0` band does not fail safely**: upstream
already knows the `Q2_0` type and the `qwen35` architecture, so mainline loads it
**without a warning and emits gibberish.**

That's why the `Q2_0` band lives outside the main model repo, in a file named
`...-Q2_0-prism-fork-required.gguf` — the requirement is in the filename so it
survives being copied around.

**Use the PrismML fork binaries. Every supported path does.**

---

# 3. Reference: what is in play

| | MLX pack (this repo) | GGUF bands |
| --- | --- | --- |
| File | `model.safetensors` (8.6 GB) | `*.gguf` (5.9–7.2 GB) |
| Runtime | MLX / `mlx-vlm`, `.venv-vlm` | llama.cpp, `bin/mac/llama-server` |
| Served? | **Yes** — Step 4-alt (new file, untested) | **Yes** — tested, port 8080 |
| Driver | `scripts/run_mlx.sh` | `scripts/run_llama.sh` |
| Fork needed | **No** — stock MLX + `mlx-vlm` | **Yes** — `PrismML-Eng/llama.cpp` |

Upstream ships **no** MLX server for `bonsai2` — its `start_mlx_server.sh`
refuses one. **This repo adds one** (`scripts/mlx_server_bonsai2.py`, Step 4-alt,
untested); the GGUF path stays the tested server route.

**"No upstream server" was never "not an MLX model."** It is an MLX model and
`run_mlx.sh` runs it on stock MLX — that was always true, and it is why an MLX
server could be written at all.

### ❌ "The download is broken, or this repo is"

The real thing, seen on a Mac on 2026-09-18:

```
error: Request failed after 3 retries
  Caused by: Failed to fetch: https://files.pythonhosted.org/packages/c7/da/32c75222.../pillow-12.3.0-cp314-cp314-macosx_11_0_arm64.whl.metadata
  Caused by: error sending request for url (https://files.pythonhosted.org/...)
  Caused by: client error (Connect)
  Caused by: invalid peer certificate: UnknownIssuer
```

Read it in two passes.

**`invalid peer certificate: UnknownIssuer` is a TLS interception, not a 404.**
`files.pythonhosted.org` is fine. `uv` verifies against its own bundled Mozilla
root list and does not read the macOS keychain, so the root CA installed by a
corporate VPN, Zscaler/Netskope, or some antivirus is invisible to it and every
download fails identically. The fix is one variable:

```bash
UV_NATIVE_TLS=1 uv pip install --python .venv-vlm/bin/python -r ../runtime/requirements.txt
```

`pip` reads the keychain already; if you fall back to it and see the same error,
pass `--cert /path/to/proxy-ca.pem`.

**Note `cp314` in that filename.** That wheel is for Python 3.14, which the pack
does not support (`requires-python >=3.11, <3.13`). It is there because
`UV_PYTHON=python3` resolved to a Homebrew 3.14, and `uv` warns about that and
builds the venv anyway. Pin `UV_PYTHON=3.11`.

**Its sibling, and the one you will hit next: `503 Service Unavailable`.** Same
host, same step, no certificate error:

```
Caused by: Failed to fetch: https://files.pythonhosted.org/packages/95/47/196df6.../mlx_vlm-0.6.3-py3-none-any.whl.metadata
Caused by: HTTP status server error (503 Service Unavailable) for url (...)
```

That is PyPI's CDN refusing one wheel while serving others in the same run —
`✓ mlx==0.32.0` then a 503 on `mlx-vlm` is the normal shape of it. Nothing to
diagnose: wait a minute and re-run. `./serve-mlx.sh` now retries the install four
times with a delay, and because installs are resumable, a re-run continues from
whatever is already in the venv.

Neither problem is in this repo. Nothing here contacts `files.pythonhosted.org` —
`assemble.sh` fetches only from `github.com/<repo>/releases/download/…`.

### ❌ "Bonsai 2 doesn't support thinking"

The opposite. This pack ships a reasoning chat template and thinking is **on by
default** — `enable_thinking` being *undefined* counts as true:

| Where | What it says |
| --- | --- |
| `chat_template.jinja:46` | `{%- if enable_thinking is undefined or enable_thinking is true %}` |
| `chat_template.jinja:47-55` | `reasoning_effort` is `xhigh` (the default), `medium`, or `low`; the template **raises** on anything else |
| `chat_template.jinja:165-169` | with `enable_thinking is false` it emits the pre-closed ` thinking\n\n</think>\n\n`; otherwise it opens ` thinking\n` and the model reasons |
| `mlx_generate_bonsai2.py:89,134-135` | `--no-think` exists and works by appending that same pre-closed block |
| `chat_template.jinja:57` | the template also accepts a `tools` argument |

That last row is the tell: **a flag to skip thinking is proof that thinking is
the default.** Nobody ships `--no-think` for a model that cannot think.

So a reply containing a ` thinking...</think>` block is not a bug and not
mismatched weights — it is the pack doing what it says. Turn it off with
`enable_thinking: false` in the request, `chat_template_kwargs`, or
`./serve-mlx.sh` → `scripts/mlx_server_bonsai2.py --no-think`, and pick the
effort with `--reasoning-effort low|medium|xhigh`.

## The MLX route, if you specifically want it

```bash
cd upstream-demo
./scripts/run_mlx.sh -p "What is the capital of France?"
```

Needs `.venv-vlm`. Point it at this repo's reassembled pack instead of letting the
demo fetch a second 8.6 GB copy:

```bash
cd upstream-demo
.venv-vlm/bin/python scripts/mlx_generate_bonsai2.py --model ../ -p "..."
```

(That works because `./assemble.sh` in the repo root puts `model.safetensors`
beside `config.json`, `runtime/`, and the tokenizer — the layout the loader
expects.)

Or load it directly in Python:

```python
import sys
sys.path.insert(0, '<repo>/runtime')
from vision_artifact import load_vl_model
model, processor, config = load_vl_model('<repo>')
```

## Do not edit `runtime/*.py`

`upstream-demo/scripts/bonsai2-runtime.sha256` pins the SHA-256 of all four
runtime files, and the driver **refuses to import anything that does not match**:

| File | sha256 (this repo matches exactly) |
| --- | --- |
| `artifact.py` | `5279718d7671bd799e866f53099e82b0260117fec811f83011ba47a0abc7943e` |
| `codec.py` | `7f7fd67637a7d9363eab8ebf7db59771830b690330ffef772379a0169ddb9608` |
| `runtime.py` | `30ad3905775040a8167360a009168b9ede1436cb02dc43e9e743432482eafbbf` |
| `vision_artifact.py` | `624e78d1fc7a0ddbaa637121ee823209c525b8e89f35fbc68d6d2f3f3fcfd87d` |

"Fixing" one to force a load gets your pack rejected by the official driver.

## Do not edit `config.json` either

`config.json` is shipped from the pack, it is correct, and it is the one file
that decides whether the Hadamard transform runs at all. Two fields matter:

| Field | Value | Who consumes it |
| --- | --- | --- |
| `model_type` | `prism_hadamard_qwen35` | the pack's own loaders; they **refuse** anything else |
| `base_model_type` | `qwen3_5` | `chat_config()`, which swaps it into `model_type` at load time |

That swap is deliberate (`runtime/vision_artifact.py:98-100`) — mlx-vlm's prompt
helper keys off `model_type` and needs the base architecture name there. So both
values are correct simultaneously and neither needs "fixing".

**An agent has already done this by hand.** On 2026-09-18 a Mac agent found
`model_type: "qwen3_5"` in a working copy, rewrote the file to
`prism_hadamard_qwen35` with a `json.load` / `json.dump` one-liner, printed the
new value, and called it fixed. Whether the field was ever genuinely wrong is
unknowable after the fact — the file is not recoverable from that session. What
is knowable is that editing it was the wrong move either way:

- If `model_type` really was `qwen3_5`, the file had been edited by something
  earlier, and the answer is `git checkout -- config.json`, not another patch.
- If it was already `prism_hadamard_qwen35`, the edit was a no-op on a tracked
  file that now reads as dirty in `git status`.

Either way, check `git status` after any failed load. A modified `config.json` is
the first thing to suspect and the first thing to revert:

```bash
git status --short          # config.json modified? revert it:
git checkout -- config.json
python3 -c "import json;c=json.load(open('config.json'));print(c['model_type'],c['base_model_type'])"
# want: prism_hadamard_qwen35 qwen3_5
```

The failure mode this protects against is the worst one in this repo: a pack
whose `model_type` is `qwen3_5` loads **successfully** under stock `mlx_lm` /
`mlx_vlm`, skips the rotation, and answers fluently and wrongly.

---

# 4. Reference: tuning for 18 GB

Context length is auto-selected: **`-c 16384`** on an 18 GB machine.

| Variable | Effect |
| --- | --- |
| `BONSAI_CTX` | Override context length — first thing to lower |
| `BONSAI_KV4=1` | 4-bit KV cache; big saving on long contexts |
| `BONSAI_MMPROJ_CPU=1` | Keep the vision projector on CPU |
| `BONSAI_NGL` | GPU layers (default 99). Lower to offload to CPU |

Also: `BONSAI_HOST` (bind address; defaults to `127.0.0.1` — set `0.0.0.0` for
LAN access, and note `BONSAI_ALLOW_REMOTE`), **`PORT`** — *not* `BONSAI_PORT`,
which does not exist; the port override is the plain `PORT`, default `8080` —
`BONSAI_GGUF`, `BONSAI_MODEL`, `BONSAI_FAMILY`, `BONSAI_BACKEND`,
`BONSAI_IMAGE_MAX_TOKENS`, `BONSAI_MMPROJ`, `BONSAI_SKIP_GGUF`, `BONSAI_SKIP_MLX`,
`BONSAI_OPENWEBUI`, `BONSAI_MLX_VLM`, `BONSAI_MLX_VISION`, `BONSAI_SPECULATIVE`
(off; **not recommended on Apple Silicon**), `BONSAI_SPEC_NMAX`,
`GGML_METAL_TENSOR_DISABLE=1` (**M5 only**).

Two variables the scripts read but the docs omit: `BONSAI_FORCE_G64` and
`BONSAI_SKIP_RUNTIME_CHECK`. Full list in
[`upstream-demo/environment_variables.md`](upstream-demo/environment_variables.md),
which is upstream's and is the authority.

**Sampling** (`generation_config.json`): thinking `temp 1.0 / top_p 0.95 /
top_k 20`; instruct `temp 0.7 / top_p 0.80 / top_k 20 / presence_penalty 1.5`.
Reasoning effort defaults to `xhigh`; use `medium` for speed, `low` is unsupported.

---

# 5. Reference: benchmarks

**Caveat first: these are the *previous* Ternary-Bonsai 27B family, not Bonsai 2
27B.** No Bonsai 2 27B Apple Silicon numbers are published. Expect the same order
of magnitude, not these exact figures.

`pp512` prompt processing, `tg128` generation (tok/s):

| Machine | Backend | pp512 | tg128 |
| --- | --- | ---: | ---: |
| **M3 Pro 18 GB** | Metal | **78.6** | **12.6** |
| M1 Pro 32 GB | MLX | 48.5 | 9.53 |
| M4 24 GB | MLX | 65.2 | 12.7 |
| M4 Pro 64 GB | Metal / MLX | 116 / 120 | 19.0 / 24.8 |
| M5 Pro 64 GB | Metal / MLX | 130 / 466 | 26.5 / 29.5 |
| M5 Max 48 GB | Metal | 816 | 45.8 |

No M2 entries. Your closest real number is the M3 Pro row: **~12.6 tok/s**.

Quality (model card, H100/vLLM — the weights, not Apple Silicon):
coding 89.42 vs 89.07 baseline; math 96.57 vs 97.06; instruction following 82.66
vs 81.25; tool calling 74.92 vs 76.74; knowledge/reasoning 79.86 vs 85.55; vision
66.19 vs 71.36; **overall 84.78 vs 86.32**.

---

# 6. Reference: symptom → cause → fix

| Symptom | Cause | Fix |
| --- | --- | --- |
| `Unsupported packed model schema` | Called `artifact.load_model` on a schema-2 pack | Use `vision_artifact.load_vl_model` |
| `mlx_lm.server` refuses / gibberish | Correct behavior — no rotation transform | Use the GGUF path (§1) |
| Gibberish from GGUF, **no warning** | Stock llama.cpp + `Q2_0` — fails unsafely | Use the PrismML fork binaries |
| `this file matches the legacy Prism Q2_0 layout...` | Deprecated GGUF | Use the `PQ2_0` or `_g64` file |
| Binary killed on first run | Gatekeeper quarantine | Re-run `./setup.sh` |
| Driver refuses to import the runtime | A `runtime/*.py` was edited | Restore the pinned file (§3) |
| `xcrun metal` not found | No Xcode CLT | `xcode-select --install` |
| Port 8080 in use | Another server running | `PORT=8081 ./scripts/start_llama_server.sh` |
| Prompted for a Hugging Face token | Upstream prompt; both repos are public | **Press Enter.** No token needed — see Step 2 |
| Downloading from Hugging Face | Expected — the GGUF exists only on HF | Let it run; ~7.8 GB, anonymous |
| `setup.sh` dies creating the venv | `uv` fetching a managed CPython 3.11 | `UV_PYTHON=python3 ./setup.sh` |
| Want **no** Hugging Face contact | Supported: point at a local GGUF | `BONSAI_GGUF=… BONSAI_MMPROJ=… ./scripts/start_llama_server.sh` — Step 3-alt |
| It refetches a second 8.6 GB MLX copy | Step 3 fetches both halves | `BONSAI_SKIP_MLX=1 sh scripts/download_models.sh` |
| Agent writing a long Python loader | It missed the shipped runner | `.venv-vlm/bin/python scripts/mlx_generate_bonsai2.py --model .. -p "…"` |
| Agent demands a GGUF for the MLX path | Wrong artifact — MLX needs no GGUF | `./assemble.sh` once, then the one-liner above |
| `setup.sh` starts a huge download | `setup.sh:274` calls `download_models.sh` | Skip `setup.sh` — use Step 2-alt's two commands |
| `setup.sh` asks for a token then **fails to connect** | It is trying to download the GGUF from Hugging Face | **Not needed for MLX.** Skip `setup.sh` entirely — Step 2-alt |

---

# 7. License

Apache 2.0, inherited from `Qwen/Qwen3.8-27B`. Weights are Prism ML's.
[`UPSTREAM_MODEL_CARD.md`](UPSTREAM_MODEL_CARD.md) is upstream's card, verbatim.
The upstream demo is vendored at [`upstream-demo/`](upstream-demo/).
