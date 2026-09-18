# Running Ternary Bonsai 2 27B on macOS (Apple Silicon)

This is the practical setup guide: what actually runs, what silently produces
garbage, and the exact commands. Written for an 18 GB M3 Pro, but the paths are
the same on any Apple Silicon Mac.

**Everything here comes from the upstream project
[PrismML-Eng/Bonsai-demo](https://github.com/PrismML-Eng/Bonsai-demo)** — that
repo is the source of truth and carries `setup.sh`, which does the whole install
for you. This document exists so you don't have to reverse-engineer it, and so
an agent can follow one authoritative page instead of guessing.

---

## 1. What actually works

| What you want | Path | Status |
| --- | --- | --- |
| **OpenAI-compatible server** | llama.cpp fork + GGUF | ✅ Supported |
| **One-off prompt** (best quality, fastest) | llama.cpp fork + GGUF | ✅ Supported |
| **One-off prompt via MLX** | This MLX pack + the demo's driver | ✅ Supported |
| Vision / images | Either path | ✅ Supported |
| **A served MLX model** | `mlx_lm.server` | ❌ **Refuses by design** |

## 2. Why `mlx_lm.server` will not work — this is not your setup being broken

If an agent or a tool tells you `mlx_lm.server` cannot load these weights
cleanly, **it is correct and you should not try to force it.**

The reason is structural. Bonsai 2 stores its weights in a **blockwise
Hadamard-rotated basis**. Every projection was rotated before ternary
quantization, and the runtime must apply the matching transform to activations
as it goes. A loader that doesn't know about the rotation doesn't error — it
just produces nonsense, because the arithmetic is wrong in a way that is still
numerically valid.

The consequences:

- **`mlx_lm.load` / `mlx_lm.server`** apply no such transform. Refuse them.
- Upstream agrees: the demo's own `scripts/start_mlx_server.sh` **hard-refuses
  `bonsai2`** and tells you to use llama.cpp instead. This is upstream's
  designed behavior, not a bug in your machine.
- **Stock `llama.cpp` is worse.** For the Bonsai 2 GGUF bands, `PTQ1_0` and
  `PQ2_0` fail safely (their ggml type ids sit past upstream's `GGML_TYPE_COUNT`,
  so stock refuses them outright). But the `Q2_0` band **does not fail safely** —
  mainline already knows the `Q2_0` type and the `qwen35` architecture, so it
  loads the file without a warning and emits gibberish. That's why the `Q2_0`
  band is kept out of the main model repo and named
  `...-Q2_0-prism-fork-required.gguf`.

**Bottom line: use the PrismML fork binaries. Every supported path uses them.**

---

## 3. Path A — llama.cpp + GGUF (recommended; the only server path)

This is what you want on an 18 GB M3 Pro.

### Install

**The demo is already in this repository**, at [`upstream-demo/`](upstream-demo/)
— a verbatim snapshot of upstream `c398c6e` (see
[`upstream-demo/VENDORED-FROM.md`](upstream-demo/VENDORED-FROM.md)). There is
nothing to clone:

```bash
cd upstream-demo
./setup.sh
```

If you would rather track the live upstream repo — it does move — clone it
instead:

```bash
git clone https://github.com/PrismML-Eng/Bonsai-demo.git
cd Bonsai-demo
./setup.sh
```

All the `./scripts/...` commands in this section then run from whichever of the
two directories you used.

On macOS, `setup.sh` does this:

1. Checks `xcode-select -p` (Xcode Command Line Tools). Nothing else is needed —
   no Homebrew, no `build-essential`.
2. Installs **`uv`** (>= 0.7.0) from `https://astral.sh/uv/install.sh` if it is
   missing. The project uses `uv`, not `pip`.
3. Creates a virtualenv with **Python 3.11** (`uv venv --python 3.11`) and runs
   `uv sync` to install `huggingface-hub`, `cmake`, `ninja`, `setuptools`.
4. **Downloads prebuilt binaries — it does not build llama.cpp from source.**
   It fetches `llama-${RELEASE_TAG}-bin-macos-arm64.tar.gz` from
   `PrismML-Eng/llama.cpp` release `prism-b10683-d8f26ee` into `bin/mac/`, then
   clears the Gatekeeper quarantine attribute and ad-hoc codesigns them. This
   matters: without that step macOS kills the binaries on first run.

A source build is available but opt-in (`scripts/build_mac.sh` clones
`https://github.com/PrismML-Eng/llama.cpp` at branch **`prism`**). You almost
certainly do not need it.

If you want the MLX environment too, `setup.sh` on Apple Silicon also checks
`xcrun metal --version` (it aborts if missing), clones
`PrismML-Eng/mlx` at branch `prism`, and installs it with
`uv pip install -e mlx/ --no-build-isolation`, plus a separate `.venv-vlm`.

### Get the model

```bash
sh scripts/download_models.sh
```

For the 27B on Apple Silicon this pulls from
**`prism-ml/Ternary-Bonsai-2-27B-gguf`**, matching `*-PQ2_0.gguf` plus
`*mmproj-Q8_0.gguf`, into `models/bonsai2-gguf/27B/`.

| Band | bits/weight | Size | Notes |
| --- | ---: | ---: | --- |
| `PTQ1_0` | 1.75 | ~5.9 GB | smallest |
| `PQ2_0` | 2.13 | ~7.2 GB | **what the demo downloads**; faster prompt processing |
| `mmproj` (vision) | — | ~0.63 GB | needed for images |

There is no "works everywhere" band for Bonsai 2. All of them need the fork.

### Serve it (OpenAI-compatible)

```bash
./scripts/start_llama_server.sh
```

- Host `127.0.0.1`, port **8080** (override with `BONSAI_HOST` / `PORT`)
- Endpoint: `http://localhost:8080/v1/chat/completions`
- Binary: `bin/mac/llama-server`

The flags it uses for `bonsai2`:

```
-m $MODEL --host $HOST --port $PORT -ngl 99 -fa on -c $CTX \
  --temp 1.0 --top-p 0.95 --top-k 20 --jinja \
  --mmproj $MMPROJ --image-max-tokens 1024 --webui-config-file ...
```

Extra flags pass through, e.g.:

```bash
./scripts/start_llama_server.sh --reasoning-budget 2048
```

It checks for a port already in use with
`curl -s --max-time 2 "http://localhost:$PORT/health"`.

> There is an MLX server script on port 8081, but it **hard-refuses `bonsai2`**.
> Don't go down that road — see §2.

### One-off prompt

```bash
./scripts/run_llama.sh -p "What is the capital of France?"
```

---

## 4. Path B — the MLX pack (this repository)

**One-shot generation only. Not servable.**

### What this repository is

This repo mirrors the MLX pack `prism-ml/Ternary-Bonsai-2-27B-mlx-2bit` — a
single 8.60 GB `model.safetensors` split into five parts, reassembled by
`./assemble.sh` (see [`README.md`](README.md)). It is **not** the same artifact
as the GGUF in Path A, and it is **not** what the demo's server path uses.

### Load it correctly

```python
import sys
sys.path.insert(0, '/path/to/Ternary-Bonsai-2-27B-mlx-2bit/runtime')
from vision_artifact import load_vl_model

model, processor, config = load_vl_model('/path/to/Ternary-Bonsai-2-27B-mlx-2bit')
```

**Do not use `artifact.load_model`.** This trips people up constantly, because
the pack's own `PACK-RUNTIME.md` tells you to use it. That file is stale:

- `runtime/artifact.py` is the **older, text-only** loader. It rejects any config
  that is not `schema_version == 1` (guard at `artifact.py:81-85`).
- This pack is **`schema_version: 2`**, so `artifact.load_model` raises
  `Unsupported packed model schema` immediately — before reading a single tensor.
- `runtime/vision_artifact.py` is the loader that matches this pack. It has **no
  schema-version check**, and it reads the schema-2 fields (`hadamard_config`,
  `tensor_namespace`, `gdn_activation_layout`, `components`).

You can confirm the mismatch yourself in one command:

```bash
python3 -c "import json;print(json.load(open('config.json'))['schema_version'])"   # 2
grep -n 'schema_version' runtime/artifact.py                                       # requires 1
```

### Vision is included

The pack's `components` are:

```json
{"text": true, "vision": true, "mtp": false}
```

So **vision works** — `load_vl_model` returns a `processor` built as a
`Qwen3VLProcessor`, deliberately avoiding `AutoProcessor` and torchvision so the
whole path stays on numpy and Pillow. MTP (multi-token prediction) is not
included.

`PACK-RUNTIME.md`'s line "Vision and MTP are not included" describes the
text-only `artifact.py` path. It is half right, and misleading about which half
applies to this pack.

### Run it

Use the demo's driver, which handles the runtime pinning for you:

```bash
cd upstream-demo
./scripts/run_mlx.sh -p "What is the capital of France?"
```

It needs the `.venv-vlm` environment, and runs:

```
.venv-vlm/bin/python scripts/mlx_generate_bonsai2.py \
  --model models/Ternary-Bonsai-2-27B-mlx-2bit -p "..."
```

**Pointing it at this repository's copy.** The driver defaults to
`models/Ternary-Bonsai-2-27B-mlx-2bit/` inside the demo directory. Your
reassembled pack is one level up, in this repo's root. Either:

- **Let the demo fetch its own copy** — `sh scripts/download_models.sh` pulls the
  same pack from Hugging Face into `upstream-demo/models/` unless
  `BONSAI_SKIP_MLX` is set. Simplest, at the cost of a second 8.6 GB on disk.
- **Point `--model` at this repo's reassembled pack**, avoiding the duplicate:

  ```bash
  cd upstream-demo
  .venv-vlm/bin/python scripts/mlx_generate_bonsai2.py \
    --model ../ -p "What is the capital of France?"
  ```

  This works because `./assemble.sh` in the repo root produces
  `model.safetensors` alongside `config.json`, `runtime/`, and the tokenizer —
  exactly the directory layout the loader expects. Run `./assemble.sh` in the
  repo root first if you haven't.

Either way, the four runtime files must be the pinned ones (§4, "Do not edit the
runtime files").

### Dependencies

Install `runtime/requirements.txt` on Apple Silicon. The pins matter:

```
mlx==0.32.0
mlx-lm==0.31.3
numpy>=2.0
tokenizers>=0.21
jinja2>=3.1
mlx-vlm==0.6.3
transformers==5.5.0
pillow>=10.0
```

### Do not edit the runtime files

`Bonsai-demo` pins the SHA-256 of all four runtime files in
`scripts/bonsai2-runtime.sha256`, and its generator **refuses to import anything
that does not match**:

| File | sha256 (matches this repo exactly) |
| --- | --- |
| `runtime/artifact.py` | `5279718d7671bd799e866f53099e82b0260117fec811f83011ba47a0abc7943e` |
| `runtime/codec.py` | `7f7fd67637a7d9363eab8ebf7db59771830b690330ffef772379a0169ddb9608` |
| `runtime/runtime.py` | `30ad3905775040a8167360a009168b9ede1436cb02dc43e9e743432482eafbbf` |
| `runtime/vision_artifact.py` | `624e78d1fc7a0ddbaa637121ee823209c525b8e89f35fbc68d6d2f3f3fcfd87d` |

Verified byte-identical to the demo's reviewed revision. If you "fix" one of
these files to make something load, the official driver will reject your pack.

---

## 5. Benchmark numbers

**Read the caveat first.** These are **community benchmarks for the *previous*
Ternary-Bonsai 27B family, not for Bonsai 2 27B.** No Bonsai 2 27B Apple Silicon
numbers have been published. Treat them as a rough expectation, not a spec.

`pp512` = prompt processing (tok/s), `tg128` = generation (tok/s).

| Machine | Backend | pp512 | tg128 | Quant |
| --- | --- | ---: | ---: | --- |
| **M3 Pro 18 GB** | Metal | **78.6** | **12.6** | `Q2_0` |
| M1 Pro 32 GB | MLX | 48.5 | 9.53 (10.63 greedy) | — |
| M4 24 GB | MLX | 65.2 | 12.7 | — |
| M4 Pro 64 GB | Metal | 116 | 19.0 | — |
| M4 Pro 64 GB | MLX | 120 | 24.8 | — |
| M5 Pro 64 GB | Metal | 130 | 26.5 | — |
| M5 Pro 64 GB | MLX | 466 | 29.5 | — |
| M5 Max 48 GB | Metal | 816 | 45.8 | `PQ2_0` |
| M5 Max 48 GB | Metal | 796 | 63.9 | 1-bit |

No M2 entries exist. The upstream MLX figures reported for the pre-rotation
build (M5 Max 47.0, M5 Pro 28.7, M4 Pro 18.0 tok/s) are in the same ballpark as
the Metal column above.

**Your machine specifically:** the community notes for the prior-generation
family say *"All four Ternary-Bonsai sizes fit comfortably in 18 GB."* Your
closest data point is the M3 Pro row: **~12.6 tok/s generation**. For Bonsai 2
27B at 8.6 GB (MLX) or ~7.2 GB + 0.63 GB (GGUF `PQ2_0` + mmproj), expect the same
order of magnitude. Note this is well below the M4 Pro, because generation here
is memory-bandwidth-bound and the M3 Pro has less of it.

### Quality (from the model card, thinking mode, H100/vLLM — measures the weights, not Apple Silicon)

| Category | FP16 baseline | Bonsai 2 27B |
| --- | ---: | ---: |
| Coding | 89.07 | **89.42** |
| Math | 97.06 | 96.57 |
| Instruction following | 81.25 | **82.66** |
| Agentic / tool calling | 76.74 | 74.92 |
| Knowledge & reasoning | 85.55 | 79.86 |
| Vision | 71.36 | 66.19 |
| **Overall (14 benchmarks)** | **86.32** | **84.78** |

---

## 6. Tuning for 18 GB

The demo picks context length from detected memory. For an 18 GB machine it
selects **`-c 16384`** (the 16384-token tier, for machines ≤23 GB).

Knobs that matter when memory is tight:

| Variable | Effect |
| --- | --- |
| `BONSAI_CTX` | Override context length. First thing to lower. |
| `BONSAI_KV4=1` | 4-bit KV cache — big memory saving on long contexts. |
| `BONSAI_MMPROJ_CPU=1` | Keeps the vision projector on CPU, off the GPU. |
| `BONSAI_NGL` | GPU layers. Default `99` (all). Lower to offload to CPU. |

Other variables, from `environment_variables.md`: `BONSAI_FAMILY`, `BONSAI_MODEL`,
`BONSAI_BACKEND`, `BONSAI_HOST`, `BONSAI_PORT`, `BONSAI_IMAGE_MAX_TOKENS`,
`BONSAI_SKIP_GGUF`, `BONSAI_SKIP_MLX`, `BONSAI_OPENWEBUI`, `BONSAI_MLX_VLM`,
`BONSAI_SPECULATIVE` (off by default; **not recommended on Apple Silicon**), and
`GGML_METAL_TENSOR_DISABLE=1` (**M5 only**).

### Sampling

Defaults come from `generation_config.json`:

- **Thinking:** `temperature=1.0`, `top_p=0.95`, `top_k=20`
- **Instruct / non-thinking:** `temperature=0.7`, `top_p=0.80`, `top_k=20`, `presence_penalty=1.5`

Reasoning effort defaults to `xhigh`. Use `medium` for shorter responses and a
better speed/accuracy balance. `low` is not supported and behaves like `xhigh`.

---

## 7. Troubleshooting

| Symptom | Cause | Fix |
| --- | --- | --- |
| `Unsupported packed model schema` | You called `artifact.load_model` on a schema-2 pack | Use `vision_artifact.load_vl_model` (§4) |
| `This pack carries no vision tower; use artifact.load_model instead` | Pack genuinely has no vision | It does; you're on the wrong loader or wrong directory |
| `mlx_lm.server` won't load it | Correct behavior | Use Path A (§2) |
| `mlx_lm.server` loads it and output is gibberish | The rotation transform was skipped | Same — it must not be loaded this way |
| `this file matches the legacy Prism Q2_0 layout (group size 128 stored as ggml type id 42)` | Deprecated GGUF | Download the `PQ2_0` or `_g64` file |
| Gibberish from GGUF with **no** warning | You're on stock llama.cpp with a `Q2_0` band — it fails *unsafely* | Use the PrismML fork binaries |
| Binary killed on first run / "cannot be opened" | Gatekeeper quarantine | Re-run `setup.sh`; it clears quarantine and ad-hoc codesigns |
| Runtime hash mismatch / generator refuses to import | A file in `runtime/` was edited | Restore the pinned file (§4) |
| `xcrun metal` not found | Xcode Command Line Tools missing | `xcode-select --install` |

---

## 8. Licensing

Apache 2.0, inherited from `Qwen/Qwen3.8-27B`. Weights are Prism ML's. The
upstream model card is preserved verbatim in this repo as
[`UPSTREAM_MODEL_CARD.md`](UPSTREAM_MODEL_CARD.md); upstream's loader notes are
in [`PACK-RUNTIME.md`](PACK-RUNTIME.md) — **read the caveat in §4 about that file
before following it.**
