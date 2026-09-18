# Vendored copy of PrismML-Eng/Bonsai-demo

This directory is a **verbatim snapshot** of the upstream Bonsai demo, included
so this repository is self-contained: one `git clone` gives you the loader, the
setup scripts, and the upstream documentation without a second network fetch.

| | |
| --- | --- |
| Source | <https://github.com/PrismML-Eng/Bonsai-demo> |
| Commit | `c398c6eeef7533dd9398682cc1297e33670df0cd` |
| Committed | 2026-09-17T11:42:39-07:00 |
| License | Apache 2.0 (see [`LICENSE`](LICENSE)) |
| Vendored | 2026-09-18 |

Nothing in here has been modified. The only omission is upstream's `.git`
directory. The vendored PDFs are upstream's whitepapers, carried for
completeness.

**This is a snapshot, not a fork.** Upstream keeps moving; if something here
disagrees with the live repository, upstream is right. To refresh it:

```bash
git clone --depth 1 https://github.com/PrismML-Eng/Bonsai-demo.git /tmp/bonsai-demo
cp -r /tmp/bonsai-demo/. upstream-demo/ && rm -rf upstream-demo/.git
```

## Where to start

- **[`../SETUP.md`](../SETUP.md)** — the practical walkthrough for this machine.
  Start there.
- [`AGENTS.md`](AGENTS.md) — upstream's own agent instructions.
- [`MODEL-FORMATS.md`](MODEL-FORMATS.md) — which GGUF band to use and why the
  wrong one fails silently.
- [`README.md`](README.md) — full upstream documentation.
- [`setup.sh`](setup.sh) — the installer. Run it from *this* directory:

  ```bash
  cd upstream-demo && ./setup.sh
  ```

  Note that `setup.sh` clones the PrismML `llama.cpp` and `mlx` forks itself and
  downloads model weights into `upstream-demo/`. That is expected: this
  directory is a working checkout, not just reference material. Add it to your
  backups accordingly — the downloads are multi-gigabyte.

## A caution

Upstream's [`PACK-RUNTIME.md`](../PACK-RUNTIME.md) is **not** in this directory;
it ships with the MLX pack (the parent repo). That file tells you to load the
pack with `artifact.load_model`, **which fails on this pack** — see
[`../SETUP.md`](../SETUP.md) §2. Where the pack's own docs and this demo
disagree, the demo is right.

Also note `scripts/start_mlx_server.sh` refuses `bonsai2`. That is a refusal to
*serve*, not a statement that the pack is not an MLX model — see
[`../SETUP.md`](../SETUP.md) §2. One-shot MLX (`scripts/run_mlx.sh`) is supported
and runs on stock MLX.
