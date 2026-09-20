# Instructions for AI agents working in this repository

## Do this first

**If you want the model served** — which is what a coding agent needs — run one
of these from the repo root and do not hand-assemble the steps:

```bash
./serve-gguf.sh             # GGUF via llama.cpp — no Hugging Face, no venv
./serve-mlx.sh              # MLX pack — no Hugging Face, builds a venv
```

Add `--check` to either to set up and smoke-test but stop before serving.

**Prefer `./serve-gguf.sh`.** It is the shorter path: the GGUF bands are
mirrored in this repo's own release (tag `gguf-v1`), and the llama.cpp install
is a 12 MB prebuilt tarball from GitHub, so the whole thing needs no Hugging
Face access, no Python virtualenv and no compiler. `./serve-mlx.sh` is equally
supported and uses the MLX pack instead of the GGUF.

Both check the checkout, fetch what is missing, run a known-answer prompt, and
only start the server if that answer is correct. If either prints `[STOP]`, that
is the finding — report it, do not work around it.

For everything else, read **[`SETUP.md`](SETUP.md) §1** and run it exactly as
written. It is one path, copy-paste, no decisions. Then stop.

If you are about to conclude that the setup is broken, read **§2** before saying
anything. It lists every wrong conclusion this model reliably produces, and all
thirteen are false. You are almost certainly about to reach one of them.

**If you are about to run `./setup.sh`: stop and read SETUP.md Step 2-alt.** For
the MLX path `setup.sh` is optional and actively harmful — it calls
`download_models.sh` (`setup.sh:274`) and therefore starts a Hugging Face
download you may not want and may not be able to reach.

**If the user wants a server** (a coding agent needs one), two exist, and the
one-command front ends for both are above. Do not hand-assemble either:

- **Tested, and the shorter path:** llama.cpp + GGUF through `./serve-gguf.sh`,
  or `cd upstream-demo && ./scripts/start_llama_server.sh` directly, port 8080.
  The GGUF bands are mirrored in this repo, so this one needs no Hugging Face.
- **MLX:** `./serve-mlx.sh`, or `scripts/mlx_server_bonsai2.py` directly, port
  8080 — the server script is written by this repo and is **new and never run**.
  Validate it with the curl SETUP.md Step 4-alt prints before wiring anything to
  it. Fluent nonsense means it is skipping the rotation: stop.

Do not invent another. If §2 doesn't cover it, quote the exact command and the
exact error, and say what you tried.

## What this repository is

A mirror of two Hugging Face artifacts for the same model:

| Upstream | Runtime | Local |
| --- | --- | --- |
| `prism-ml/Ternary-Bonsai-2-27B-mlx-2bit` | MLX | `./assemble.sh` → `model.safetensors` (8,595,477,990 bytes) |
| `prism-ml/Ternary-Bonsai-2-27B-gguf` | llama.cpp | `./assemble-gguf.sh` → `PTQ1_0` + `PQ2_0` + `mmproj-Q8_0` (+ `mmproj-BF16` in `27B-projectors/`) |

**No weights are in git** in either case; both assemblers download release
parts (tag `weights-v1` and `gguf-v1`), verify each part against a pinned
sha256, and reassemble. The GGUF one places its files into
`upstream-demo/models/bonsai2-gguf/27B/`, which is where the demo's own scripts
look, so nothing needs an environment variable.

The upstream demo is vendored at **`upstream-demo/`** (verbatim snapshot,
provenance in `upstream-demo/VENDORED-FROM.md`). Everything needed to install and
run is in this one clone. **Do not tell the user to clone
`PrismML-Eng/Bonsai-demo`** — it is public, but it is already here.

## The five things that will get you stuck

1. **The MLX pack does not run in llama.cpp.** llama.cpp reads GGUF and nothing
   else. Two formats, two runtimes: the MLX pack runs under MLX/`mlx-vlm`
   (`run_mlx.sh`, one-shot only); the GGUF bands run under llama.cpp
   (`start_llama_server.sh`, port 8080). Prism maintains two forks for this
   reason, not because one feeds the other.

2. **Never load this pack with `mlx_lm.load`, `mlx_lm.server`, or
   `mlx_lm.generate`.** The weights are Hadamard-rotated and those loaders apply
   no matching transform. They either fail or emit confident nonsense. Upstream's
   own MLX server script hard-refuses `bonsai2`. For a **tested** server, use the
   GGUF path; for an MLX server, this repo ships one (see 5 below and SETUP.md
   Step 4-alt).

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

