"""OpenAI-compatible MLX server for Bonsai 2 packs.

Bonsai 2 stores its language weights in a rotated basis, so the matching transform has to be
applied to activations at run time. `mlx_lm.server` and `mlx_vlm.server` do not apply it: they
load the weights and return wrong output with no error, which is why the demo's own
`scripts/start_mlx_server.sh` refuses `bonsai2`. This server uses the pack's own loader
(`runtime/vision_artifact.py`) and the same `mlx_vlm.generate` call as
`scripts/mlx_generate_bonsai2.py`, so the transform is applied.

HTTP is standard library only. The pack's `runtime/requirements.txt` pins exact versions and
carries no web framework; adding one would mean changing those pins.

UNTESTED. This file was written without an Apple Silicon machine available, so it has never
been executed. Validate it with the curl in `--help` before trusting it with an agent.

Text only. Images are not wired into the HTTP path; use `scripts/run_mlx.sh --image` for those.

Thinking is supported, because the pack's own chat template supports it: it is **on by
default**, and `reasoning_effort` selects xhigh (the template's default), medium or low
(`chat_template.jinja:46-55`, `:165-169`). Pass `enable_thinking: false` per request,
`chat_template_kwargs`, or start the server with `--no-think`. Replies therefore contain a
` thinking... response` block unless you turn it off.

Not wired: tool calling. The pack's template does handle a `tools` argument
(`chat_template.jinja:57`), so it is reachable, but this server does not pass one or parse
`tool_calls` back out. A client that needs function calling will not get it yet.
"""
import argparse
import hashlib
import json
import os
import sys
import threading
import time
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

# transformers does not recognise `prism_hadamard_qwen35` and says so loudly, and its tokenizer
# prints a Mistral regex note. Neither applies: the pack's loader builds the model itself and the
# tokenizer is the base model's own. Both read as errors to a first-time user, so quiet them
# before transformers is imported, which is when it reads this.
os.environ.setdefault("TRANSFORMERS_VERBOSITY", "error")
os.environ.setdefault("TOKENIZERS_PARALLELISM", "false")

DEFAULTS = {
    "temp": 1.0,
    "top_p": 0.95,
    "top_k": 20,
    "max_tokens": 4096,
    # Thinking is ON in this pack's chat template unless `enable_thinking` is explicitly
    # false (`chat_template.jinja:46`, `:165-169`), and `reasoning_effort` is one of
    # xhigh (default), medium, low. These defaults match the template's own, so a client
    # that says nothing gets exactly what `run_mlx.sh` would have produced.
    "enable_thinking": True,
    "reasoning_effort": None,
}

MANIFEST = Path(__file__).resolve().parent / "bonsai2-runtime.sha256"

# MLX generation is not safe to run concurrently on one model instance, and this server is
# threaded so that a client polling /health cannot block behind a generation. Every generate call
# takes this lock, so requests queue rather than interleave.
GEN_LOCK = threading.Lock()


def read_manifest():
    entries = {}
    for line in MANIFEST.read_text().splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        digest, name = line.split(None, 1)
        entries[name.strip()] = digest
    return entries


def verify_runtime(runtime):
    """Refuse to import loader code that is not the reviewed revision.

    Same check as mlx_generate_bonsai2.py, and for the same reason: whatever is in runtime/
    runs as the user, so a change over there must not quietly become code execution here.
    """
    if os.environ.get("BONSAI_SKIP_RUNTIME_CHECK") == "1":
        print("runtime checksum check skipped (BONSAI_SKIP_RUNTIME_CHECK=1)", file=sys.stderr)
        return
    if not MANIFEST.is_file():
        sys.exit(f"{MANIFEST} is missing; cannot verify the pack's loader code.")

    expected = read_manifest()
    found = {f.name for f in runtime.glob("*.py")}
    problems = []
    for name in sorted(set(expected) | found):
        if name not in expected:
            problems.append(f"  {name}: not in the manifest")
        elif name not in found:
            problems.append(f"  {name}: in the manifest but missing from the pack")
        else:
            digest = hashlib.sha256((runtime / name).read_bytes()).hexdigest()
            if digest != expected[name]:
                problems.append(f"  {name}: {digest} does not match {expected[name]}")
    if problems:
        sys.exit(
            "The pack's loader code does not match the revision this demo pinned, so it "
            "will not be imported.\n" + "\n".join(problems)
        )


