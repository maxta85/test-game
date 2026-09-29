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


def ask(paths, prompt: str, model: str) -> str:
    content = [{"type": "text", "text": prompt}]
    for p in paths:
        content.append({"type": "image_url", "image_url": {"url": f"data:image/png;base64,{encode(p)}"}})

    body = {
        "model": model,
        "messages": [{"role": "user", "content": content}],
        "max_tokens": 1200,
    }
    req = urllib.request.Request(
        ENDPOINT,
        data=json.dumps(body).encode(),
        headers={"Content-Type": "application/json", "Authorization": f"Bearer {API_KEY}"},
    )
    with urllib.request.urlopen(req, timeout=180) as resp:
        data = json.loads(resp.read().decode())
    return data["choices"][0]["message"]["content"]


def main() -> int:
    argv = sys.argv[1:]
    model, prompt = DEFAULT_MODEL, None
    images = []

    i = 0
    while i < len(argv):
        a = argv[i]
        if a in ("-m", "--model") and i + 1 < len(argv):
            model = argv[i + 1]
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
        print(ask(images, prompt or DEFAULT_PROMPT, model))
    except urllib.error.HTTPError as e:
        print(f"HTTP {e.code}: {e.read().decode()[:400]}")
        return 1
    except Exception as e:  # noqa: BLE001
        print(f"failed: {type(e).__name__}: {e}")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
