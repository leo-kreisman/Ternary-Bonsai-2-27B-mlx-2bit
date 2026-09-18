# Instructions for AI agents working in this repository

## Do this first

Read **[`SETUP.md`](SETUP.md) §1** and run it exactly as written. It is one path,
copy-paste, no decisions. Then stop.

If you are about to conclude that the setup is broken, read **§2** before saying
anything. It lists every wrong conclusion this model reliably produces, and all
seven are false. You are almost certainly about to reach one of them.

Do not invent another. If §2 doesn't cover it, quote the exact command and the
exact error, and say what you tried.

## What this repository is

A mirror of the Hugging Face MLX pack `prism-ml/Ternary-Bonsai-2-27B-mlx-2bit`.
The weights are **not in git**; `./assemble.sh` downloads five release parts and
reassembles `model.safetensors` (8,595,477,990 bytes).

The upstream demo is vendored at **`upstream-demo/`** (verbatim snapshot,
provenance in `upstream-demo/VENDORED-FROM.md`). Everything needed to install and
run is in this one clone. **Do not tell the user to clone
`PrismML-Eng/Bonsai-demo`** — it is public, but it is already here.

## The four things that will get you stuck

1. **The MLX pack does not run in llama.cpp.** llama.cpp reads GGUF and nothing
   else. Two formats, two runtimes: the MLX pack runs under MLX/`mlx-vlm`
   (`run_mlx.sh`, one-shot only); the GGUF bands run under llama.cpp
   (`start_llama_server.sh`, port 8080). Prism maintains two forks for this
   reason, not because one feeds the other.

2. **Never load this pack with `mlx_lm.load`, `mlx_lm.server`, or
   `mlx_lm.generate`.** The weights are Hadamard-rotated and those loaders apply
   no matching transform. They either fail or emit confident nonsense. Upstream's
   own MLX server script hard-refuses `bonsai2`. For a server, use the GGUF path.

   **This is not "MLX is unsupported" and not "it isn't an MLX model".** It is an
   MLX model and runs on **stock MLX** via `./scripts/run_mlx.sh` (the PrismML
   `mlx` fork is for the 1-bit family, not this pack). Only the stock *loader and
   server entry points* are excluded, and only because they skip the rotation.
   Do not report that MLX is out.

3. **Never call `artifact.load_model` on this pack.** `PACK-RUNTIME.md` says to;
   it is stale. `runtime/artifact.py:81-85` rejects anything that is not
   `schema_version == 1`, and this pack is `schema_version: 2`, so it raises
   `Unsupported packed model schema` before reading a tensor. That error is a
   guard clause, **not** evidence of a corrupt download. The correct loader is:

   ```python
   import sys
   sys.path.insert(0, '<repo>/runtime')
   from vision_artifact import load_vl_model
   model, processor, config = load_vl_model('<repo>')
   ```

4. **Never edit `runtime/*.py`, and never edit the expected hashes in
   `assemble.sh`.** Upstream pins the runtime SHA-256s and refuses any revision
   that does not match; this repo's copies match exactly. And hashes in
   `assemble.sh` pin the published bytes — a mismatch means a bad transfer, so
   delete the part and re-run `./assemble.sh`, which re-fetches it.

Also: do not commit a `.gitattributes` from Hugging Face — it marks
`*.safetensors` for Git LFS, and this repo deliberately avoids LFS.

## Quick reference

| Task | Command |
| --- | --- |
| Install | `cd upstream-demo && ./setup.sh` |
| Get the model | `cd upstream-demo && sh scripts/download_models.sh` |
| Get it **without** Hugging Face | `BONSAI_GGUF=… BONSAI_MMPROJ=… ./scripts/start_llama_server.sh` — SETUP.md Step 3-alt |
| Skip the redundant 8.6 GB MLX copy | `BONSAI_SKIP_MLX=1 sh scripts/download_models.sh` |
| Serve (OpenAI-compatible, 8080) | `cd upstream-demo && ./scripts/start_llama_server.sh` |
| One-off prompt | `cd upstream-demo && ./scripts/run_llama.sh -p "..."` |
| One-off via MLX | `cd upstream-demo && ./scripts/run_mlx.sh -p "..."` |
| Get / verify the MLX weights | `./assemble.sh` / `./assemble.sh --verify` |

Environment variables: `PORT` (not `BONSAI_PORT`), `BONSAI_HOST`, `BONSAI_CTX`,
`BONSAI_KV4`, `BONSAI_MMPROJ_CPU`, `BONSAI_NGL`. Full list in
`upstream-demo/environment_variables.md`.
