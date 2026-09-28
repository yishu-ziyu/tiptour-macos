#!/usr/bin/env python3
"""Roadmap 3.2, offline run: find what the user cares about from their own words.

Reads only what the user typed in Claude Code and Codex, commit subjects of the
git projects under ~/Desktop/AI 产品, and recently edited Obsidian notes (last
30 days; Obsidian 90). Keys, e-mail addresses and phone numbers are removed
before anything leaves the machine. Excerpts go to whichever chat model Her
uses (today StepFun step-3.7-flash; any OpenAI-compatible endpoint works, set
by --endpoint/--model/--key-account). The user approved sending excerpts to
Her's model, not to one vendor (2026-09-28). The model only proposes directions with material IDs,
and this script keeps a direction only when its quotes are really in the
material, from at least two places on at least two days.

The key is read from Her's Keychain item at run time (macOS asks once); it is
never printed or written.

  python3 scripts/interest-discovery.py            # writes out/interest-discovery/<date>/
  python3 scripts/interest-discovery.py --serve    # then opens the page for marking
"""
from __future__ import annotations

import argparse
import concurrent.futures
import datetime
import hashlib
import glob
import http.server
import json
import os
import re
import subprocess
import sys
import threading
import time
import urllib.request
from collections import defaultdict
from pathlib import Path

REPOSITORY_ROOT = Path(__file__).resolve().parent.parent
HOME = Path.home()
PROJECTS_FOLDER = HOME / "Desktop" / "AI 产品"
OBSIDIAN_FOLDER = HOME / "Desktop" / "黑曜石"
ENDPOINT = "https://api.stepfun.com/step_plan/v1/chat/completions"
MODEL = "step-3.7-flash"
DAYS = 30
MESSAGES_PER_BATCH = 90
CHARACTERS_PER_MESSAGE = 280
DIRECTION_COUNT = 10

SECRET_PATTERNS = [
    (re.compile(r"(sk|pk|rk|ghp|gho|xox[abp])[-_][A-Za-z0-9_\-]{12,}"), "〔密钥〕"),
    (re.compile(r"\b[A-Za-z0-9+/=_\-]{32,}\b"), "〔长串〕"),
    (re.compile(r"[\w.+-]+@[\w-]+\.[\w.-]+"), "〔邮箱〕"),
    (re.compile(r"(?<!\d)1[3-9]\d{9}(?!\d)"), "〔手机号〕"),
]


# Text that reaches the logs as a "user" message without the user typing it:
# Her's own hand-off prompt and test fixtures, terminal pane references, tool
# errors, hand-back notes and automatic conversation summaries.
NOT_TYPED_BY_USER = ("Her 已建立", "workspace_ref=", "Codex could not", "这个仓库这两天由外部工具",
                     "Files pasted by the user", "This session is being continued", "disposable local Her",
                     "acceptance fixture")


def redact(text: str) -> str:
    for pattern, replacement in SECRET_PATTERNS:
        text = pattern.sub(replacement, text)
    return text


def typed_text(raw: str) -> str | None:
    """The user's own words: no injected blocks, pasted files, code or images."""
    text = re.sub(r"<([a-zA-Z_-]+)[^>]*>.*?</\1>", " ", raw, flags=re.S)
    text = re.sub(r"```.*?```", " ", text, flags=re.S)
    # 【…】 quotes something else (usually an assistant's reply); keep only what the user added.
    text = re.sub(r"【.*?】", " ", text, flags=re.S)
    text = text.strip()
    if any(marker in text for marker in NOT_TYPED_BY_USER):
        return None
    if not text or text.startswith(("<", "#", "[Image", "Caveat:", "[Request interrupted")):
        return None
    if len(text) < 4 or text.lower() in {"ok", "继续", "好的", "可以", "是的", "y", "yes"}:
        return None
    return redact(re.sub(r"\s+", " ", text))[:CHARACTERS_PER_MESSAGE]


