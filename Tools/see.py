#!/usr/bin/env python3
"""Give the agent eyes on a rendered frame.

Sends a PNG to a vision model via the LiteLLM relay and prints the reply, so art
direction (fog density, light colour, framing, whether the scene reads as a wet
tropical night) can actually be judged instead of guessed at from pixel stats.

Usage:
  ./Tools/see.py shot.png
  ./Tools/see.py shot.png "What is wrong with this render?"
  ./Tools/see.py shot.png -m gemini-3.5-flash
  ./Tools/see.py a.png b.png c.png          # compare several frames
  ./Tools/see.py shot.png -b openrouter     # route via OpenRouter instead

Backends: litellm (default, http://100.81.147.15:4000) or openrouter.
The OpenRouter key is read from $OPENROUTER_API_KEY or
~/.config/cairns/openrouter.key - never from inside the repo.
"""
import base64
import json
import os
import sys
import urllib.error
import urllib.request

ENDPOINT = os.environ.get("LITELLM_URL", "http://100.81.147.15:4000/v1/chat/completions")
API_KEY = os.environ.get("LITELLM_KEY", "dummy")
DEFAULT_MODEL = os.environ.get("LITELLM_VISION_MODEL", "gemini-3.5-flash")

# Second, independent backend. Same OpenAI-shaped payload, different host.
OPENROUTER_URL = "https://openrouter.ai/api/v1/chat/completions"
OPENROUTER_MODEL = os.environ.get("OPENROUTER_VISION_MODEL", "stealth/space-bunny-alpha")
OPENROUTER_KEY_FILE = os.path.expanduser("~/.config/cairns/openrouter.key")


def _openrouter_key() -> str:
    if os.environ.get("OPENROUTER_API_KEY"):
        return os.environ["OPENROUTER_API_KEY"]
    try:
        with open(OPENROUTER_KEY_FILE) as fh:
            return fh.read().strip()
    except OSError:
        return ""

DEFAULT_PROMPT = (
    "You are the art director for a night-time street racing game set in tropical "
    "Queensland, Australia (Cairns / Manunda). Describe this game render "
    "concretely and critically: what is in frame, the lighting, colour palette, "
    "atmosphere, materials, and whether it reads as a convincing hot humid wet "
    "night in a low-rise tropical suburb. Point out the three biggest things "
    "that look wrong or cheap. Be specific and terse."
)


def encode(path: str) -> str:
    with open(path, "rb") as fh:
        return base64.b64encode(fh.read()).decode("ascii")


def ask(paths, prompt: str, model: str, backend: str = "litellm") -> str:
    content = [{"type": "text", "text": prompt}]
    for p in paths:
        content.append({"type": "image_url", "image_url": {"url": f"data:image/png;base64,{encode(p)}"}})

    if backend == "openrouter":
        url, key = OPENROUTER_URL, _openrouter_key()
        if not key:
            raise RuntimeError("no OpenRouter key: set OPENROUTER_API_KEY or write ~/.config/cairns/openrouter.key")
        model = model or OPENROUTER_MODEL
        headers = {"HTTP-Referer": "https://cairnsafterdark.local", "X-Title": "CAIRNS AFTER DARK"}
    else:
        url, key = ENDPOINT, API_KEY
        model = model or DEFAULT_MODEL
        headers = {}

    body = {
        "model": model,
        "messages": [{"role": "user", "content": content}],
        "max_tokens": 1200,
    }
    req = urllib.request.Request(
        url,
        data=json.dumps(body).encode(),
        headers={**headers, "Content-Type": "application/json", "Authorization": f"Bearer {key}"},
    )
    with urllib.request.urlopen(req, timeout=240) as resp:
        data = json.loads(resp.read().decode())
    return data["choices"][0]["message"]["content"]


def main() -> int:
    argv = sys.argv[1:]
    model, prompt, backend = "", None, "litellm"
    images = []

    i = 0
    while i < len(argv):
        a = argv[i]
        if a in ("-m", "--model") and i + 1 < len(argv):
            model = argv[i + 1]
            i += 2
            continue
        if a in ("-b", "--backend") and i + 1 < len(argv):
            backend = argv[i + 1]
            i += 2
            continue
        # An argument is an image if it is an existing image file; everything
        # else is part of the prompt. Order does not matter.
        if os.path.exists(a) and a.lower().endswith((".png", ".jpg", ".jpeg", ".webp")):
            images.append(a)
        else:
            prompt = (prompt + " " + a).strip() if prompt else a
        i += 1

    if not images:
        print(__doc__)
        return 2
    for p in images:
        if not os.path.exists(p):
            print(f"missing: {p}")
            return 1
    try:
        print(ask(images, prompt or DEFAULT_PROMPT, model, backend))
    except urllib.error.HTTPError as e:
        print(f"HTTP {e.code}: {e.read().decode()[:400]}")
        return 1
    except Exception as e:  # noqa: BLE001
        print(f"failed: {type(e).__name__}: {e}")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
