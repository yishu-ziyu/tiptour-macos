"""Disposable desktop controls with independent result readback; localhost only."""
import json
from http.server import BaseHTTPRequestHandler, HTTPServer

STATE = {"selected": None, "clicks": 0, "menu_open": False, "events": []}
HTML = """<!doctype html><html lang="zh"><meta charset="utf-8">
<title>TipTour 操作验收</title><style>
body{font:24px system-ui;margin:70px;background:#fafafa;color:#202020}
button{font:24px system-ui;padding:18px;margin:12px;cursor:pointer}
#result{padding:24px;background:#e4efe6;margin-top:30px}section{margin:30px 0}
#same-name{display:flex;justify-content:space-between;max-width:900px}
</style><h1>TipTour 操作验收</h1>
<p>这里所有控件都是测试用的，点击不会修改真实数据。</p>
<section><button onclick="select('task-2')">检查官网部署状态（2）</button>
<button onclick="select('task-3')">检查官网部署状态（3）</button></section>
<section id="same-name"><button onclick="select('left-setting')">设置</button>
<button onclick="select('right-setting')">设置</button></section>
<button onclick="openMenu()">打开显示设置</button>
<section id="menu" hidden><button onclick="select('scale')">缩放选项</button></section>
<div id="result">尚未选择任务</div>
<script>
function render(state){
  document.getElementById('menu').hidden=!state.menu_open;
  document.getElementById('result').textContent=
    '已选择：'+(state.selected ?? '无')+'，点击次数：'+state.clicks+'，步骤：'+state.events.join(' → ');
}
async function update(path, value){
  const state=await (await fetch(path,{method:'POST',body:JSON.stringify(value)})).json();
  render(state);
}
async function select(value){await update('/select',{selected:value})}
async function openMenu(){await update('/menu',{})}
fetch('/state').then(response=>response.json()).then(render);
</script></html>"""


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def respond(self, body, content_type="application/json"):
        data = body.encode("utf-8")
        self.send_response(200)
        self.send_header("Content-Type", content_type + "; charset=utf-8")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        if self.path == "/state":
            self.respond(json.dumps(STATE))
        else:
            self.respond(HTML, "text/html")

    def do_POST(self):
        if self.path == "/reset":
            STATE.update(selected=None, clicks=0, menu_open=False, events=[])
        elif self.path == "/menu":
            STATE["menu_open"] = True
            STATE["events"].append("open-menu")
        elif self.path == "/select":
            request = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
            selected = request.get("selected")
            if selected in {"task-2", "task-3", "left-setting", "right-setting"} or (
                selected == "scale" and STATE["menu_open"]
            ):
                STATE.update(selected=selected, clicks=STATE["clicks"] + 1)
                STATE["events"].append(selected)
        self.respond(json.dumps(STATE))


if __name__ == "__main__":
    print("Fixture: http://127.0.0.1:19475; readback: /state", flush=True)
    HTTPServer(("127.0.0.1", 19475), Handler).serve_forever()
