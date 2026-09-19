GGUF bands for [`prism-ml/Ternary-Bonsai-2-27B-gguf`](https://huggingface.co/prism-ml/Ternary-Bonsai-2-27B-gguf), mirrored here so the llama.cpp path needs **no Hugging Face access at all**.

This is the `PTQ1_0` band plus the `Q8_0` vision projector, and nothing else. Concatenating the three `part-N` assets reproduces the Hugging Face original byte for byte.

## Get them and serve

```bash
git clone https://github.com/leo-kreisman/Ternary-Bonsai-2-27B-mlx-2bit.git
cd Ternary-Bonsai-2-27B-mlx-2bit
./serve-gguf.sh
```

That fetches and verifies these files, downloads a prebuilt Prism llama.cpp binary from GitHub, runs a known-answer prompt, and only then serves on `:8080`. There is no `setup.sh`, no Python virtualenv, no compiler, and no token.

Just the weights:

```bash
./assemble-gguf.sh            # fetch + verify + place (resumable)
./assemble-gguf.sh --verify   # verify what is on disk; fetch nothing
```

They land in `upstream-demo/models/bonsai2-gguf/27B/` — the directory the demo's own scripts already look in. `start_llama_server.sh` then finds the model through `select_model_gguf`, which knows the `*-PTQ1_0.gguf` pattern (`scripts/common.sh:136`), and the projector through its own `*mmproj*.gguf` glob (`:72`). No environment variables, and no new code path.

## ⚠️ You need the Prism fork of llama.cpp

`PTQ1_0` uses ggml type ids past upstream's `GGML_TYPE_COUNT`, so stock llama.cpp refuses it outright — it fails safely, but it does fail. Use the binaries from [`PrismML-Eng/llama.cpp`](https://github.com/PrismML-Eng/llama.cpp); `./serve-gguf.sh` and `cd upstream-demo && sh scripts/download_binaries.sh` both fetch the pinned build.

Do **not** substitute the `Q2_0` band as a mainline-compatible alternative: upstream knows that type id and the `qwen35` architecture, so mainline loads it without a warning and emits gibberish.

## Assets

| Asset | Bytes | sha256 |
| --- | ---: | --- |
| `Ternary-Bonsai-2-27B-PTQ1_0.gguf.part-0` | 1,982,216,310 | `c4ae8f5b2d15eb660abc4ed66e891f21a59a64c3c188d57434672205e7b0aebf` |
| `Ternary-Bonsai-2-27B-PTQ1_0.gguf.part-1` | 1,982,216,310 | `a677e95cf176833829ed410014e4e711635e07f5bbbf039e440078e14d37102e` |
| `Ternary-Bonsai-2-27B-PTQ1_0.gguf.part-2` | 1,982,216,308 | `c52897d69863a87f90cfced1d67449aab1bc596c3f881042da504f2ebe067e7c` |
| `Ternary-Bonsai-2-27B-mmproj-Q8_0.gguf` | 629,246,976 | `6807ede61d570bb86ba34b756a0fa109edc33668604de867c6ea6d8f1d631903` |

The `PTQ1_0` band is 5,946,648,928 bytes, over GitHub's 2 GiB per-file cap, so it ships as three parts; the projector is under the cap and ships whole. Reassembled whole-file hashes (identical to Hugging Face):

```
53107f530aa52eb00912263ab1ee29bd199261c87cd7b4ad4ca1318c1fe33ee3  Ternary-Bonsai-2-27B-PTQ1_0.gguf
6807ede61d570bb86ba34b756a0fa109edc33668604de867c6ea6d8f1d631903  Ternary-Bonsai-2-27B-mmproj-Q8_0.gguf
```

`MANIFEST.sha256` carries the same checksums in `shasum -c` format. To re-check the parts after `./assemble-gguf.sh` has fetched them:

```bash
curl -fLO https://github.com/leo-kreisman/Ternary-Bonsai-2-27B-mlx-2bit/releases/download/gguf-v1/MANIFEST.sha256
grep 'part-' MANIFEST.sha256 > parts.sha256
parts="$(pwd)/parts.sha256"
cd upstream-demo/models/bonsai2-gguf/27B/.parts/Ternary-Bonsai-2-27B-PTQ1_0.gguf
shasum -a 256 -c "$parts"
```

If a part fails, the download is wrong, not the hash. Delete it and re-run `./assemble-gguf.sh`. Do not edit the expected hashes to match a bad download.

## Verified before publishing

These exact bytes were run under the pinned Prism fork before this release was published:

```
$ llama-cli -m Ternary-Bonsai-2-27B-PTQ1_0.gguf -mm Ternary-Bonsai-2-27B-mmproj-Q8_0.gguf \
    -st -rea off -n 96 --temp 1.0 --top-p 0.95 --top-k 20 \
    -p "What is the capital of France? Answer in one short sentence."

ftype      : PTQ1_0 - 1.75 bpw ternary (group 128)
modalities : text, vision, video
> The capital of France is Paris.
```

Coherent output, and the projector loaded — which is what confirms the ternary kernels and the rotation are being applied rather than skipped.

## What you are getting

The 5.54 GiB, 1.75 bpw ternary band of a 27.36B-parameter model, plus a 0.63 GB Q8_0 projector for image input. Base model [Qwen/Qwen3.8-27B](https://huggingface.co/Qwen/Qwen3.8-27B), 262K context, Apache 2.0.

This is the **smaller** of the two servable bands. `PQ2_0` (~7.2 GB) is higher quality and is *not* mirrored here; if you have the memory for it, fetch it from Hugging Face. `F16` (53.8 GB) is not mirrored either.

Thinking is on by default, and the server starts with `--jinja`, so tool calling is wired. See [`SETUP.md`](https://github.com/leo-kreisman/Ternary-Bonsai-2-27B-mlx-2bit/blob/main/SETUP.md) for the full walkthrough and [`AGENTS.md`](https://github.com/leo-kreisman/Ternary-Bonsai-2-27B-mlx-2bit/blob/main/AGENTS.md) for the rules agents keep getting wrong.

Licence: Apache 2.0, inherited from the base model. The weights are Prism ML's; this release only redistributes them.