def claude_messages(since: float) -> list[dict]:
    messages = []
    for path in glob.glob(str(HOME / ".claude/projects/*/*.jsonl")):
        if os.path.getmtime(path) < since:
            continue
        for line in open(path, errors="ignore"):
            try:
                entry = json.loads(line)
            except json.JSONDecodeError:
                continue
            if entry.get("type") != "user" or entry.get("isMeta"):
                continue
            content = entry.get("message", {}).get("content")
            if isinstance(content, list):
                content = " ".join(part.get("text", "") for part in content if part.get("type") == "text")
            if not isinstance(content, str) or not (text := typed_text(content)):
                continue
            messages.append({"source": "Claude Code", "date": entry.get("timestamp", "")[:10],
                             "project": os.path.basename(entry.get("cwd", "")) or "?", "text": text})
    return messages


def codex_messages(since: float) -> list[dict]:
    messages = []
    for path in glob.glob(str(HOME / ".codex/sessions/**/*.jsonl"), recursive=True):
        if os.path.getmtime(path) < since:
            continue
        project = "?"
        for line in open(path, errors="ignore"):
            try:
                entry = json.loads(line)
            except json.JSONDecodeError:
                continue
            payload = entry.get("payload", {})
            if entry.get("type") == "session_meta":
                project = os.path.basename(payload.get("cwd", "")) or "?"
            if entry.get("type") != "response_item" or payload.get("type") != "message" or payload.get("role") != "user":
                continue
            raw = " ".join(part.get("text", "") for part in payload.get("content", []))
            if text := typed_text(raw):
                messages.append({"source": "Codex", "date": entry.get("timestamp", "")[:10], "project": project, "text": text})
    return messages


def commit_subjects() -> list[dict]:
    messages = []
    for git_folder in PROJECTS_FOLDER.glob("*/.git"):
        repository = git_folder.parent
        log = subprocess.run(["git", "-C", str(repository), "log", f"--since={DAYS}.days", "--date=short",
                              "--pretty=%ad\t%s", "--no-merges"], capture_output=True, text=True).stdout
        for line in log.splitlines():
            date, _, subject = line.partition("\t")
            if subject:
                messages.append({"source": "git 提交", "date": date, "project": repository.name, "text": redact(subject)[:200]})
    return messages


def obsidian_notes() -> list[dict]:
    since = time.time() - 90 * 86400
    notes = []
    for path in OBSIDIAN_FOLDER.rglob("*.md"):
        if ".obsidian" in path.parts or path.stat().st_mtime < since:
            continue
        body = re.sub(r"^---.*?---", "", path.read_text(errors="ignore"), flags=re.S)
        if text := typed_text(body):
            date = datetime.date.fromtimestamp(path.stat().st_mtime).isoformat()
            notes.append({"source": "Obsidian", "date": date, "project": path.stem, "text": text})
    return notes


def collect_material() -> list[dict]:
    since = time.time() - DAYS * 86400
    material, seen = [], set()
    for message in sorted(claude_messages(since) + codex_messages(since) + commit_subjects() + obsidian_notes(),
                          key=lambda message: message["date"]):
        if message["text"] in seen:
            continue
        seen.add(message["text"])
        # Derived from the content, so a changed filter does not renumber the rest
        # and the saved batch answers stay valid.
        message["id"] = "m" + hashlib.sha1(f"{message['source']}|{message['text']}".encode()).hexdigest()[:7]
        material.append(message)
    return material


def model_key(account: str) -> str:
    completed = subprocess.run(["security", "find-generic-password", "-s", "com.yishuziyu.her",
                                "-a", account, "-w"], capture_output=True, text=True)
    if completed.returncode != 0 or not completed.stdout.strip():
        sys.exit(f"没读到 Her 钥匙串里的 {account}（拒绝或不存在），什么都没发出去。")
    return completed.stdout.strip()


def ask_model(key: str, system: str, user: str, max_tokens: int = 6000) -> dict:
    body = json.dumps({"model": settings.model, "messages": [{"role": "system", "content": system}, {"role": "user", "content": user}],
                       "max_tokens": max_tokens, "temperature": 0.2, "reasoning_effort": "low",
                       "response_format": {"type": "json_object"}}).encode()
    for attempt in range(3):
        request = urllib.request.Request(settings.endpoint, data=body, headers={
            "Authorization": f"Bearer {key}", "Content-Type": "application/json"})
        try:
            with urllib.request.urlopen(request, timeout=180) as response:
                content = json.load(response)["choices"][0]["message"]["content"]
            return json.loads(content[content.index("{"):content.rindex("}") + 1])
        except Exception as error:  # network, refusal or unreadable JSON: retry, then give up on this batch
            if attempt == 2:
                print(f"  一批没有结果：{error}", file=sys.stderr)
                return {}
            time.sleep(3)
    return {}


