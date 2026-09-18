MLX ternary (2-bit) weights for [`prism-ml/Ternary-Bonsai-2-27B-mlx-2bit`](https://huggingface.co/prism-ml/Ternary-Bonsai-2-27B-mlx-2bit), split into five byte-range parts.

The single weight file `model.safetensors` is 8,595,477,990 bytes (~8.60 GB), over GitHub's 2 GiB per-file cap, so it ships as five parts of 1,719,095,598 bytes each. Concatenating them reproduces the original byte for byte.

## Get them

```bash
git clone https://github.com/leo-kreisman/Ternary-Bonsai-2-27B-mlx-2bit.git
cd Ternary-Bonsai-2-27B-mlx-2bit
./assemble.sh
```

The script downloads the parts, verifies each one's sha256, concatenates them, and checks the result against the whole-file hash. It is resumable and re-fetches any part that fails its checksum.

## ⚠️ This is not a drop-in MLX model

The weights are stored in a **blockwise Hadamard-rotated basis**. The runtime must apply the matching transform to activations. Stock `mlx-lm` will not run it — upstream is explicit that a runtime either applies the transform or refuses to load the file.

Use the **vision loader**, not `artifact.load_model` — that one is the older
text-only loader and it rejects this pack outright:

```python
import sys
sys.path.insert(0, '<repo>/runtime')
from vision_artifact import load_vl_model
model, processor, config = load_vl_model('<repo>')
```

`PACK-RUNTIME.md` tells you to use `artifact.load_model`; **it is stale and will
fail** with `Unsupported packed model schema`, because this pack is
`schema_version: 2` and `artifact.py` requires `1`. Vision **is** included in this
pack (`components = {"text": true, "vision": true, "mtp": false}`); MTP is not.

For an OpenAI-compatible server, use the **llama.cpp path** — `mlx_lm.server`
cannot serve this model, and upstream's own MLX server script refuses it by
design. Full walkthrough, including an 18 GB tuning section:
[`SETUP.md`](https://github.com/leo-kreisman/Ternary-Bonsai-2-27B-mlx-2bit/blob/main/SETUP.md).
Agents should start at [`AGENTS.md`](https://github.com/leo-kreisman/Ternary-Bonsai-2-27B-mlx-2bit/blob/main/AGENTS.md).

## Parts

| Part | Bytes | sha256 |
| --- | ---: | --- |
| `model.safetensors.part-0` | 1,719,095,598 | `7f9edef6d4c9cbaaab778f6089c388d5e910f805a549093609439fd0e42cd99b` |
| `model.safetensors.part-1` | 1,719,095,598 | `a46d1a47b762961a094d928a37c3cacba7e2d90c479a3eccf2b590ef9fee67b1` |
| `model.safetensors.part-2` | 1,719,095,598 | `aef84cf964cd5a4f3a0f69cfcafe664d52b2d92cd28a6873d12f56c1781d1ffc` |
| `model.safetensors.part-3` | 1,719,095,598 | `e6f3add026a192849905dc582e446ed1e17bc89c7fef003bc676117bcabcedac` |
| `model.safetensors.part-4` | 1,719,095,598 | `2464e72fedec333ad12c362d4e33f197cb7e63cc478800c3338610ddb026490d` |

Assembled whole-file hash (identical to Hugging Face):

```
130de5925082c168b7866b2e91b52e44abbafc99017e3ca352b77b5b55a269ed  model.safetensors
```

`MANIFEST.sha256` carries the same checksums in `shasum -c` format:

```bash
curl -fLO https://github.com/leo-kreisman/Ternary-Bonsai-2-27B-mlx-2bit/releases/download/weights-v1/MANIFEST.sha256
grep 'safetensors\.part-' MANIFEST.sha256 > parts.sha256
(cd .parts && shasum -a 256 -c ../parts.sha256)
```

If a part fails, the download is wrong, not the hash. Delete it and re-run `assemble.sh`. Do not edit the expected hashes to match a bad download.

## What you are getting

27.36B parameters (24.35B backbone over 64 blocks + 2.54B embedding/LM head + 0.46B vision tower) in 8.60 GB deployed — 7.67 GB language model plus 0.92 GB vision tower. Ternary g128, base model [Qwen/Qwen3.8-27B](https://huggingface.co/Qwen/Qwen3.8-27B), 262K context, Apache 2.0.

Coding is level with the full-precision baseline (89.42 vs 89.07) and instruction following is slightly ahead (82.66 vs 81.25); the losses sit in knowledge/reasoning (79.86 vs 85.55) and vision (66.19 vs 71.36). See the [repository README](https://github.com/leo-kreisman/Ternary-Bonsai-2-27B-mlx-2bit#readme) for the full picture, including sampling parameters, reasoning-effort guidance, and likely throughput on Apple Silicon.
