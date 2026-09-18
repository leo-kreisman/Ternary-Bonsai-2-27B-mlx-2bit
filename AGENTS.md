# Instructions for AI agents working in this repository

**Read [`SETUP.md`](SETUP.md) before doing anything.** It is the authoritative
setup and run guide. This file exists so you don't repeat the mistakes listed
below, which are the ones agents reliably make here.

## What this repository is

A mirror of the Hugging Face MLX pack `prism-ml/Ternary-Bonsai-2-27B-mlx-2bit`.
The weights are **not in git**; `./assemble.sh` downloads five release parts and
reassembles them into `model.safetensors` (8,595,477,990 bytes).

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
| Serve (OpenAI-compatible, port 8080) | `./scripts/start_llama_server.sh` in `Bonsai-demo` |
| One-off prompt | `./scripts/run_llama.sh -p "..."` |
| One-off via MLX | `./scripts/run_mlx.sh -p "..."` |

## When the user reports "it won't load"

Two errors account for nearly all of them:

- `Unsupported packed model schema` → wrong loader. See rule 2.
- A refusal or gibberish from an MLX server → correct behavior. See rule 1.

Full symptom table in `SETUP.md` §7. Do not invent a workaround; every
supported path goes through the PrismML fork binaries.