PROPOSE = """你在帮一个人整理「他最近在意的方向」，以后用来替他留意外面的新东西（新模型、新工具、活动、文章）。
下面是他自己打的字和他项目的提交标题，每行开头是编号。

找出这批材料里他在意的方向，最多 6 条。要求：
- 到主题层级：「实时语音的响应速度」可以；「把某个函数改名」太细，不要；「以后怎么干活」这类工作方法不要。
- 方向是外面可能有新东西的领域、工具或问题。
- 每条给出 2～4 处依据，写编号和逐字摘一小段原话（原文里连续出现的 4～30 个字，不要改写）。
- kind 从这四个里选：正在做的项目、反复聊的话题、在用的工具、没决定的事。
- search_terms：以后去外面找新东西用的 1～3 个英文或中文搜索词。
只输出 JSON：{"directions":[{"title":"…","kind":"…","why":"一句话说为什么看得出他在意","evidence":[{"id":"m12","quote":"…"}],"search_terms":["…"]}]}"""

MERGE = """下面是从一个人不同项目的材料里分别提出的候选方向（每条有编号 c1、c2…）。
这份列表以后用来替他留意外面的新东西：新模型、新工具、新版本、活动、文章。挑出他最在意的 %d 条。

要求：
- 标题具体到能直接拿去搜新消息，12 个字以内，用他自己的说法。好的例子：「实时语音模型的延迟」「Claude Code 新功能」「浏览器侧边栏 AI 助手」。不要的例子：「工程规范落地」「产品体验优化」「多模型协作体系」——这些是干活的方式或大词，搜不到具体新东西。
- 同一件事的候选合并；出现在多个项目、多天、最近还在出现的优先。
- kind 只能是这四个之一：正在做的项目、反复聊的话题、在用的工具、没决定的事。
- why 一句大白话，点出他具体说过或做过什么（比如「连着几天在嫌语音回答要等 6 秒」），不要写「是核心方向」这类套话。
- from 列出合并进来的候选编号。
只输出 JSON：{"directions":[{"title":"…","kind":"…","why":"…","from":["c3","c9"],"search_terms":["…"]}]}""" % DIRECTION_COUNT


def normalized(text: str) -> str:
    return re.sub(r"[\s，。,.!！?？「」“”\"'：:；;、]", "", text).lower()


def verified_evidence(evidence: list[dict], material_by_id: dict[str, dict]) -> list[dict]:
    kept = []
    for item in evidence if isinstance(evidence, list) else []:
        if not isinstance(item, dict):
            continue
        message = material_by_id.get(str(item.get("id", "")).strip())
        quote = str(item.get("quote", "")).strip()
        if message and any(marker in message["text"] for marker in NOT_TYPED_BY_USER):
            continue
        if message and len(normalized(quote)) >= 3 and normalized(quote) in normalized(message["text"]):
            kept.append({**message, "quote": quote})
    return kept


