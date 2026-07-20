#!/usr/bin/env python3
"""Analyze a local image through an OpenRouter vision model.

The helper deliberately keeps the provider call outside Claude Code's main
model route. It returns bounded text so the calling session can decide what to
do with the visual evidence.
"""

from __future__ import annotations

import argparse
import base64
import json
import mimetypes
import os
import subprocess
import sys
import time
import uuid
from pathlib import Path
from urllib.error import HTTPError, URLError
from urllib.request import ProxyHandler, Request, build_opener


DEFAULT_MODEL = "google/gemini-3-flash-preview"
DEFAULT_ENDPOINT = "https://openrouter.ai/api/v1/chat/completions"
MAX_IMAGE_BYTES = 25 * 1024 * 1024
MAX_PROMPT_CHARS = 4000


def fail(message: str) -> "NoReturn":
    print(f"pm-imageinput: {message}", file=sys.stderr)
    raise SystemExit(1)


def image_mime(path: Path) -> str:
    mime, _ = mimetypes.guess_type(path.name)
    if mime not in {"image/png", "image/jpeg", "image/webp", "image/gif"}:
        fail("image must be PNG, JPEG, WebP, or GIF")
    return mime


def jobs_root() -> Path:
    try:
        common_dir = subprocess.check_output(
            ["git", "rev-parse", "--path-format=absolute", "--git-common-dir"],
            text=True,
            stderr=subprocess.DEVNULL,
        ).strip()
        root = Path(common_dir) / "pm-handoffs" / "imageinput-jobs"
    except (OSError, subprocess.CalledProcessError):
        root = Path.cwd() / ".claude" / "imageinput-jobs"
    root.mkdir(parents=True, exist_ok=True)
    return root


def status_path(job_id: str) -> Path:
    return jobs_root() / f"{job_id}.json"


def write_status(job_id: str, **values: object) -> None:
    target = status_path(job_id)
    current: dict[str, object] = {}
    if target.exists():
        try:
            current = json.loads(target.read_text())
        except json.JSONDecodeError:
            current = {}
    current.update(values)
    temp = target.with_suffix(f".json.tmp.{os.getpid()}")
    temp.write_text(json.dumps(current, ensure_ascii=False, indent=2) + "\n")
    temp.replace(target)


def parse_content(response: dict[str, object]) -> str:
    choices = response.get("choices")
    if not isinstance(choices, list) or not choices:
        fail("OpenRouter response did not contain choices")
    message = choices[0].get("message") if isinstance(choices[0], dict) else None
    content = message.get("content") if isinstance(message, dict) else None
    if isinstance(content, str):
        return content.strip()
    if isinstance(content, list):
        parts = [item.get("text", "") for item in content if isinstance(item, dict)]
        return "\n".join(part for part in parts if isinstance(part, str)).strip()
    fail("OpenRouter response did not contain text content")


def analyze(image: Path, prompt: str) -> str:
    api_key = os.environ.get("OPENROUTER_API_KEY", "").strip()
    if not api_key:
        fail("OPENROUTER_API_KEY is not configured")
    if image.stat().st_size > MAX_IMAGE_BYTES:
        fail(f"image exceeds {MAX_IMAGE_BYTES // (1024 * 1024)} MiB")

    mime = image_mime(image)
    encoded = base64.b64encode(image.read_bytes()).decode("ascii")
    model = os.environ.get("OPENROUTER_VISION_MODEL", DEFAULT_MODEL)
    endpoint = os.environ.get("OPENROUTER_VISION_ENDPOINT", DEFAULT_ENDPOINT)
    payload = {
        "model": model,
        "messages": [
            {
                "role": "user",
                "content": [
                    {"type": "text", "text": prompt},
                    {
                        "type": "image_url",
                        "image_url": {"url": f"data:{mime};base64,{encoded}"},
                    },
                ],
            }
        ],
        "max_tokens": int(os.environ.get("OPENROUTER_VISION_MAX_TOKENS", "1600")),
        "stream": False,
    }
    if os.environ.get("PM_IMAGEINPUT_DRY_RUN") == "1":
        return (
            f"[dry-run] model={model}\n"
            f"image={image}\n"
            f"bytes={image.stat().st_size}\n"
            f"prompt={prompt}"
        )

    headers = {
        "Authorization": f"Bearer {api_key}",
        "Content-Type": "application/json",
        "X-OpenRouter-Title": "Claude Code PM Image Input",
    }
    referer = os.environ.get("OPENROUTER_HTTP_REFERER")
    if referer:
        headers["HTTP-Referer"] = referer
    request = Request(endpoint, data=json.dumps(payload).encode(), headers=headers, method="POST")
    opener = (
        build_opener()
        if os.environ.get("OPENROUTER_VISION_USE_PROXY") == "1"
        else build_opener(ProxyHandler({}))
    )
    try:
        with opener.open(request, timeout=int(os.environ.get("OPENROUTER_VISION_TIMEOUT", "60"))) as response:
            body = json.loads(response.read().decode("utf-8"))
    except HTTPError as error:
        detail = error.read().decode("utf-8", errors="replace")[:1000]
        fail(f"OpenRouter HTTP {error.code}: {detail}")
    except (URLError, TimeoutError) as error:
        fail(f"OpenRouter request failed: {error}")
    return parse_content(body)


