GGUF bands for [`prism-ml/Ternary-Bonsai-2-27B-gguf`](https://huggingface.co/prism-ml/Ternary-Bonsai-2-27B-gguf), mirrored here so the llama.cpp path needs **no Hugging Face access at all**.

This is both servable bands — `PTQ1_0` and `PQ2_0` — plus both vision projectors. Concatenating the `part-N` assets reproduces the Hugging Face originals byte for byte.

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

The model and the tested projector land in `upstream-demo/models/bonsai2-gguf/27B/` — the directory the demo's own scripts already look in. `start_llama_server.sh` then finds the model through `select_model_gguf`, which knows the `*-PTQ1_0.gguf` pattern (`scripts/common.sh:136`), and the projector through its own `*mmproj*.gguf` glob (`:72`). No environment variables, and no new code path. `./serve-gguf.sh` serves `PTQ1_0`; point `BONSAI_GGUF` at `PQ2_0` to serve that one instead.

## ⚠️ You need the Prism fork of llama.cpp — for both bands

`PTQ1_0` and `PQ2_0` both use ggml type ids past upstream's `GGML_TYPE_COUNT`, so stock llama.cpp refuses them outright — they fail safely, but they do fail. **There is no stock-llama.cpp band in this release.** Use the binaries from [`PrismML-Eng/llama.cpp`](https://github.com/PrismML-Eng/llama.cpp); `./serve-gguf.sh` and `cd upstream-demo && sh scripts/download_binaries.sh` both fetch the pinned build.

Do **not** substitute the `Q2_0` band as a mainline-compatible alternative: upstream knows that type id and the `qwen35` architecture, so mainline loads it without a warning and emits gibberish.

## Which band to use

| | `PTQ1_0` | `PQ2_0` |
| --- | --- | --- |
| Bytes | 5,946,648,928 (5.54 GiB) | 7,206,168,928 (6.71 GiB) |
| Effective | 1.75 bpw ternary, group 128 | 2-bit product quant |
| Use when | memory is tight | you want the better output |

Both need the Prism fork and both are verified here. `PTQ1_0` is the smaller band and is the one `./serve-gguf.sh` serves by default.

## Assets

| Asset | Bytes | sha256 |
| --- | ---: | --- |
| `Ternary-Bonsai-2-27B-PTQ1_0.gguf.part-0` | 1,982,216,310 | `c4ae8f5b2d15eb660abc4ed66e891f21a59a64c3c188d57434672205e7b0aebf` |
| `Ternary-Bonsai-2-27B-PTQ1_0.gguf.part-1` | 1,982,216,310 | `a677e95cf176833829ed410014e4e711635e07f5bbbf039e440078e14d37102e` |
| `Ternary-Bonsai-2-27B-PTQ1_0.gguf.part-2` | 1,982,216,308 | `c52897d69863a87f90cfced1d67449aab1bc596c3f881042da504f2ebe067e7c` |
| `Ternary-Bonsai-2-27B-PQ2_0.gguf.part-0` | 1,801,542,232 | `c76cc27bf7b59c7f732b434fcd961a00baa8c78ac112e747a5b533b10bced2ed` |
| `Ternary-Bonsai-2-27B-PQ2_0.gguf.part-1` | 1,801,542,232 | `3bf4f8b26cad40df53a2627bb57c4c678ec5d3ca4d7d8f7ca7894acf9c0b76c4` |
| `Ternary-Bonsai-2-27B-PQ2_0.gguf.part-2` | 1,801,542,232 | `fd9779cb9010548fbb2086244b862dd36087d810f9546b2ee4afbacffc41d50f` |
| `Ternary-Bonsai-2-27B-PQ2_0.gguf.part-3` | 1,801,542,232 | `18b39c944e19ea4f0774e8342ffce632ede837772a3516dd44c21d1d0fe41717` |
| `Ternary-Bonsai-2-27B-mmproj-Q8_0.gguf` | 629,246,976 | `6807ede61d570bb86ba34b756a0fa109edc33668604de867c6ea6d8f1d631903` |
| `Ternary-Bonsai-2-27B-mmproj-BF16.gguf` | 931,145,856 | `e287342d92332fa3577ed1d42e921dac9370c08da58ba9337fa450f6cc76cfd7` |

Both `PTQ1_0` (5,946,648,928 bytes) and `PQ2_0` (7,206,168,928 bytes) are over GitHub's 2 GiB per-file cap, so they ship as three and four parts; both projectors are under the cap and ship whole. Reassembled whole-file hashes (identical to Hugging Face):

```
53107f530aa52eb00912263ab1ee29bd199261c87cd7b4ad4ca1318c1fe33ee3  Ternary-Bonsai-2-27B-PTQ1_0.gguf
3907dc1658db1f78a9826bf8d5bcb8dc65db0d466388937af57f2294fae62ec1  Ternary-Bonsai-2-27B-PQ2_0.gguf
6807ede61d570bb86ba34b756a0fa109edc33668604de867c6ea6d8f1d631903  Ternary-Bonsai-2-27B-mmproj-Q8_0.gguf
e287342d92332fa3577ed1d42e921dac9370c08da58ba9337fa450f6cc76cfd7  Ternary-Bonsai-2-27B-mmproj-BF16.gguf
```

## Why `mmproj-BF16` is not in the model directory

`assemble-gguf.sh` places it in `27B-projectors/`, one directory over. `start_llama_server.sh:72` picks its projector with a first-match glob:

```bash
for _mp in $GGUF_MODEL_DIR/*mmproj*.gguf; do [ -f "$_mp" ] && MMPROJ="$_mp" && break; done
```

Sorted, `mmproj-BF16` comes before `mmproj-Q8_0`, so putting the BF16 projector beside the model would silently switch every run to a projector that has not been through the known-answer check — and that check is text-only, so it would not catch it. Keeping it one directory over leaves the tested path exactly as it was while still shipping the bytes. Use it with `BONSAI_MMPROJ=/path/to/Ternary-Bonsai-2-27B-mmproj-BF16.gguf`.

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

`PTQ1_0` — these exact bytes were run under the pinned Prism fork before this release was published:

```
$ llama-cli -m Ternary-Bonsai-2-27B-PTQ1_0.gguf -mm Ternary-Bonsai-2-27B-mmproj-Q8_0.gguf \
    -st -rea off -n 96 --temp 1.0 --top-p 0.95 --top-k 20 \
    -p "What is the capital of France? Answer in one short sentence."

ftype      : PTQ1_0 - 1.75 bpw ternary (group 128)
modalities : text, vision, video
> The capital of France is Paris.
```

Coherent output, and the projector loaded — which is what confirms the ternary kernels and the rotation are being applied rather than skipped.

`PQ2_0` is **not** in that transcript: it was verified against the sha256 Hugging Face publishes, byte for byte, but it has not been through the same known-answer run here. It carries the same fork requirement and the same architecture; if you serve it, run the probe yourself before trusting it.

## What you are getting

Both servable bands of a 27.36B-parameter model — 5.54 GiB at 1.75 bpw ternary, and 6.71 GiB at 2-bit product quant — plus a Q8_0 and a BF16 projector for image input. Base model [Qwen/Qwen3.8-27B](https://huggingface.co/Qwen/Qwen3.8-27B), 262K context, Apache 2.0.

`F16` (53.8 GB) is **not** mirrored: it is larger than everything else here combined and no Mac can serve it. If you want it, fetch it from Hugging Face.

There is no 4-bit, 6-bit or 8-bit band, and there cannot be one — these weights are natively ternary, so a `Q4_K_M`/`Q6_K`/`Q8_0` of them would store ternary values in larger containers, roughly three times the bytes for identical information. That is why prism-ml publishes none.

Thinking is on by default, and the server starts with `--jinja`, so tool calling is wired. See [`SETUP.md`](https://github.com/leo-kreisman/Ternary-Bonsai-2-27B-mlx-2bit/blob/main/SETUP.md) for the full walkthrough and [`AGENTS.md`](https://github.com/leo-kreisman/Ternary-Bonsai-2-27B-mlx-2bit/blob/main/AGENTS.md) for the rules agents keep getting wrong.

Licence: Apache 2.0, inherited from the base model. The weights are Prism ML's; this release only redistributes them.