def run(output_folder: Path) -> None:
    material = collect_material()
    material_by_id = {message["id"]: message for message in material}
    by_project = defaultdict(list)
    for message in material:
        by_project[message["project"]].append(message)
    batches = []
    for project, messages in sorted(by_project.items(), key=lambda item: -len(item[1])):
        for start in range(0, len(messages), MESSAGES_PER_BATCH):
            batches.append((project, messages[start:start + MESSAGES_PER_BATCH]))
    sources = defaultdict(int)
    for message in material:
        sources[message["source"]] += 1
    print(f"材料 {len(material)} 条（{dict(sources)}），{len(by_project)} 个项目，{len(batches)} 批发给 {settings.model}")

    key = model_key(settings.key_account)
    output_folder.mkdir(parents=True, exist_ok=True)
    candidates_file = output_folder / "candidates.json"
    # Each batch's answer is kept as soon as it arrives, so a crash or a rerun
    # never asks the model about the same batch twice.
    answers_file = output_folder / "batch-answers.json"
    answers = json.loads(answers_file.read_text()) if answers_file.exists() else {}
    answers_lock = threading.Lock()

    def propose(batch):
        project, messages = batch
        batch_key = f"{project}:{messages[0]['id']}:{len(messages)}"
        if batch_key not in answers:
            lines = "\n".join(f"{m['id']} [{m['date']} {m['source']}] {m['text']}" for m in messages)
            directions = ask_model(key, PROPOSE, f"项目：{project}\n\n{lines}").get("directions", [])
            if directions:
                with answers_lock:
                    answers[batch_key] = directions
                    answers_file.write_text(json.dumps(answers, ensure_ascii=False))
        return answers.get(batch_key, [])

    candidates = []
    with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:
        for proposed in pool.map(propose, batches):
            for direction in proposed if isinstance(proposed, list) else []:
                if not isinstance(direction, dict):
                    continue
                evidence = verified_evidence(direction.get("evidence", []), material_by_id)
                if evidence:
                    candidates.append({**direction, "evidence": evidence, "id": f"c{len(candidates) + 1}"})
    candidates_file.write_text(json.dumps(candidates, ensure_ascii=False, indent=1))
    print(f"候选 {len(candidates)} 条（原话都在记录里找得到）")

    listing = "\n".join(
        f"{c['id']} {c.get('title', '')}（{c.get('kind', '')}）：{c.get('why', '')}"
        f"｜项目 {', '.join(sorted({e['project'] for e in c['evidence']}))}"
        f"｜日期 {', '.join(sorted({e['date'] for e in c['evidence']}))}" for c in candidates)
    merged = ask_model(key, MERGE, listing, max_tokens=16000).get("directions", [])
    print(f"合并后 {len(merged)} 条")
    candidate_by_id = {c["id"]: c for c in candidates}
    directions = []
    for direction in merged if isinstance(merged, list) else []:
        if not isinstance(direction, dict):
            continue
        evidence, seen = [], set()
        for candidate_id in direction.get("from", []):
            for item in candidate_by_id.get(candidate_id, {}).get("evidence", []):
                if item["id"] not in seen:
                    seen.add(item["id"])
                    evidence.append(item)
        # Code decides: real quotes, from at least two places on at least two days.
        if len(evidence) < 2 or len({item["date"] for item in evidence}) < 2:
            print(f"  丢掉「{direction.get('title', '')}」：依据 {len(evidence)} 处，不够两处或不跨两天")
            continue
        # The user's own words first, newest first; commit subjects after them.
        evidence.sort(key=lambda item: (item["source"] != "git 提交", item["date"]), reverse=True)
        directions.append({"title": direction.get("title", ""), "kind": direction.get("kind", ""),
                           "why": direction.get("why", ""), "search_terms": direction.get("search_terms", []),
                           "last_seen": max(item["date"] for item in evidence), "evidence": evidence})
    directions = sorted(directions, key=lambda direction: direction["last_seen"], reverse=True)[:DIRECTION_COUNT]
    output_folder.mkdir(parents=True, exist_ok=True)
    (output_folder / "directions.json").write_text(json.dumps(
        {"generated_at": datetime.datetime.now().isoformat(timespec="seconds"), "model": settings.model,
         "material_count": len(material), "sources": dict(sources), "candidate_count": len(candidates),
         "directions": directions}, ensure_ascii=False, indent=1))
    (output_folder / "index.html").write_text(PAGE)
    print(f"方向 {len(directions)} 条 → {output_folder}")


