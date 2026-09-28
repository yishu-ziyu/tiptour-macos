#!/usr/bin/env python3
"""Roadmap 3.4: once a day, find new things outside that match what the user cares about.

Code fetches real, dated items (Hacker News stories with enough points, releases
of the coding tools the user uses, official model news). Her's model only
judges each item against the directions from roadmap 3.2 and writes one line on
why it matters to the user; the title, link and date always come from the
source itself. The StepFun Step Plan route answers web-search requests by
inventing results (2026-09-28: three "new releases" from 2024 with made-up
links), so the model never searches.

Kept: worth 2 or more out of 3, never sent before, direction not silenced; at
most one per direction and three per day.

  python3 scripts/daily-discovery.py [--days 1]   # writes ~/Library/Application Support/Her/discovery/<date>.json
  python3 scripts/daily-discovery.py --install    # run it every day at 09:30 (LaunchAgent)
  python3 scripts/daily-discovery.py --serve      # page to judge today's picks
"""
from __future__ import annotations

import argparse
import datetime
import email.utils
import html
import json
import re
import subprocess
import sys
import urllib.parse
import xml.etree.ElementTree as ElementTree
from pathlib import Path

from her_model import HerModel, add_model_arguments, serve_marking_page

REPOSITORY_ROOT = Path(__file__).resolve().parent.parent
DIRECTIONS_FOLDER = REPOSITORY_ROOT / "out" / "interest-discovery"
# Shared with Her (TipTour/App/DiscoveryNotices.swift): Her posts <date>.json and
# writes silenced.json when the user presses 「这类别推」.
STATE_FOLDER = Path.home() / "Library" / "Application Support" / "Her" / "discovery"
TOOL_REPOSITORIES = ["anthropics/claude-code", "openai/codex", "MoonshotAI/kimi-cli"]
FEEDS = [("OpenAI 新闻", "https://openai.com/news/rss.xml"),
         ("Hugging Face 博客", "https://huggingface.co/blog/feed.xml")]
HACKER_NEWS_MINIMUM_POINTS = 40
ITEMS_PER_BATCH = 60
PICKS_PER_DAY = 3
MINIMUM_WORTH = 2


def fetch(url: str) -> bytes:
    """curl, not urllib: through the local proxy urllib's TLS gets cut off by
    openai.com (2026-09-28) while curl reads the same feed reliably."""
    completed = subprocess.run(["curl", "-sSfL", "--retry", "3", "--retry-all-errors", "-m", "60",
                                "-A", "Her daily discovery", url], capture_output=True)
    if completed.returncode != 0:
        raise OSError(completed.stderr.decode(errors="ignore").strip() or f"curl exit {completed.returncode}")
    return completed.stdout


def plain(text: str, limit: int = 300) -> str:
    return re.sub(r"\s+", " ", html.unescape(re.sub(r"<[^>]+>", " ", text or ""))).strip()[:limit]


def hacker_news(since: datetime.datetime) -> list[dict]:
    query = urllib.parse.urlencode({"tags": "story", "hitsPerPage": 300, "numericFilters":
                                    f"created_at_i>{int(since.timestamp())},points>={HACKER_NEWS_MINIMUM_POINTS}"})
    hits = json.loads(fetch(f"https://hn.algolia.com/api/v1/search_by_date?{query}"))["hits"]
    return [{"title": hit["title"], "url": hit.get("url") or f"https://news.ycombinator.com/item?id={hit['objectID']}",
             "date": hit["created_at"][:10], "source": "Hacker News",
             "detail": f"{hit.get('points', 0)} 分，{hit.get('num_comments') or 0} 条讨论"} for hit in hits]


def tool_releases(since: datetime.datetime) -> list[dict]:
    items = []
    for repository in TOOL_REPOSITORIES:
        for release in json.loads(fetch(f"https://api.github.com/repos/{repository}/releases?per_page=10")):
            published = datetime.datetime.fromisoformat(release["published_at"].replace("Z", "+00:00"))
            if published >= since and not release.get("draft"):
                items.append({"title": f"{repository.split('/')[1]} {release.get('name') or release['tag_name']}",
                              "url": release["html_url"], "date": release["published_at"][:10],
                              "source": "GitHub 发布", "detail": plain(release.get("body", ""))})
    return items


