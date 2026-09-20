---
base_model: Qwen/Qwen3.8-27B
library_name: mlx
tags:
  - mlx
  - ternary
  - 2-bit
  - hybrid-attention
  - bonsai
  - prismml
license: apache-2.0
---

# Ternary-Bonsai-2-27B-mlx-2bit

Ternary weights for Bonsai 2 27B, shipped **two ways** from GitHub Releases so
neither path needs Hugging Face access.

| Artifact | Upstream | Runtime | Get it |
| --- | --- | --- | --- |
| MLX pack, 8.60 GB | [`prism-ml/Ternary-Bonsai-2-27B-mlx-2bit`](https://huggingface.co/prism-ml/Ternary-Bonsai-2-27B-mlx-2bit) | MLX / `mlx-vlm` | `./assemble.sh` |
| GGUF, `PTQ1_0` 5.54 GiB + `PQ2_0` 6.71 GiB, both projectors | [`prism-ml/Ternary-Bonsai-2-27B-gguf`](https://huggingface.co/prism-ml/Ternary-Bonsai-2-27B-gguf) | llama.cpp | `./assemble-gguf.sh` |

Both are the same model in different containers. **The GGUF path is the shorter
one** — no Python virtualenv, no compiler, no Hugging Face, just an 11 MB
prebuilt binary plus the weights:

```bash
git clone https://github.com/leo-kreisman/Ternary-Bonsai-2-27B-mlx-2bit.git
cd Ternary-Bonsai-2-27B-mlx-2bit
./serve-gguf.sh          # fetch, verify, smoke-test, serve on :8080
```

> **This is a mirror.** The canonical copies live upstream on Hugging Face (links
> above). The upstream model card is preserved verbatim in this repo as
> [`UPSTREAM_MODEL_CARD.md`](UPSTREAM_MODEL_CARD.md) — read it for the full
> methodology and benchmark detail. This repository only redistributes the
> weights from GitHub Releases.

**Want to actually run it? Go to [`SETUP.md`](SETUP.md).** §1 is the path —
copy-paste, one route, no decisions. §2 is the refutation: six wrong conclusions
this model reliably produces, including that `mlx_lm.server` can serve it and
that the MLX pack runs in llama.cpp. Both are false.

Agents: read [`AGENTS.md`](AGENTS.md) first.

## Read this before you try to load it

**Yes, this is an MLX model, and it runs on stock MLX.** `library_name` is `mlx`,
the weights are MLX safetensors, and upstream's `run_mlx.sh` drives it on stock
MLX through the `mlx-vlm` venv. You do **not** need the PrismML `mlx` fork for
this pack — that fork is for the 1-bit family, not this one. What follows is two
narrow exceptions, not a claim that MLX is unsupported.

**1. The stock `mlx_lm` loaders will not run it.** The weights are stored in a
rotated basis: every matrix was transformed by a blockwise Hadamard rotation
before the ternary assignment, and the runtime must apply the matching transform
to activations. Upstream states it plainly — the packed model declares its
rotation as metadata, so *"a runtime either applies the matching transform or
refuses to load the file."* The runner that does this is the **bundled runtime**
in [`runtime/`](runtime/), used by `run_mlx.sh`.

The ordinary `mlx_lm.load("...")` snippet will not work. That is a statement
about the *loader*, not about MLX.

**2. Use `vision_artifact.load_vl_model`, NOT `artifact.load_model`.**
[`PACK-RUNTIME.md`](PACK-RUNTIME.md) tells you to call `artifact.load_model`.
**That will fail on this pack.** `artifact.py` is the older text-only loader and
it rejects any config that is not `schema_version 1`; this pack is
`schema_version 2`, so it raises `Unsupported packed model schema` before
touching a single tensor. The loader that matches this pack is
`vision_artifact.load_vl_model`, which has no schema-version check and reads the
schema-2 fields (`hadamard_config`, `tensor_namespace`, `gdn_activation_layout`,
`components`).

The pack's `components` are `{"text": true, "vision": true, "mtp": false}` — so
**vision is included** and MTP is not. `PACK-RUNTIME.md`'s "Vision and MTP are
not included" describes the text-only path, not this pack.

> **The upstream source of truth for running this model is
> [PrismML-Eng/Bonsai-demo](https://github.com/PrismML-Eng/Bonsai-demo).** It
> carries the tested setup and builds the right MLX runtime. Where anything here
> disagrees with it, it is right.

### Loading with the bundled runtime

```python
import sys
sys.path.insert(0, '/path/to/Ternary-Bonsai-2-27B-mlx-2bit/runtime')
from vision_artifact import load_vl_model

model, processor, config = load_vl_model('/path/to/Ternary-Bonsai-2-27B-mlx-2bit')
```

Note the three return values: `processor` is a built `Qwen3VLProcessor`, so the
vision path works without `AutoProcessor` and without torch.

**`mlx_lm.server` will not serve this model, and neither will `mlx_lm.load`.**
This is not a limitation of your setup, and it does **not** mean MLX is
unsupported — upstream's `scripts/start_mlx_server.sh` explicitly refuses
`bonsai2` because those server entry points apply no rotation transform. The
pack is an MLX model; what is missing is an MLX *server* for it. One-shot MLX
works today (`./scripts/run_mlx.sh -p "..."`), and the supported server path is
llama.cpp. See [`SETUP.md`](SETUP.md) §1 for the server, §2 for this exact
confusion.

Install `runtime/requirements.txt` on Apple Silicon first. It pins exact
versions, and they matter:

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

## Getting the weights

The config, tokenizer, and runtime files are committed in this repository. The
single weight file `model.safetensors` is **8,595,477,990 bytes (~8.60 GB)**,
well over GitHub's 2 GiB per-file cap for both Git LFS and Release assets, so it
ships as **five byte-range parts**. Four parts would be 2.149 GB each and would
fail; five are ~1.72 GB each. Concatenating them reproduces the original file
byte for byte.

```bash
git clone https://github.com/leo-kreisman/Ternary-Bonsai-2-27B-mlx-2bit.git
cd Ternary-Bonsai-2-27B-mlx-2bit
./assemble.sh
```

The script downloads the five parts, verifies each against its published
sha256, concatenates them, and checks the reassembled file against the hash
from Hugging Face. When it finishes, the checkout is a loadable model
directory. It is resumable — re-running skips parts already downloaded and
verified, and re-fetches any part that fails its checksum.

### Parts

Each part is 1,719,095,598 bytes (1.60 GiB).

| Part | sha256 |
| --- | --- |
| `model.safetensors.part-0` | `7f9edef6d4c9cbaaab778f6089c388d5e910f805a549093609439fd0e42cd99b` |
| `model.safetensors.part-1` | `a46d1a47b762961a094d928a37c3cacba7e2d90c479a3eccf2b590ef9fee67b1` |
| `model.safetensors.part-2` | `aef84cf964cd5a4f3a0f69cfcafe664d52b2d92cd28a6873d12f56c1781d1ffc` |
| `model.safetensors.part-3` | `e6f3add026a192849905dc582e446ed1e17bc89c7fef003bc676117bcabcedac` |
| `model.safetensors.part-4` | `2464e72fedec333ad12c362d4e33f197cb7e63cc478800c3338610ddb026490d` |

Assembled whole-file hash (identical to Hugging Face):

```
130de5925082c168b7866b2e91b52e44abbafc99017e3ca352b77b5b55a269ed  model.safetensors
```

### Verifying the parts yourself

`MANIFEST.sha256` is a standard checksum file, so `shasum -c` can check every
part in one step. From the repository root, after `assemble.sh` has downloaded
them into `.parts/`:

```bash
curl -fLO https://github.com/leo-kreisman/Ternary-Bonsai-2-27B-mlx-2bit/releases/download/weights-v1/MANIFEST.sha256
grep 'safetensors\.part-' MANIFEST.sha256 > parts.sha256
(cd .parts && shasum -a 256 -c ../parts.sha256)
```

A good download prints `OK` for all five lines.

> **If a part fails its checksum, the download is wrong — not the hash.** Delete
> the file and re-fetch it; `assemble.sh` does exactly this on its own:
>
> ```bash
> rm -f .parts/model.safetensors.part-2
> ./assemble.sh
> ```
>
> Do **not** edit the expected hashes in `assemble.sh` to match a download. Those
> values pin the published bytes. Changing one to accept a corrupt part converts
> a loud, catchable failure into a model that loads and silently produces wrong
> output.

## Getting the GGUF instead

The MLX pack above is one artifact. The GGUF is a **different container** for the
same model, run by a **different runtime** — llama.cpp, not MLX. Neither feeds
the other. If you want a server, this is the shorter path.

Release tag `gguf-v1` carries both servable bands and both vision projectors:

| Asset | Bytes | Role |
| --- | ---: | --- |
| `Ternary-Bonsai-2-27B-PTQ1_0.gguf.part-0/1/2` | 1,982,216,310 ×3 | the smaller band — 5,946,648,928 bytes, split 3 ways to stay under the 2 GiB cap |
| `Ternary-Bonsai-2-27B-PQ2_0.gguf.part-0/1/2/3` | 1,801,542,232 ×4 | the higher-quality band — 7,206,168,928 bytes, split 4 ways |
| `Ternary-Bonsai-2-27B-mmproj-Q8_0.gguf` | 629,246,976 | the tested vision projector, under the cap, shipped whole |
| `Ternary-Bonsai-2-27B-mmproj-BF16.gguf` | 931,145,856 | the BF16 projector, shipped whole, placed one directory over |

```bash
./serve-gguf.sh            # fetch, verify, smoke-test, serve on :8080
./serve-gguf.sh --check    # the same, but stop before serving
./assemble-gguf.sh         # just the weights, resumable
./assemble-gguf.sh --verify
```

The model and the tested Q8_0 projector land in
`upstream-demo/models/bonsai2-gguf/27B/`, which is the directory the demo's own
scripts already look in, so no environment variables are involved.
`mmproj-BF16` lands in `27B-projectors/` beside it instead — deliberately, not by
oversight: `start_llama_server.sh:72` picks its projector with a first-match glob,
and `mmproj-BF16` sorts before `mmproj-Q8_0`, so putting it in the model
directory would silently switch every run to a projector the smoke test never
touches. Point `BONSAI_MMPROJ` at it to use it.

> ### ⚠️ You need the Prism fork of llama.cpp — for both bands
>
> `PTQ1_0` and `PQ2_0` both use ggml type ids past upstream's `GGML_TYPE_COUNT`,
> so **mainline llama.cpp refuses them outright**. That is the safe failure.
> There is no stock-llama.cpp band in this release. Do **not** reach for the
> `Q2_0` band instead: mainline knows that type id *and* the `qwen35`
> architecture, so it loads the file with no complaint and emits gibberish.
> `serve-gguf.sh` and `download_binaries.sh` both fetch the pinned Prism build.

Whole-file hashes, identical to Hugging Face:

```
53107f530aa52eb00912263ab1ee29bd199261c87cd7b4ad4ca1318c1fe33ee3  Ternary-Bonsai-2-27B-PTQ1_0.gguf
3907dc1658db1f78a9826bf8d5bcb8dc65db0d466388937af57f2294fae62ec1  Ternary-Bonsai-2-27B-PQ2_0.gguf
6807ede61d570bb86ba34b756a0fa109edc33668604de867c6ea6d8f1d631903  Ternary-Bonsai-2-27B-mmproj-Q8_0.gguf
e287342d92332fa3577ed1d42e921dac9370c08da58ba9337fa450f6cc76cfd7  Ternary-Bonsai-2-27B-mmproj-BF16.gguf
```

The same warning as above applies: a part that fails its checksum is a bad
download, not a wrong hash. Do not edit the expected hashes to match it.

`PTQ1_0` (1.75 bpw, 5.54 GiB) is the **smaller** of the two servable GGUF bands
and is the one `serve-gguf.sh` serves by default. `PQ2_0` (2-bit product quant,
6.71 GiB) is the higher-quality band and is mirrored here too; point `BONSAI_GGUF`
at it to serve that one instead. Both were checked against the sha256 Hugging Face
publishes, byte for byte — but only `PTQ1_0` has been through the known-answer run
in this repo, so run the probe yourself before trusting `PQ2_0`.

`F16` (53.8 GB) is **not** mirrored — it is larger than everything else here
combined and no Mac can serve it.

There is no 4-bit, 6-bit or 8-bit GGUF band and there cannot be one: these weights
are natively ternary, so such a build would store ternary values in larger
containers — roughly three times the bytes for identical information.

## Model Details

- **Base model:** [Qwen/Qwen3.8-27B](https://huggingface.co/Qwen/Qwen3.8-27B), architecture unchanged
- **Parameters:** 27.36B — 24.35B language backbone (64 blocks) + 2.54B embedding/LM head + 0.46B vision tower (27 blocks)
- **Weight format:** ternary g128 — values in {−1, 0, +1} with one FP16 scale per group of 128, stored in a blockwise Hadamard-rotated basis (block 1024)
- **True bits/weight:** 1.72 as a representation, **2.25 as MLX stores it** (MLX's grouped container keeps a scale *and* a bias per group where the native format keeps one)
- **Deployed size:** 8.60 GB — 7.67 GB language model + 0.92 GB vision tower
- **Architecture:** hybrid attention (~75% linear / ~25% full), SwiGLU MLP, RoPE, RMSNorm
- **Context length:** 262K tokens
- **License:** Apache 2.0

## Benchmarks

Thinking mode, evaluated upstream with EvalScope + vLLM on H100. These measure
the **weights**, not MLX on Apple Silicon, and not the bundled runtime.

| Category | FP16 baseline | Bonsai 2 27B |
| --- | ---: | ---: |
| Coding (HumanEval+, MBPP+, LiveCodeBench) | 89.07 | **89.42** |
| Math (GSM8K, MATH-500, AIME25, AIME26) | 97.06 | 96.57 |
| Instruction following (IFEval, IFBench) | 81.25 | **82.66** |
| Agentic / tool calling (BFCL v3) | 76.74 | 74.92 |
| Knowledge & reasoning (MMLU-Redux, MuSR) | 85.55 | 79.86 |
| Vision (MMMU-Pro, OCR Bench v2) | 71.36 | 66.19 |
| **Overall (14 benchmarks)** | **86.32** | **84.78** |

Coding is level with the full-precision baseline and instruction following is
slightly ahead. The losses are concentrated in knowledge/reasoning and vision.
For comparison, a conventional `IQ2_XXS` build of the same base at 9.4 GB scores
72.59 overall, and collapses to 56.4 on LiveCodeBench — which is the failure
mode this representation avoids.

## Throughput on Apple Silicon

Upstream figures, measured on the **earlier pre-rotation build** via the
llama.cpp Metal backend and reported pending re-measurement:

| Platform | Footprint | Decode (tok/s) | Prefill (tok/s) |
| --- | ---: | ---: | ---: |
| Apple M5 Max | 7.2 GB | 47.0 | 765 |
| Apple M5 Pro | 7.2 GB | 28.7 | 393 |
| Apple M4 Pro | 7.2 GB | 18.0 | 125 |

There is no M3 Pro row. Decode here is memory-bandwidth-bound, and the M3 Pro
has substantially less bandwidth than the M4 Pro, so expect **below** the M4
Pro's 18 tok/s — on the order of 10–13 tok/s is a reasonable guess, but treat
that as an estimate, not a measurement.

The model defaults to `xhigh` reasoning effort. Upstream recommends `medium` for
shorter responses and a better speed/accuracy balance; `low` is not supported
and behaves close to `xhigh`.

Recommended sampling parameters (upstream, and carried in
`generation_config.json`):

- **Thinking:** `temperature=1.0`, `top_p=0.95`, `top_k=20`
- **Instruct / non-thinking:** `temperature=0.7`, `top_p=0.80`, `top_k=20`, `presence_penalty=1.5`

## What is in this repository

| Path | What it is |
| --- | --- |
| **`SETUP.md`** | **start here** — install, serve, run, benchmarks, and 18 GB tuning for macOS |
| **`AGENTS.md`** | hard rules for AI agents (what not to try, and why) |
| **`serve-gguf.sh`** | **one command:** fetch the GGUF, install llama.cpp, smoke-test, serve |
| **`serve-mlx.sh`** | the same for the MLX pack — fetch the weights, build the venv, serve |
| `assemble-gguf.sh` | fetch + verify the GGUF release parts into `upstream-demo/models/bonsai2-gguf/27B/` |
| `model.safetensors` | the MLX weights — **not in git**, fetched by `assemble.sh` |
| `runtime/` | the bundled MLX runtime; **`vision_artifact.py` is the loader this pack needs**, `artifact.py` is the older text-only one |
| `hadamard.json` | the rotation metadata the runtime applies to activations |
| `config.json` | per-layer ternary group metadata (58 KB) |
| `chat_template.jinja`, `tokenizer*` | tokenizer and chat template |
| `PACK-RUNTIME.md` | upstream loading notes, verbatim — **stale for this pack**, see §2 above |
| `UPSTREAM_MODEL_CARD.md` | upstream model card, verbatim |
| `files.json`, `*-validation.json` | upstream serialization/tokenizer validation records |

Validation files check serialization, not model quality or cross-runtime
equivalence.

## License

Apache 2.0, inherited from the base model. The weights are Prism ML's; this
repository only redistributes them.