PAGE = """<!doctype html><meta charset=utf-8><title>她以为你在意的</title>
<style>
body{font:15px/1.6 -apple-system,"PingFang SC",sans-serif;max-width:760px;margin:40px auto;padding:0 20px;color:#1d1d1f;background:#fbfbfd}
h1{font-size:26px;margin:0 0 4px}.sub{color:#6e6e73;margin-bottom:28px}
.card{background:#fff;border-radius:14px;padding:18px 20px;margin:14px 0;box-shadow:0 1px 3px #0001}
.t{font-size:18px;font-weight:600}.k{color:#6e6e73;font-size:13px;margin-left:8px}
.why{margin:6px 0 10px}details{color:#424245;font-size:13.5px}summary{cursor:pointer;color:#0066cc}
.q{margin:6px 0 6px 4px;border-left:3px solid #e5e5ea;padding-left:10px}.q b{background:#fff3b0;font-weight:400}
.m{color:#86868b}.btns{margin-top:12px;display:flex;gap:8px}
button{border:1px solid #d2d2d7;background:#fff;border-radius:18px;padding:5px 16px;font-size:14px;cursor:pointer}
button.on{background:#0071e3;color:#fff;border-color:#0071e3}button.no.on{background:#d70015;border-color:#d70015}
#score{position:sticky;top:0;background:#fbfbfdee;padding:10px 0;font-weight:600}
</style>
<h1>她以为你在意的</h1><div class=sub>从你最近 30 天打的字和项目提交里看出来的。每条标一下：对、不对、说不清。</div>
<div id=score></div><div id=list></div>
<script>
const esc=s=>s.replace(/[&<>]/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;'}[c]));
let marks={};
async function main(){
 const d=await (await fetch('directions.json')).json();
 try{marks=await (await fetch('marks.json')).json()}catch(e){}
 const L=document.getElementById('list');
 d.directions.forEach((x,i)=>{
  const ev=x.evidence.map(e=>`<div class=q>${esc(e.text).replace(esc(e.quote),'<b>'+esc(e.quote)+'</b>')}<div class=m>${e.date} · ${esc(e.source)} · ${esc(e.project)}</div></div>`).join('');
  L.insertAdjacentHTML('beforeend',`<div class=card><span class=t>${esc(x.title)}</span><span class=k>${esc(x.kind)} · 我猜的</span>
  <div class=why>${esc(x.why)}</div><details><summary>依据 ${x.evidence.length} 处，最近一次 ${x.last_seen}</summary>${ev}</details>
  <div class=btns>${['对','不对','说不清'].map(v=>`<button data-i=${i} data-v=${v} class="${v=='不对'?'no':''}">${v}</button>`).join('')}</div></div>`)});
 document.querySelectorAll('button').forEach(b=>b.onclick=async()=>{marks[d.directions[b.dataset.i].title]=b.dataset.v;
  await fetch('marks.json',{method:'POST',body:JSON.stringify(marks)});paint(d)});
 paint(d)}
function paint(d){document.querySelectorAll('button').forEach(b=>b.classList.toggle('on',marks[d.directions[b.dataset.i].title]==b.dataset.v));
 const n=Object.keys(marks).length,ok=Object.values(marks).filter(v=>v=='对').length;
 document.getElementById('score').textContent=`已标 ${n} / ${d.directions.length}　对 ${ok} 条（8 条以上算通过）`}
main()
</script>"""


def serve(folder: Path) -> None:
    class Handler(http.server.SimpleHTTPRequestHandler):
        def __init__(self, *args, **kwargs):
            super().__init__(*args, directory=str(folder), **kwargs)

        def do_POST(self):
            body = self.rfile.read(int(self.headers["Content-Length"]))
            (folder / "marks.json").write_bytes(body)
            self.send_response(204)
            self.end_headers()

        def log_message(self, *args):
            pass

    server = http.server.ThreadingHTTPServer(("127.0.0.1", 19480), Handler)
    print("http://127.0.0.1:19480/  （标记存到 marks.json；Ctrl+C 结束）")
    server.serve_forever()


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--serve", action="store_true", help="only serve the latest run's page for marking")
    parser.add_argument("--endpoint", default=ENDPOINT, help="OpenAI-compatible chat completions URL")
    parser.add_argument("--model", default=MODEL)
    parser.add_argument("--key-account", default="stepfunAPIKey", help="account of the key in Her's Keychain")
    arguments = parser.parse_args()
    settings = arguments
    output = REPOSITORY_ROOT / "out" / "interest-discovery" / datetime.date.today().isoformat()
    if arguments.serve:
        serve(output)
    else:
        run(output)