4. **Never edit `runtime/*.py`, `config.json`, or the expected hashes in
   `assemble.sh` or `assemble-gguf.sh`.** Upstream pins the runtime SHA-256s and
   refuses any revision that does not match; this repo's copies match exactly.
   And hashes in the assemblers pin the published bytes — a mismatch means a bad
   transfer, so delete the part and re-run, which re-fetches it.

   **`config.json` is shipped, correct, and load-bearing.** Do not "repair" it,
   do not rewrite `model_type`, and do not rewrite it back to the value you
   think it should have. `model_type` must stay `prism_hadamard_qwen35`; the
   base architecture is carried separately in `base_model_type` (`qwen3_5`) and
   `chat_config()` swaps them at load time on purpose
   (`runtime/vision_artifact.py:98-100`). An agent has already been here: it
   found `model_type: "qwen3_5"`, wrote `prism_hadamard_qwen35` back with a
   Python one-liner, and printed it as a success. If a `config.json` on disk
   says `qwen3_5`, the file was edited — restore it with
   `git checkout -- config.json` rather than patching it further, then check
   `git status` for whatever else was touched. A pack whose `model_type` is
   `qwen3_5` is a pack whose Hadamard transform will be skipped, and it loads
   *successfully* while emitting nonsense.

5. **The Hugging Face model card's Quickstart is a Python snippet, and it is why
   you keep writing Python.** The card's entire Quickstart is:

   ```python
   model, processor, config = load_vl_model("bonsai2-27b-mlx")
   prompt = apply_chat_template(processor, chat_config(config), "…", num_images=1)
   print(generate(model, processor, prompt, ["photo.jpg"], max_tokens=256, temperature=1.0))
   ```

   That is one-shot Python, not a server, and it is already implemented **twice**
   in this repo: as a one-line command (`scripts/mlx_generate_bonsai2.py`) and
   behind HTTP (`scripts/mlx_server_bonsai2.py`). **Do not write a third.** Use
   one of those. The card offers no server for MLX; upstream's card routes
   serving to GGUF ("for CUDA, CPU, and llama.cpp on Metal, use the GGUF packs").

   `scripts/mlx_server_bonsai2.py` is **new and has never been run** (written
   without Apple Silicon available). Before trusting it, run the curl in SETUP.md
   Step 4-alt. Coherent answer = it works. Fluent nonsense = it is skipping the
   rotation, so stop and say so.

Also: do not commit a `.gitattributes` from Hugging Face — it marks
`*.safetensors` for Git LFS, and this repo deliberately avoids LFS.

## Quick reference

| Task | Command |
| --- | --- |
| **Everything (GGUF): set up, verify, smoke-test, serve** | `./serve-gguf.sh` (`--check` stops before serving) |
| **Everything (MLX): set up, verify, smoke-test, serve** | `./serve-mlx.sh` (`--check` stops before serving) |
| **Get the GGUF from this repo** — no Hugging Face | `./assemble-gguf.sh` (lands in `upstream-demo/models/bonsai2-gguf/27B/`) |
| **Serve the higher-quality band** | `BONSAI_GGUF=…/27B/Ternary-Bonsai-2-27B-PQ2_0.gguf ./scripts/start_llama_server.sh` |
| **Use the BF16 projector** | `BONSAI_MMPROJ=…/27B-projectors/Ternary-Bonsai-2-27B-mmproj-BF16.gguf …` |
| **MLX, one prompt** | `cd upstream-demo && .venv-vlm/bin/python scripts/mlx_generate_bonsai2.py --model .. -p "..."` |
| **MLX server** (new, untested) | `cd upstream-demo && .venv-vlm/bin/python scripts/mlx_server_bonsai2.py --model .. --port 8080` |
| Install, **MLX only** — no `setup.sh` | SETUP.md **Step 2-alt** (two commands) |
| Install, for the llama.cpp server | `cd upstream-demo && ./setup.sh` |
| Get the MLX weights | `./assemble.sh` in the repo root |
| Get / verify the MLX weights | `./assemble.sh` / `./assemble.sh --verify` |
| Get the GGUF from Hugging Face instead | `cd upstream-demo && sh scripts/download_models.sh` |
| Serve a GGUF that is already on disk | `BONSAI_GGUF=… BONSAI_MMPROJ=… ./scripts/start_llama_server.sh` — Step 3-alt |
| Skip the redundant 8.6 GB MLX copy | `BONSAI_SKIP_MLX=1 sh scripts/download_models.sh` |
| Serve, llama.cpp (tested, 8080) | `cd upstream-demo && ./scripts/start_llama_server.sh` |
| One-off prompt via llama.cpp | `cd upstream-demo && ./scripts/run_llama.sh -p "..."` |

`mmproj-BF16` is deliberately placed in `27B-projectors/`, **not** in `27B/`.
`start_llama_server.sh:72` picks its projector with a first-match glob over
`$GGUF_MODEL_DIR/*mmproj*.gguf`; `mmproj-BF16` sorts before `mmproj-Q8_0`, so
putting it beside the model would silently switch every run to a projector the
text-only smoke test never exercises. **Do not "tidy" it into `27B/`**, and do
not widen that glob. Move it only with `BONSAI_MMPROJ=<path>`.

Environment variables: `PORT` (not `BONSAI_PORT`), `BONSAI_HOST`, `BONSAI_CTX`,
`BONSAI_KV4`, `BONSAI_MMPROJ_CPU`, `BONSAI_NGL`. Full list in
`upstream-demo/environment_variables.md`.