class Bonsai:
    """The loaded pack, plus the one call that turns messages into text."""

    def __init__(self, pack_path, gen_defaults):
        self.pack = Path(pack_path).resolve()
        self.defaults = gen_defaults
        config_path = self.pack / "config.json"
        if not config_path.is_file():
            sys.exit(f"No config.json in {self.pack}. Run ./assemble.sh first.")
        config = json.loads(config_path.read_text())
        if config.get("model_type") != "prism_hadamard_qwen35":
            sys.exit(
                f"{self.pack} is not a Bonsai 2 MLX pack (model_type={config.get('model_type')!r})."
            )
        runtime = self.pack / "runtime"
        if not (runtime / "vision_artifact.py").is_file():
            sys.exit(f"{runtime}/vision_artifact.py is missing; this pack predates vision support.")
        verify_runtime(runtime)
        sys.path.insert(0, str(runtime))

        import warnings

        warnings.filterwarnings("ignore")

        import mlx.core as mx

        mx.set_default_device(mx.gpu)

        from vision_artifact import chat_config, load_vl_model

        from mlx_vlm import generate
        from mlx_vlm.prompt_utils import apply_chat_template

        self._generate = generate
        self._apply_chat_template = apply_chat_template
        self._chat_config = chat_config

        started = time.time()
        self.model, self.processor, self.config = load_vl_model(str(self.pack))
        print(f"loaded {self.pack.name} in {time.time() - started:.0f}s", file=sys.stderr)

    def build_prompt(self, messages, enable_thinking=True, reasoning_effort=None):
        """Render an OpenAI messages list with the pack's own chat template.

        The tokenizer path is preferred because it handles a system prompt, multi-turn
        history, and the thinking controls, which a coding agent needs. mlx-vlm's helper
        only takes one user prompt, so it is the fallback for a tokenizer with no template
        -- and that fallback cannot express `enable_thinking`, so it always thinks.

        `enable_thinking` and `reasoning_effort` are the pack's own template variables
        (`chat_template.jinja:46-55`, `:165-169`); passing them is what makes thinking
        controllable. `reasoning_effort` must be xhigh, medium or low, and the template
        raises on anything else, so it is validated here rather than in the client.
        """
        tokenizer = getattr(self.processor, "tokenizer", None)
        if reasoning_effort is not None and reasoning_effort not in ("xhigh", "medium", "low"):
            raise ValueError(
                f"reasoning_effort must be xhigh, medium or low, not {reasoning_effort!r}"
            )
        if tokenizer is not None and getattr(tokenizer, "chat_template", None):
            kwargs = {"enable_thinking": bool(enable_thinking)}
            if reasoning_effort:
                kwargs["reasoning_effort"] = reasoning_effort
            return tokenizer.apply_chat_template(
                messages, add_generation_prompt=True, tokenize=False, **kwargs
            )
        last_user = ""
        for m in reversed(messages):
            if m.get("role") == "user":
                last_user = m.get("content") or ""
                break
        return self._apply_chat_template(
            self.processor, self._chat_config(self.config), last_user, num_images=0
        )

    def complete(self, messages, max_tokens, temperature, top_p, top_k,
                 enable_thinking=True, reasoning_effort=None):
        prompt = self.build_prompt(messages, enable_thinking, reasoning_effort)
        with GEN_LOCK:
            out = self._generate(
                self.model,
                self.processor,
                prompt,
                [],  # text only; the HTTP path does not carry images
                max_tokens=max_tokens,
                temperature=temperature,
                top_p=top_p,
                top_k=top_k,
                verbose=False,
            )
        text = out if isinstance(out, str) else getattr(out, "text", str(out))
        usage = {
            "prompt_tokens": getattr(out, "prompt_tokens", 0) or 0,
            "completion_tokens": getattr(out, "generation_tokens", 0) or 0,
            "total_tokens": 0,
        }
        usage["total_tokens"] = usage["prompt_tokens"] + usage["completion_tokens"]
        return text.strip(), usage