def feed_items(since: datetime.datetime) -> list[dict]:
    items = []
    for name, url in FEEDS:
        for entry in ElementTree.fromstring(fetch(url)).iter("item"):
            published = email.utils.parsedate_to_datetime(entry.findtext("pubDate") or "")
            if published >= since:
                items.append({"title": plain(entry.findtext("title") or "", 200), "url": entry.findtext("link") or "",
                              "date": published.date().isoformat(), "source": name,
                              "detail": plain(entry.findtext("description") or "")})
    return items


def collect_items(days: int) -> list[dict]:
    since = datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(days=days)
    items = []
    for name, collector in [("Hacker News", hacker_news), ("工具发布", tool_releases), ("官方新闻", feed_items)]:
        try:
            items += collector(since)
        except Exception as error:  # one unreachable source must not cost the others
            print(f"  {name} 没取到：{error}", file=sys.stderr)
    for number, item in enumerate(items, start=1):
        item["id"] = f"i{number}"
    return items


def normalized_title(title: str) -> str:
    return re.sub(r"\W+", "", title.lower())


def read_json(path: Path, default):
    return json.loads(path.read_text()) if path.exists() else default


JUDGE = """下面是一个人在意的方向（编号 d1、d2…，附他具体说过、做过的事），和今天外面的新内容（编号 i1、i2…，只有标题、来源和简介）。
替他挑出真的和他有关的新内容，写成他的 AI 伙伴发给他的一句话。无关的不要输出。

- direction：对应的方向编号。
- why_you：像熟人发消息，一两句大白话：先点出他手上哪件具体的事，再说这条对那件事有什么用，最后可以给一个马上能做的小动作。例：「你这周一直嫌语音首响慢，这个模型号称首响 200 毫秒，可以拿同一句话跟现在的比一下。」
  只能用标题和简介里有的事实，不要补充、不要夸大；不要写「和你关注的××直接相关」这种套话。
- worth：现在值不值得打扰他，0～3，从严打分：
  3＝会直接改变他手上某件事的做法，或他在用的工具出了影响他的变化；
  2＝同一件事上值得知道的新东西；
  1＝只是同一大类（比如都和 AI Agent 有关）；
  0＝无关。拿不准就往低打。
只输出 JSON：{"picks":[{"item":"i3","direction":"d2","why_you":"…","worth":3}]}"""


