#!/usr/bin/env python3
"""Small OpenAI-compatible client for redeem.

`complete` sends one chat turn and writes a JSON result.
`repl` continues that conversation on stdin.
"""

from __future__ import annotations

import argparse
import json
import sys
import urllib.error
import urllib.request


def post_chat(url: str, body: dict, api_key: str, timeout: int) -> dict:
    data = json.dumps(body).encode("utf-8")
    headers = {"Content-Type": "application/json"}
    if api_key:
        headers["Authorization"] = f"Bearer {api_key}"
    last_error = None
    for attempt in (body, without_template_kwargs(body)):
        req = urllib.request.Request(
            url.rstrip("/") + "/v1/chat/completions",
            data=json.dumps(attempt).encode("utf-8"),
            headers=headers,
            method="POST",
        )
        try:
            with urllib.request.urlopen(req, timeout=timeout) as resp:
                return json.loads(resp.read().decode("utf-8"))
        except urllib.error.HTTPError as exc:
            detail = exc.read().decode("utf-8", "replace")
            last_error = f"HTTP {exc.code}: {detail[:800]}"
            if exc.code == 400 and "chat_template_kwargs" in detail and "chat_template_kwargs" in attempt:
                continue
            raise SystemExit(last_error) from exc
        except urllib.error.URLError as exc:
            raise SystemExit(f"request failed: {exc}") from exc
    raise SystemExit(last_error or "request failed")


def without_template_kwargs(body: dict) -> dict:
    copy = dict(body)
    copy.pop("chat_template_kwargs", None)
    return copy


def message_text(payload: dict) -> tuple[str, str]:
    choices = payload.get("choices") or []
    if not choices:
        return "", ""
    message = choices[0].get("message") or {}
    content = message.get("content") or ""
    if isinstance(content, list):
        parts = []
        for item in content:
            if isinstance(item, str):
                parts.append(item)
            elif isinstance(item, dict):
                parts.append(str(item.get("text") or ""))
        content = "\n".join(parts)
    reasoning = message.get("reasoning_content") or ""
    return str(content), str(reasoning)


def build_body(system: str, messages: list[dict], max_tokens: int, temperature: float) -> dict:
    full = [{"role": "system", "content": system}] + messages
    return {
        "messages": full,
        "temperature": temperature,
        "max_tokens": max_tokens,
        "stream": False,
        "chat_template_kwargs": {"enable_thinking": False},
    }


def result_from(payload: dict) -> dict:
    content, reasoning = message_text(payload)
    timings = payload.get("timings") or {}
    usage = payload.get("usage") or {}
    return {
        "content": content,
        "reasoning": reasoning,
        "text": content if content.strip() else reasoning,
        "timings": timings,
        "usage": usage,
    }


def read_text(path: str) -> str:
    with open(path, encoding="utf-8") as handle:
        return handle.read()


def cmd_complete(args: argparse.Namespace) -> int:
    system = read_text(args.system_file)
    user = read_text(args.user_file)
    payload = post_chat(
        args.url,
        build_body(system, [{"role": "user", "content": user}], args.max_tokens, args.temperature),
        args.api_key,
        args.timeout,
    )
    result = result_from(payload)
    encoded = json.dumps(result, indent=2)
    if args.out_json:
        with open(args.out_json, "w", encoding="utf-8") as handle:
            handle.write(encoded)
            handle.write("\n")
    sys.stdout.write(result["text"])
    if result["text"] and not result["text"].endswith("\n"):
        sys.stdout.write("\n")
    return 0


def cmd_repl(args: argparse.Namespace) -> int:
    system = read_text(args.system_file)
    messages: list[dict] = []
    if args.user_file:
        messages.append({"role": "user", "content": read_text(args.user_file)})
    if args.reply_file:
        messages.append({"role": "assistant", "content": read_text(args.reply_file)})
    print("redeem chat. /quit to stop. The server stays read-only until you agree to a write.", flush=True)
    while True:
        try:
            line = input("you> ")
        except EOFError:
            print()
            return 0
        if line.strip() in {"/quit", "/exit"}:
            return 0
        if not line.strip():
            continue
        messages.append({"role": "user", "content": line})
        payload = post_chat(
            args.url,
            build_body(system, messages, args.max_tokens, args.temperature),
            args.api_key,
            args.timeout,
        )
        result = result_from(payload)
        text = result["text"].rstrip()
        print(text, flush=True)
        messages.append({"role": "assistant", "content": text})


def main() -> int:
    parser = argparse.ArgumentParser(description="redeem chat client")
    parser.add_argument("--url", required=True)
    parser.add_argument("--system-file", required=True)
    parser.add_argument("--api-key", default="")
    parser.add_argument("--max-tokens", type=int, default=360)
    parser.add_argument("--temperature", type=float, default=0.2)
    parser.add_argument("--timeout", type=int, default=240)
    sub = parser.add_subparsers(dest="cmd", required=True)

    complete = sub.add_parser("complete")
    complete.add_argument("--user-file", required=True)
    complete.add_argument("--out-json", default="")
    complete.set_defaults(func=cmd_complete)

    repl = sub.add_parser("repl")
    repl.add_argument("--user-file", default="")
    repl.add_argument("--reply-file", default="")
    repl.set_defaults(func=cmd_repl)

    args = parser.parse_args()
    return args.func(args)


if __name__ == "__main__":
    raise SystemExit(main())
