
## Session Handoff — 2026-09-18 (MLX-servability wording)

**Goal:** Stop the user's Mac agent from concluding "this is not an MLX model / MLX is
unsupported", which it reached by reading this repo's own README and AGENTS.md.

**Failed Paths:**
- Assuming the agent was simply wrong. It was quoting the repo: README said "This is not
  a drop-in MLX model" and AGENTS.md trap 2 said "never load with mlx_lm.*". Read
  together those generalize to "MLX is out". The docs caused it.
- README listed the PrismML `mlx` fork as a requirement for this pack. Wrong —
  `run_mlx.sh:56` says Bonsai 2 runs on **stock MLX** via `.venv-vlm`; the fork is for
  the 1-bit family.
- Treating the follow-up complaint ("it says mlx is not servable") as another agent
  error. It is not. That one is true.

**Final Solution:** Split one over-broad claim into the two real ones, in README.md,
SETUP.md §2 (new seventh refutation, placed first), AGENTS.md trap 2, and
upstream-demo/VENDORED-FROM.md.
1. It IS an MLX model; runs on stock MLX one-shot via `./scripts/run_mlx.sh`. Fork not
   needed for this pack.
2. The stock `mlx_lm`/`mlx_vlm` loader **and server** entry points are excluded, because
   they apply no Hadamard rotation. No MLX server exists for `bonsai2`; upstream refuses
   it in `start_mlx_server.sh`. Server = GGUF + llama.cpp, port 8080.
Also fixed two stale cross-references (`§4` -> `§2`). Commit `c4ace32`, pushed.

**Unresolved:**
- No MLX server exists. Upstream's refusal is "Refuse until a server path exists", i.e.
  unbuilt, not impossible — the pack loads into a standard `mlx_vlm` Model with a ready
  `Qwen3VLProcessor`, so a custom server calling `vision_artifact.load_vl_model` and
  driving `mlx_vlm.generate` would produce correct output. Offered twice; not accepted.
  Cannot be tested here (x86_64 Linux, no MLX) — the Mac would validate it.
- OmniCoder-9B mirror still not built (download done; repo empty; 10 parts planned).
- Optional: report upstream that `PACK-RUNTIME.md` names `artifact.load_model`, which
  rejects this schema-2 pack.