def run(arguments: argparse.Namespace) -> None:
    latest_directions = sorted(DIRECTIONS_FOLDER.glob("*/directions.json"))
    if not latest_directions:
        sys.exit("还没有 3.2 的方向列表，先跑 scripts/interest-discovery.py。")
    directions = json.loads(latest_directions[-1].read_text())["directions"]
    STATE_FOLDER.mkdir(parents=True, exist_ok=True)
    sent = read_json(STATE_FOLDER / "sent.json", {})
    silenced = set(read_json(STATE_FOLDER / "silenced.json", []))
    direction_by_id = {f"d{number}": direction for number, direction in enumerate(directions, start=1)
                       if direction["title"] not in silenced}

    items = collect_items(arguments.days)
    sent_titles = {normalized_title(title) for title in sent.values()}
    items = [item for item in items if item["url"] not in sent and normalized_title(item["title"]) not in sent_titles]
    print(f"新内容 {len(items)} 条（去掉推过的），方向 {len(direction_by_id)} 个（去掉你说别推的）")

    direction_lines = "\n".join(
        f"{direction_id} {direction['title']}：{direction['why']}｜他说过：" +
        "；".join(f"「{item['quote']}」" for item in direction["evidence"][:3])
        for direction_id, direction in direction_by_id.items())
    item_by_id = {item["id"]: item for item in items}
    model = HerModel.from_arguments(arguments)
    picks = []
    for start in range(0, len(items), ITEMS_PER_BATCH):
        item_lines = "\n".join(f"{item['id']} [{item['source']} {item['date']}] {item['title']}｜{item['detail']}"
                               for item in items[start:start + ITEMS_PER_BATCH])
        answer = model.ask_json(JUDGE, f"方向：\n{direction_lines}\n\n新内容：\n{item_lines}")
        for pick in answer.get("picks", []) if isinstance(answer.get("picks"), list) else []:
            if not isinstance(pick, dict) or pick.get("item") not in item_by_id or pick.get("direction") not in direction_by_id:
                continue
            worth = pick.get("worth") if isinstance(pick.get("worth"), int) else 0
            picks.append({**item_by_id[pick["item"]], "direction": direction_by_id[pick["direction"]]["title"],
                          "why_you": str(pick.get("why_you", "")).strip(), "worth": worth})

    picks.sort(key=lambda pick: (pick["worth"], pick["date"]), reverse=True)
    chosen, used_directions = [], set()
    for pick in picks:
        if pick["worth"] >= MINIMUM_WORTH and pick["direction"] not in used_directions and len(chosen) < PICKS_PER_DAY:
            chosen.append(pick)
            used_directions.add(pick["direction"])
    today = datetime.date.today().isoformat()
    others = [pick for pick in picks if pick not in chosen]
    # A dry run must not replace the day file Her posts from.
    run_file = STATE_FOLDER / (f"{today}-dry-run.json" if arguments.dry_run else f"{today}.json")
    run_file.write_text(json.dumps(
        {"date": today, "model": arguments.model, "item_count": len(items), "chosen": chosen, "others": others},
        ensure_ascii=False, indent=1))
    if not arguments.dry_run:
        sent.update({pick["url"]: pick["title"] for pick in chosen})
        (STATE_FOLDER / "sent.json").write_text(json.dumps(sent, ensure_ascii=False, indent=1))
    (STATE_FOLDER / "index.html").write_text(PAGE)
    print(f"相关 {len(picks)} 条，推 {len(chosen)} 条 → {run_file}")
    for pick in chosen:
        print(f"  · {pick['title']}（{pick['source']} {pick['date']}，{pick['worth']} 分）\n    {pick['why_you']}")


LAUNCH_AGENT_LABEL = "com.yishuziyu.her.daily-discovery"


def install_launch_agent() -> None:
    """launchd starts jobs without the shell's environment, so the proxy the
    outside sources need is written into the job."""
    import os
    import plistlib
    agent = Path.home() / "Library" / "LaunchAgents" / f"{LAUNCH_AGENT_LABEL}.plist"
    proxy = {name: os.environ[name] for name in ("HTTPS_PROXY", "HTTP_PROXY", "NO_PROXY") if os.environ.get(name)}
    agent.write_bytes(plistlib.dumps({
        "Label": LAUNCH_AGENT_LABEL,
        "ProgramArguments": [sys.executable, str(Path(__file__).resolve())],
        "StartCalendarInterval": {"Hour": 9, "Minute": 30},
        "EnvironmentVariables": {**proxy, "PATH": "/usr/bin:/bin:/usr/sbin:/sbin"},
        "StandardOutPath": str(STATE_FOLDER / "last-run.log"),
        "StandardErrorPath": str(STATE_FOLDER / "last-run.log"),
    }))
    STATE_FOLDER.mkdir(parents=True, exist_ok=True)
    subprocess.run(["launchctl", "bootout", f"gui/{os.getuid()}/{LAUNCH_AGENT_LABEL}"], capture_output=True)
    subprocess.run(["launchctl", "bootstrap", f"gui/{os.getuid()}", str(agent)], check=True)
    print(f"每天 09:30 运行；日志 {STATE_FOLDER / 'last-run.log'}。停用：launchctl bootout gui/{os.getuid()}/{LAUNCH_AGENT_LABEL}")


