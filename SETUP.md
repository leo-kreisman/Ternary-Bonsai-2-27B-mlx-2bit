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

Takes a few minutes. It needs Xcode Command Line Tools (`xcode-select --install`
if you don't have them).

## Step 3 — Get the model

```bash
sh scripts/download_models.sh
```

Downloads into `models/bonsai2-gguf/27B/`:

| File | Size | Why |
| --- | ---: | --- |
| `*-PQ2_0.gguf` | ~7.2 GB | the model |
| `*mmproj-Q8_0.gguf` | ~0.63 GB | vision (images) |

## Step 4 — Serve it

```bash
./scripts/start_llama_server.sh
```

- OpenAI-compatible at **`http://localhost:8080/v1/chat/completions`**
- Flags it sets for you: `-ngl 99 -fa on -c 16384 --temp 1.0 --top-p 0.95
  --top-k 20 --jinja --mmproj ... --image-max-tokens 1024`
- `-c 16384` is chosen automatically for an 18 GB machine

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

**That is the whole path.** Everything below is either the refutation or
reference material.

---

# 2. THE REFUTATION

Seven wrong conclusions this model reliably produces. If you or an agent reached
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
| Served? | **No** — one-shot only | **Yes** — port 8080 |
| Driver | `scripts/run_mlx.sh` | `scripts/run_llama.sh` |
| Fork needed | **No** — stock MLX + `mlx-vlm` | **Yes** — `PrismML-Eng/llama.cpp` |

The MLX pack is **one-shot only**. If you want a server, it is the GGUF path,
full stop. **"One-shot only" means no server — it does not mean MLX is
unsupported.** It is an MLX model and `run_mlx.sh` runs it on stock MLX.

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

---

# 7. License

Apache 2.0, inherited from `Qwen/Qwen3.8-27B`. Weights are Prism ML's.
[`UPSTREAM_MODEL_CARD.md`](UPSTREAM_MODEL_CARD.md) is upstream's card, verbatim.
The upstream demo is vendored at [`upstream-demo/`](upstream-demo/).
