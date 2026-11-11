"""Helpers for calling the configured Ollama API."""

import base64
import json
import os
from urllib.error import HTTPError
from urllib.request import Request, urlopen


DEFAULT_OLLAMA_BASE_URL = "http://localhost:11434"


def get_ollama_base_url():
    """Return the configured Ollama server URL, with a local default."""
    configured_url = os.getenv("OLLAMA_BASE_URL", "").strip().rstrip("/")
    return configured_url or DEFAULT_OLLAMA_BASE_URL


def get_ollama_api_url(path):
    """Return an absolute URL for an Ollama API path."""
    return f"{get_ollama_base_url()}/{path.lstrip('/')}"


def _chat(model, content, image=None):
    message = {"role": "user", "content": content}
    if image is not None:
        message["images"] = [base64.b64encode(image).decode("ascii")]
    request = Request(
        get_ollama_api_url("api/chat"),
        data=json.dumps({"model": model, "messages": [message], "stream": False}).encode(),
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    try:
        with urlopen(request, timeout=120) as response:
            data = json.load(response)
    except HTTPError as exc:
        body = exc.read().decode("utf-8", errors="replace")
        try:
            detail = json.loads(body).get("error", body)
        except ValueError:
            detail = body
        raise ValueError(f"Ollama HTTP {exc.code}: {str(detail)[:500]}") from exc
    result = data.get("message", {}).get("content", "").strip()
    if not result:
        raise ValueError("Ollama returned an empty response. Check the model and try again.")
    return result


def narrate_frames(model, frames, prompt):
    """Describe frames separately for single-image vision models, then draft a script."""
    descriptions = []
    for index, frame in enumerate(frames, 1):
        description = _chat(
            model, f"Describe the visible scene in this video frame {index} of {len(frames)} "
            "in one or two factual sentences. Do not invent audio or dialogue.", frame,
        )
        descriptions.append(f"Frame {index}: {description}")
    return _chat(model, f"{prompt}\n\nChronological visual observations:\n" + "\n".join(descriptions))


def storyboard_scene_text(model, script_line):
    """Create a short visual direction for local storyboard cards."""
    prompt = (
        "Write one concise cinematic visual direction for this narration line. "
        "Return plain text only, max 24 words, no markdown, no camera jargon list. "
        "Narration line: " + script_line
    )
    return _chat(model, prompt)