PAGE = """<!doctype html><meta charset=utf-8><title>今天她会告诉你的</title>
<style>
body{font:15px/1.6 -apple-system,"PingFang SC",sans-serif;max-width:720px;margin:40px auto;padding:0 20px;color:#1d1d1f;background:#fbfbfd}
h1{font-size:26px;margin:0 0 4px}.sub{color:#6e6e73;margin-bottom:24px}
.card{background:#fff;border-radius:14px;padding:16px 20px;margin:14px 0;box-shadow:0 1px 3px #0001}
.t{font-size:17px;font-weight:600;color:#1d1d1f;text-decoration:none}.t:hover{text-decoration:underline}
.m{color:#86868b;font-size:13px}.why{margin:8px 0}.dir{font-size:13px;color:#6e6e73}
.btns{margin-top:10px;display:flex;gap:8px;flex-wrap:wrap}
button{border:1px solid #d2d2d7;background:#fff;border-radius:18px;padding:4px 14px;font-size:14px;cursor:pointer}
button.on{background:#0071e3;color:#fff;border-color:#0071e3}button.bad.on{background:#d70015;border-color:#d70015}
details{margin-top:28px;color:#424245}summary{cursor:pointer;color:#0066cc}.o{margin:8px 0;font-size:14px}
</style>
<h1>今天她会告诉你的</h1><div class=sub id=sub></div><div id=list></div><details><summary id=os></summary><div id=others></div></details>
<script>
const esc=s=>(s||'').replace(/[&<>"]/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;'}[c]));
const today=new Date().toISOString().slice(0,10);
let fb={},silenced=[];
async function load(n){try{return await (await fetch(n)).json()}catch(e){return null}}
async function main(){
 const d=await load(today+'.json');fb=await load('feedback.json')||{};silenced=await load('silenced.json')||[];
 document.getElementById('sub').textContent=`从 ${d.item_count} 条新内容里挑的。每条标一下有没有用；某类不想再听，就点「这类别推」。`;
 document.getElementById('list').innerHTML=d.chosen.map((p,i)=>`<div class=card><a class=t href="${esc(p.url)}" target=_blank>${esc(p.title)}</a>
  <div class=m>${esc(p.source)} · ${p.date}</div><div class=why>${esc(p.why_you)}</div><div class=dir>因为你在意：${esc(p.direction)}</div>
  <div class=btns>${['有用','没用','打扰到我了'].map(v=>`<button data-u="${esc(p.url)}" data-v="${v}" class="${v=='有用'?'':'bad'}">${v}</button>`).join('')}
  <button data-s="${esc(p.direction)}" class=bad>这类别推</button></div></div>`).join('')||'<p>今天没有值得打扰你的。</p>';
 document.getElementById('os').textContent=`其余有关的 ${d.others.length} 条（没推）`;
 document.getElementById('others').innerHTML=d.others.map(p=>`<div class=o>${p.worth} 分 · <a href="${esc(p.url)}" target=_blank>${esc(p.title)}</a> — ${esc(p.why_you)}</div>`).join('');
 document.querySelectorAll('button[data-u]').forEach(b=>b.onclick=async()=>{fb[b.dataset.u]=b.dataset.v;await save('feedback.json',fb);paint()});
 document.querySelectorAll('button[data-s]').forEach(b=>b.onclick=async()=>{const s=b.dataset.s;silenced=silenced.includes(s)?silenced.filter(x=>x!=s):[...silenced,s];await save('silenced.json',silenced);paint()});
 paint()}
async function save(n,v){await fetch(n,{method:'POST',body:JSON.stringify(v)})}
function paint(){document.querySelectorAll('button[data-u]').forEach(b=>b.classList.toggle('on',fb[b.dataset.u]==b.dataset.v));
 document.querySelectorAll('button[data-s]').forEach(b=>b.classList.toggle('on',silenced.includes(b.dataset.s)))}
main()
</script>"""


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--days", type=int, default=1, help="how far back to look for new items")
    parser.add_argument("--dry-run", action="store_true", help="do not remember today's picks as sent")
    parser.add_argument("--serve", action="store_true", help="serve the page to judge today's picks")
    parser.add_argument("--install", action="store_true", help="run every day at 09:30 through a LaunchAgent")
    add_model_arguments(parser)
    arguments = parser.parse_args()
    if arguments.install:
        install_launch_agent()
    elif arguments.serve:
        serve_marking_page(STATE_FOLDER, 19481)
    else:
        run(arguments)