def run(image_arg: str, prompt: str, job_id: str | None = None) -> int:
    image = Path(image_arg).expanduser().resolve()
    if not image.is_file():
        fail(f"image not found: {image}")
    image_mime(image)
    if not prompt.strip():
        fail("analysis prompt is empty")
    if len(prompt) > MAX_PROMPT_CHARS:
        fail(f"prompt exceeds {MAX_PROMPT_CHARS} characters")
    if job_id:
        write_status(job_id, state="running", pid=os.getpid(), started_at=int(time.time()))
    try:
        result = analyze(image, prompt)
        output = (
            "# Image Analysis\n\n"
            f"- Image: `{image}`\n"
            f"- Model: `{os.environ.get('OPENROUTER_VISION_MODEL', DEFAULT_MODEL)}`\n"
            "- Provider: `OpenRouter`\n\n"
            "## Analysis\n\n"
            f"{result}\n"
        )
        if job_id:
            output_path = jobs_root() / f"{job_id}.md"
            output_path.write_text(output)
            write_status(job_id, state="completed", finished_at=int(time.time()), output=str(output_path))
        else:
            print(output, end="")
        return 0
    except SystemExit:
        if job_id:
            write_status(job_id, state="failed", finished_at=int(time.time()))
        raise


def start(image: str, prompt: str) -> int:
    job_id = f"image-{time.strftime('%Y%m%d-%H%M%S')}-{uuid.uuid4().hex[:8]}"
    write_status(job_id, state="queued", image=str(Path(image).expanduser().resolve()), prompt=prompt)
    log_path = jobs_root() / f"{job_id}.log"
    log = log_path.open("w")
    process = subprocess.Popen(
        [sys.executable, str(Path(__file__).resolve()), "run", image, prompt, "--job-id", job_id],
        stdout=log,
        stderr=subprocess.STDOUT,
        start_new_session=True,
    )
    log.close()
    write_status(job_id, pid=process.pid, log=str(log_path))
    print(f"job_id={job_id} state=queued")
    return 0


def show_status(job_id: str, read_output: bool = False) -> int:
    target = status_path(job_id)
    if not target.exists():
        fail(f"unknown job: {job_id}")
    data = json.loads(target.read_text())
    if read_output and data.get("state") == "completed":
        print(Path(str(data["output"])).read_text(), end="")
    else:
        print(json.dumps(data, ensure_ascii=False, indent=2))
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description="Analyze a local image with OpenRouter")
    subparsers = parser.add_subparsers(dest="command", required=True)
    for name in ("run", "start"):
        sub = subparsers.add_parser(name)
        sub.add_argument("image")
        sub.add_argument("prompt")
        if name == "run":
            sub.add_argument("--job-id")
    for name, read_output in (("status", False), ("read", True)):
        sub = subparsers.add_parser(name)
        sub.add_argument("job_id")
        sub.set_defaults(read_output=read_output)
    args = parser.parse_args()
    if args.command == "run":
        return run(args.image, args.prompt, args.job_id)
    if args.command == "start":
        return start(args.image, args.prompt)
    return show_status(args.job_id, args.read_output)


if __name__ == "__main__":
    raise SystemExit(main())
