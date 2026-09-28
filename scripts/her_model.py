"""Shared by the roadmap 3.2 and 3.4 scripts: calling Her's chat model and
serving a local page whose marks are written back to a JSON file.

The model is one setting (any OpenAI-compatible endpoint). The user approved
sending excerpts to whatever model Her uses, not to one vendor (2026-09-28).
The key comes from Her's Keychain item; it is never printed or written.
"""
from __future__ import annotations

import argparse
import http.server
import json
import subprocess
import sys
import time
import urllib.request
from pathlib import Path

DEFAULT_ENDPOINT = "https://api.stepfun.com/step_plan/v1/chat/completions"
DEFAULT_MODEL = "step-3.7-flash"
DEFAULT_KEY_ACCOUNT = "stepfunAPIKey"


def add_model_arguments(parser: argparse.ArgumentParser) -> None:
    parser.add_argument("--endpoint", default=DEFAULT_ENDPOINT, help="OpenAI-compatible chat completions URL")
    parser.add_argument("--model", default=DEFAULT_MODEL)
    parser.add_argument("--key-account", default=DEFAULT_KEY_ACCOUNT, help="account of the key in Her's Keychain")


class HerModel:
    def __init__(self, endpoint: str, model: str, key_account: str):
        self.endpoint = endpoint
        self.model = model
        completed = subprocess.run(["security", "find-generic-password", "-s", "com.yishuziyu.her",
                                    "-a", key_account, "-w"], capture_output=True, text=True)
        if completed.returncode != 0 or not completed.stdout.strip():
            sys.exit(f"没读到 Her 钥匙串里的 {key_account}（拒绝或不存在），什么都没发出去。")
        self._key = completed.stdout.strip()

    @classmethod
    def from_arguments(cls, arguments: argparse.Namespace) -> "HerModel":
        return cls(arguments.endpoint, arguments.model, arguments.key_account)

    def ask_json(self, system: str, user: str, max_tokens: int = 6000) -> dict:
        """One JSON answer, or {} after three failed tries (network, refusal, unreadable JSON)."""
        body = json.dumps({"model": self.model, "messages": [{"role": "system", "content": system},
                                                             {"role": "user", "content": user}],
                           "max_tokens": max_tokens, "temperature": 0.2, "reasoning_effort": "low",
                           "response_format": {"type": "json_object"}}).encode()
        for attempt in range(3):
            request = urllib.request.Request(self.endpoint, data=body, headers={
                "Authorization": f"Bearer {self._key}", "Content-Type": "application/json"})
            try:
                with urllib.request.urlopen(request, timeout=180) as response:
                    content = json.load(response)["choices"][0]["message"]["content"]
                return json.loads(content[content.index("{"):content.rindex("}") + 1])
            except Exception as error:
                if attempt == 2:
                    print(f"  一批没有结果：{error}", file=sys.stderr)
                    return {}
                time.sleep(3)
        return {}


def serve_marking_page(folder: Path, port: int) -> None:
    """Serves `folder`; a POST to /<name>.json overwrites that file there."""
    class Handler(http.server.SimpleHTTPRequestHandler):
        def __init__(self, *args, **kwargs):
            super().__init__(*args, directory=str(folder), **kwargs)

        def do_POST(self):
            name = Path(self.path).name
            if not name.endswith(".json"):
                self.send_response(404)
                self.end_headers()
                return
            (folder / name).write_bytes(self.rfile.read(int(self.headers["Content-Length"])))
            self.send_response(204)
            self.end_headers()

        def log_message(self, *args):
            pass

    server = http.server.ThreadingHTTPServer(("127.0.0.1", port), Handler)
    print(f"http://127.0.0.1:{port}/  （标记写回 {folder}；Ctrl+C 结束）")
    server.serve_forever()