class Handler(BaseHTTPRequestHandler):
    server_version = "bonsai2-mlx"
    protocol_version = "HTTP/1.1"

    # Injected by serve().
    bonsai = None
    model_id = "bonsai2-27b-mlx"

    def log_message(self, fmt, *args):
        sys.stderr.write("%s - %s\n" % (self.address_string(), fmt % args))

    def _send_json(self, code, payload):
        body = json.dumps(payload).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _error(self, code, message, err_type="invalid_request_error"):
        self._send_json(code, {"error": {"message": message, "type": err_type, "code": code}})

    def do_GET(self):
        if self.path.rstrip("/") in ("/health", "/v1/health"):
            self._send_json(200, {"status": "ok", "model": self.model_id})
        elif self.path.rstrip("/") == "/v1/models":
            self._send_json(200, {
                "object": "list",
                "data": [{
                    "id": self.model_id,
                    "object": "model",
                    "created": int(time.time()),
                    "owned_by": "prism-ml",
                }],
            })
        else:
            self._error(404, f"Unknown path {self.path}", "not_found")

    def do_POST(self):
        if self.path.rstrip("/") != "/v1/chat/completions":
            return self._error(404, f"Unknown path {self.path}", "not_found")

        try:
            length = int(self.headers.get("Content-Length") or 0)
            req = json.loads(self.rfile.read(length) or b"{}")
        except (ValueError, TypeError) as exc:
            return self._error(400, f"Malformed JSON body: {exc}")

        messages = req.get("messages")
        if not isinstance(messages, list) or not messages:
            return self._error(400, "'messages' must be a non-empty list")

        d = self.bonsai.defaults
        max_tokens = int(req.get("max_tokens") or d["max_tokens"])
        temperature = float(req.get("temperature", d["temp"]))
        top_p = float(req.get("top_p", d["top_p"]))
        # `top_k` is not an OpenAI field; mlx-vlm takes it, so honour it when a client sends it.
        top_k = int(req.get("top_k") or d["top_k"])

        # Thinking. Three ways in, because clients disagree about where this goes:
        #   - a top-level `enable_thinking` / `reasoning_effort` (plainest)
        #   - `chat_template_kwargs` (what vLLM and SGLang clients send)
        #   - nothing at all, which leaves the pack's own default: thinking on, effort xhigh
        ctk = req.get("chat_template_kwargs") or {}
        if not isinstance(ctk, dict):
            ctk = {}
        enable_thinking = req.get("enable_thinking", ctk.get("enable_thinking", d["enable_thinking"]))
        reasoning_effort = req.get("reasoning_effort", ctk.get("reasoning_effort", d["reasoning_effort"]))
        if reasoning_effort is not None and reasoning_effort not in ("xhigh", "medium", "low"):
            return self._error(400, "reasoning_effort must be xhigh, medium or low")

        cid = "chatcmpl-" + uuid.uuid4().hex[:24]
        created = int(time.time())

        try:
            text, usage = self.bonsai.complete(
                messages, max_tokens, temperature, top_p, top_k,
                bool(enable_thinking), reasoning_effort,
            )
        except Exception as exc:  # surface the real reason rather than a bare 500
            return self._error(500, f"{type(exc).__name__}: {exc}", "server_error")

        if not req.get("stream"):
            return self._send_json(200, {
                "id": cid,
                "object": "chat.completion",
                "created": created,
                "model": self.model_id,
                "choices": [{
                    "index": 0,
                    "message": {"role": "assistant", "content": text},
                    "finish_reason": "stop",
                }],
                "usage": usage,
            })

        # Streaming is chunked, not incremental: generation already finished above, so this
        # replays the text as SSE. Clients that require streaming get a valid stream with one
        # content delta. Token-by-token output would need mlx_vlm.stream_generate, which is a
        # different call and is not verified for this pack.
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Cache-Control", "no-cache")
        self.send_header("Connection", "close")
        self.end_headers()

        def event(payload):
            self.wfile.write(b"data: " + json.dumps(payload).encode() + b"\n\n")
            self.wfile.flush()

        base = {"id": cid, "object": "chat.completion.chunk", "created": created,
                "model": self.model_id}
        event({**base, "choices": [{"index": 0, "delta": {"role": "assistant"},
                                    "finish_reason": None}]})
        event({**base, "choices": [{"index": 0, "delta": {"content": text},
                                    "finish_reason": None}]})
        event({**base, "choices": [{"index": 0, "delta": {}, "finish_reason": "stop"}]})
        self.wfile.write(b"data: [DONE]\n\n")
        self.wfile.flush()


def serve(args):
    bonsai = Bonsai(args.model, {
        "max_tokens": args.max_tokens,
        "temp": args.temp,
        "top_p": args.top_p,
        "top_k": args.top_k,
        "enable_thinking": not args.no_think,
        "reasoning_effort": args.reasoning_effort,
    })
    Handler.bonsai = bonsai
    Handler.model_id = args.served_model_name

    httpd = ThreadingHTTPServer((args.host, args.port), Handler)
    httpd.daemon_threads = True
    print(f"\n  Bonsai 2 MLX server on http://{args.host}:{args.port}/v1", file=sys.stderr)
    print(f"  model id: {args.served_model_name}\n", file=sys.stderr)
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        print("\nstopping", file=sys.stderr)


def main():
    parser = argparse.ArgumentParser(
        description="OpenAI-compatible MLX server for Bonsai 2 packs (text only, untested).",
        epilog="""check it with:
  curl http://127.0.0.1:8080/v1/chat/completions \\
    -H 'Content-Type: application/json' \\
    -d '{"messages":[{"role":"user","content":"What is the capital of France?"}]}'

then point a coding agent at http://127.0.0.1:8080/v1""",
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    parser.add_argument("--model", required=True, help="the pack directory (.. from upstream-demo/)")
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=8080)
    parser.add_argument("--served-model-name", default="bonsai2-27b-mlx")
    parser.add_argument("--max-tokens", type=int, default=DEFAULTS["max_tokens"])
    parser.add_argument("--temp", type=float, default=DEFAULTS["temp"])
    parser.add_argument("--top-p", type=float, default=DEFAULTS["top_p"])
    parser.add_argument("--top-k", type=int, default=DEFAULTS["top_k"])
    parser.add_argument("--no-think", action="store_true",
                        help="default every request to enable_thinking=false")
    parser.add_argument("--reasoning-effort", choices=("xhigh", "medium", "low"), default=None,
                        help="default reasoning effort (the pack's own default is xhigh)")
    serve(parser.parse_args())


if __name__ == "__main__":
    main()
