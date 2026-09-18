# Instructions for AI agents working in this repository

**Read [`SETUP.md`](SETUP.md) before doing anything.** It is the authoritative
setup and run guide. This file exists so you don't repeat the mistakes listed
below, which are the ones agents reliably make here.

## What this repository is

A mirror of the Hugging Face MLX pack `prism-ml/Ternary-Bonsai-2-27B-mlx-2bit`.
The weights are **not in git**; `./assemble.sh` downloads five release parts and
reassembles them into `model.safetensors` (8,595,477,990 bytes).

The upstream demo is vendored at **`upstream-demo/`**, so everything needed to
install and run is in this one clone — do not send the user off to clone
`PrismML-Eng/Bonsai-demo` separately. It is a verbatim snapshot; provenance is in
`upstream-demo/VENDORED-FROM.md`.

## The misconception to check first

**The MLX pack does not run in llama.cpp.** They are two formats for two
runtimes, and they do not interchange:

- **MLX pack** (this repo, `model.safetensors`) → runs under **MLX / mlx-vlm**,
  via `vision_artifact.load_vl_model`, driven by `scripts/run_mlx.sh`. One-shot
  only, never served.
- **GGUF bands** (`PTQ1_0`, `PQ2_0`) → run under **llama.cpp** with the PrismML
  fork, served by `scripts/start_llama_server.sh`. This is the only server path.

llama.cpp reads GGUF and nothing else — it cannot open an MLX pack. If you have
concluded that the MLX weights are meant to be loaded by the llama.cpp fork, that
is wrong; re-read `SETUP.md` §1a. Prism maintains *two* forks (`PrismML-Eng/mlx`
and `PrismML-Eng/llama.cpp`) because both runtimes need the Hadamard activation
transform, not because one feeds the other.

## Hard rules

1. **Do not try to load this model with `mlx_lm.load`, `mlx_lm.server`,
   `mlx_lm.generate`, or any stock MLX loader.** Bonsai 2 stores weights in a
   blockwise Hadamard-rotated basis, and those loaders apply no matching
   transform. They will either fail or — worse — produce confident nonsense.
   Upstream's own `start_mlx_server.sh` hard-refuses `bonsai2`. If a user asks
   for a served model, the answer is the **llama.cpp path in `SETUP.md` §3**,
   not MLX.

2. **Do not use `artifact.load_model` on this pack.** `PACK-RUNTIME.md` tells you
   to; it is stale and it will fail. `runtime/artifact.py` rejects anything that
   is not `schema_version == 1`, and this pack is `schema_version: 2`. It raises
   `Unsupported packed model schema` before reading a tensor.

   The correct loader is:

   ```python
   import sys
   sys.path.insert(0, '<repo>/runtime')
   from vision_artifact import load_vl_model
   model, processor, config = load_vl_model('<repo>')
   ```

3. **Do not edit any file in `runtime/`.** Upstream pins the SHA-256 of all four
   runtime files in `Bonsai-demo/scripts/bonsai2-runtime.sha256` and refuses to
   import a revision that doesn't match. The copies here are verified
   byte-identical to that pinned revision. "Fixing" one to make something load
   will get the pack rejected by the official driver.

4. **Never edit the expected hashes in `assemble.sh`** to match a download. They
   pin the published bytes. A checksum failure means the transfer is bad — delete
   the part and re-run `./assemble.sh`, which re-fetches it automatically.

5. **Do not commit a `.gitattributes` from Hugging Face.** It marks
   `*.safetensors` for Git LFS, and this repo deliberately avoids LFS.

## Quick reference

| Task | Command |
| --- | --- |
| Get the weights | `./assemble.sh` |
| Verify existing weights | `./assemble.sh --verify` |
| Re-fetch one bad part | `rm -f .parts/<part> && ./assemble.sh` |
| Install everything | `cd upstream-demo && ./setup.sh` |
| Serve (OpenAI-compatible, port 8080) | `cd upstream-demo && ./scripts/start_llama_server.sh` |
| One-off prompt | `cd upstream-demo && ./scripts/run_llama.sh -p "..."` |
| One-off via MLX | `cd upstream-demo && ./scripts/run_mlx.sh -p "..."` |

## When the user reports "it won't load"

Two errors account for nearly all of them:

- `Unsupported packed model schema` → wrong loader. See rule 2.
- A refusal or gibberish from an MLX server → correct behavior. See rule 1.

Full symptom table in `SETUP.md` §7. Do not invent a workaround; every
supported path goes through the PrismML fork binaries.
