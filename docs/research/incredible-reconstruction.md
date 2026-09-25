# Incredible 架构重建 v1

现行研究文档，2026-09-23 建立，随证据更新。目的不是复刻 Incredible，而是弄清它在感知、执行、学习和可靠性上做了哪些取舍，再逐项对照 Her。

## 方法与边界

三层证据，互相印证：

1. **公开考古**：官网、公开 GitHub、公开文档、商店页面。
2. **客户端静态检查**：只检查我们自己下载的公开安装包和公开发布的扩展包，不运行、不登录。
3. **黑盒行为实验**：让真实产品在我们自己的受控页面上执行任务，页面独立记录事件（见文末「探针实验」）。

不做：绕过登录或授权、探测对方服务器、把对方代码复制进我们的仓库。静态检查只摘结论和文件名，不搬代码。

置信度：

| 标记 | 含义 |
| --- | --- |
| CONFIRMED | 对方自己的代码或随包文档直接写明，或我们在自己的副本里亲眼看到 |
| HIGH | 多条间接证据一致，没有反例 |
| HYPOTHESIS | 合理推断，只有一条间接证据 |
| UNKNOWN | 还没有证据 |

证据位置：
- `T` = `out/research/2026-09-23-teardown.md`：Incredible 0.2.31 桌面包静态拆解。原始文件在 `/tmp/her-teardown/`，本地未入库。
- `E` = Chrome 扩展 1.14.5（ID `ajhinphcdjpohilkmooikgbgcipmkopi`），包内的 `REVIEWERS.md`、`manifest.json`、`src/teach-capture.js`，原始文件在 `/tmp/her-teardown/ext/inc/`。
- `P` = 公开资料。
- `U` = 用户 2026-09-23 的溯源笔记（本对话），来源尚未逐条复核。

## 演化线

| 年份 | 形态 | 证据 |
| --- | --- | --- |
| 2021–2022 | Norditech LabelDetector：摄像头识别仓库标签，接入企业原有 ERP | U |
| 2023–2024 | STELLA：开源多智能体平台 | P，CONFIRMED：`github.com/Norditech-AB/STELLA`，AGPL-3.0，已归档，最后推送 2024-02-02 |
| 2024 | SOP-bench：让智能体执行真实标准作业流程的评测集 | P，CONFIRMED：`Norditech-AB/SOP-bench`，最后推送 2024-03-24 |
| 2024 | VISS.AI「AI Office Worker」：自然语言 → 应用 / ERP / API 自动化 | U |
| 2025 | Incredible API / Agent MAX：长任务、防循环、记忆、重试、代码执行 | P，CONFIRMED 存在：`Norditech-AB/Incredible-API-Docs`（已归档）、`Incredible-API-Cookbook`（MIT，已归档）；机制细节来自 U |
| 2026 | Vibe Computing：语音 → 桌面智能体 → 浏览器 + 应用 + 文件 | T、E |

结论：「让 AI 用人的界面去操作已有系统」是这家公司五年来的主线，不是临时转向。

## 模块矩阵

| 模块 | Incredible 的做法 | 置信度 / 证据 | Her 现状 |
| --- | --- | --- | --- |
| 整体形态 | Tauri 2（Rust）桌面主进程是中心；Swift `accessibility-helper`、`incredible-screenrec` 两个辅助进程；常驻 Python 内核；浏览器扩展只是控制面 | CONFIRMED（T、E §1） | Swift 单进程，桌面是中心 |
| 桌面感知 | AX 抽文本加遮挡判断（`screen-text`）、聚焦窗口预热、剪贴板、打开的文档和文件夹；给 Electron / Chrome 开 `AXManualAccessibility` | CONFIRMED（T） | AX + OCR + YOLO，目标窗口隔离，观察身份绑定 |
| 浏览器感知 | 注入 `content.js` 读结构，`dom-pierce.js` 穿透 shadow DOM / iframe，`dom-visibility.js` 定义「有效可见」，保留虚拟列表里零尺寸的行；视觉只用于截图 | CONFIRMED（E §4） | 浏览器 DOM / CDP 只是定位回退之一 |
| 浏览器执行 | CDP 只用 8 个方法：`Runtime.enable/evaluate`、`Input.dispatchKeyEvent/MouseEvent`、`Emulation.setFocusEmulationEnabled`、`Page.captureScreenshot`、`Page.setWebLifecycleState`、`Page.printToPDF`。点击和键入是可信事件 | CONFIRMED（E §5） | 经系统级 CUA 输入 |
| 扩展 ↔ 桌面协议 | 本机 WebSocket `ws://127.0.0.1:37423/browser-extension`，协议版本 10、浏览器操作契约版本 4。主认证：桌面程序校验浏览器自动带上的 `Origin` 请求头。备用认证：Native Messaging 宿主 `com.incredible.bridge_auth` 是一段 shell 脚本，只读取 `~/.incredible/bridge-secret` 并交给扩展。握手检查协议版本和权限；扩展用 offscreen 页面保活，另有一个 30 s 的 alarm 负责重连。命令集见下方 | CONFIRMED（E `src/protocol.js`、§1/§5，T） | 无 |
| 标签页归属 | 只动自己为任务开的、被点名的，或教学录制中的标签页；每次读写都要校验调用者和标签页归属的「租约」；智能体的标签页放进自己的标签组（标题是状态 emoji + 任务名），也可以改用降低透明度的网站图标加光标来标记 | CONFIRMED（E §4 `agent-isolation.js`、`ownership.js`、`task-card-policy.js`） | 桌面层有目标应用和窗口固定 |
| 可见反馈 | 页内画可见光标，任务卡显示标题、进度和步骤；截图时隐藏任务卡；完成后光标变成绿色对勾 | CONFIRMED（E §4） | 光标旁的指向标记、ThinkingOrb 状态指示、回执 |
| 桌面执行 | Python 内核的 `desktop.*` 原语，经进程间通信到 Rust，再到 Swift 的 AX 辅助程序 | CONFIRMED（T） | WorkflowRunner → ActionExecutor → CUA |
| 规划与执行形态 | 「代码即动作」：模型写 Python 单元格在常驻命名空间里执行；`mcp()` 调用先登记，单元格跑完后由 Rust 并行执行。浏览器侧可以把 JS 下发到沙盒页面，或经 `Runtime.evaluate` 在页面里执行 | CONFIRMED（T、E §7） | 结构化工具调用，一次一个动作或最多六步 |
| 前台 / 后台分工 | 前台代理管语音和屏幕顶部的「岛」卡片（`set_island`），用 `tell_agent` 把长活交给后台代理；有检查清单工具 | CONFIRMED（T） | 语音会话 + DesktopTaskCoordinator |
| 长任务可靠性（Agent MAX 的继承） | 当前产品里仍能看到：`context-compaction`（`mid_task`、`orch_recap`）、`spine/work_ledger`、`task-journal`、`judge_actions`、检查清单、`speculative_turn` | HIGH：机制名称都在（T）；是否完整继承 Agent MAX 的防循环和缓存重试，UNKNOWN | 任务日志只记恢复元数据；六步预算 |
| 结果未知 | `outcome_unknown` / `write_outcome_unknown`：要求先复查再继续 | CONFIRMED（T） | `uncertain_effect`，四种由用户裁决的结局 |
| 确认与安全 | 提示词规则：发送、删除、发帖、付款先出草稿；`action-gate` 做结构化审批；Python 审计钩子拦截内核直连大模型和删除文件；本地文件上传要先按站点审批，未收到答复就视为拒绝 | CONFIRMED（T、E §6） | CUA 总开关、截图开关 |
| 录制演示 → 技能 | 用户按「Demonstrate」，屏幕被录制，用户每说一句，模型就看到当时的一张静帧。浏览器侧 `teach-capture.js` 只在用户开始录制的标签页里记录 `isTrusted` 的 mousedown / input / change / submit，每步字段是网址、标题、CSS 选择器、角色、标签、非密码字段的值，**不记坐标**；密码、验证码、卡号等在页面内就丢弃。录制包含 `events.jsonl`、`intent.txt`、`transcript.txt`、`captions.vtt`、缩略图和 `video.mov`，上传到 Supabase。回放时模型被明确要求**把步骤当意图而不是脚本**：步骤说用户要什么、按什么顺序；现实决定怎么做；某一步对不上眼前的画面时，按该步的意图继续。扩展捕获不到事件时，生成流程停下来等用户确认 | 录制字段与回放策略 CONFIRMED（E `teach-capture.js`，T 中给模型的指令原文）；实际回放是否真的遵守这条指令，仍要靠黑盒实验 B | `TipTour/Skills/**/SKILL.md` 手写技能，没有录制 |
| 记忆 | 本地 `<home>/knowledge/<id>/KNOWLEDGE.md`（带 frontmatter），另有 Supabase 同步和排序；有文件监听 | CONFIRMED（T） | 无（路线图第 3 步） |
| 语音 | 级联式：AssemblyAI / ElevenLabs Scribe 流式识别 → 大模型 → ElevenLabs v3 / Inworld 合成，带逐词对齐和插话静音（hush mask）。唤醒词两级：sherpa-onnx 候选，加一个「是否在对助手说话」判别器，在 100 / 300 / 700 ms 复核 | CONFIRMED（T） | 阶跃端到端实时语音 |
| 本地 / 云端边界 | 扩展除了本机桌面程序，不连任何地址；页面数据只经桌面程序发给模型供应商；后端用 Supabase，遥测用 PostHog 和 Sentry | CONFIRMED（E §1，T） | 只连阶跃 / TypeSafe，Keychain |
| 延迟策略 | `speculative_turn`（推测执行）、聚焦窗口预热（`focused_prewarm`）、模型按角色路由（工具挑选、分类用小模型） | HIGH（T：只有名称，未测时间） | 实时模型直出，首声约 0.2 s（服务器口径） |

## 浏览器协议（CONFIRMED，扩展 `src/protocol.js`）

桌面程序发给扩展的命令，版本 4（2026-09-07 起支持 `A >>> B` 穿透跨域 iframe）：

| 类别 | 命令 |
| --- | --- |
| 标签页 | `open_tab`、`list_tabs`、`activate_tab`、`navigate`、`close_tab` |
| 观察 | `get_state`、`get_dom_snapshot`、`dump_html`、`read_element`、`get_live_artifacts`、`get_network_logs`、`screenshot`、`query_focus` |
| 动作 | `click`、`click_selector`、`type_text`、`select`、`submit`、`run_js`、`run_plan`、`notebook`、`terminal` |
| 文件 | `download_url`、`observe_downloads`、`get_downloaded_files`、`save_page_as_pdf` |
| 教学 | `start_teach_capture`、`stop_teach_capture`、`drain_teach_events` |
| 会话 | `end_browser_session`、`task_card_update`、`task_card_dismiss`、`reload_extension` |

错误码里最能说明定位哲学的三个：`ambiguous_element`（多个元素匹配，拒绝而不是猜）、`stale_element`（元素已过期）、`frame_ambiguous`（跨域 iframe 无法唯一确定，拒绝）。这和 Her「目标不唯一就停下来问，而不是点一个最像的」是同一条原则。

## 对 Her 的直接启发

1. **Her 桌面程序应当是浏览器扩展的宿主。** Incredible 证明「桌面中心 + 本机 WebSocket + 只做控制面的扩展」行得通，也过得了商店审核。Her 本机监听一个端口，用 `Origin` 请求头认证扩展，整个系统只有一个大脑。
2. **CDP 用最小集合。** 8 个方法就覆盖了读、点、键入、截图和打印。权限越少，越容易审核，也越容易解释。
3. **标签页归属和可见标记是产品特性，不是实现细节。** 智能体标签组、光标、任务卡，都是在回答「它在动我的什么」。
4. **教学录制记意图，回放时重新规划。** 选择器、角色、标签只是给模型的线索；给模型的指令明确写着「不要把步骤当脚本盲目回放，对不上就按该步的意图继续」。这和 Her「目标由代码约束、定位失败就重新观察」的方向一致，比「录下选择器再原样重放」更接近我们想要的。
5. **结果未知是行业共识。** Her 的 `uncertain_effect` 方向正确，不必为了看起来「更聪明」而退回自动重放。
6. **不必照搬的：** 级联语音（我们押的是端到端实时语音）、Python 内核（Her 不引入第二个运行时）、130 个 crate 的规模。

## 未知项

| 问题 | 怎么查 |
| --- | --- |
| 回放策略的设计意图已确认是「按意图重新规划」；模型在真实页面上是否遵守 | 黑盒实验 B |
| 浏览器感知在 DOM 缺信息时会不会退到视觉 | 黑盒实验 A 的 Canvas 和纯图标变体 |
| Agent MAX 的防循环和缓存重试是否还在 | 黑盒实验 C（故意制造循环和失败） |
| 桌面 WebSocket 消息格式 | 扩展 `src/protocol.js` 与 `background.js` 的静态阅读（只记命令名和字段） |
| 延迟策略的真实时间 | 黑盒实验，记录语音结束 → 首个动作的时间 |

## 探针实验（Agent Browser Probe Lab）

复用 Her 已有的受控夹具 `tools/voice-acceptance/fixture.py`（端口 19475，自带独立的 `/state` 读回），扩成一组探针页面。同一套页面既测 Incredible，也测 Her，结果可以直接对比。

每个页面都在页内记录 `pointerdown / mousedown / focus / input / keydown / click` 的 `isTrusted`、坐标、DOM 目标和时间戳，经 `/state` 读回。

**实验 A：定位方式。** 同一个「Submit」做 8 个变体：普通 button、ARIA button、只有图标、iframe 内、shadow DOM 内、Canvas 画的、DOM 里有但看不见、看得见但 DOM 信息极少。判读：能点中哪些、点击是可信事件还是合成事件、坐标落在哪里，由此判断主要靠 DOM、AX、CDP 还是视觉。

**实验 B：录制演示再回放。** 用户示范「找到客户 → 打开详情 → 添加备注」。之后分别改动页面：移动按钮位置、改 class、改 DOM 层级、保留 aria-label 但改显示文字、改 id、插入一个同名干扰按钮。判读：
- 改 class 和层级后还能点中，而改 id 后失败：主要靠选择器；
- 保留 aria-label 就成功：靠 `stepFor` 里的属性；
- 只有文字对上才成功：靠标签或语义；
- 每次都先观察再规划：属于重新规划。

**实验 C：可靠性。** 按钮点了没有反应（形成循环）、中途弹出对话框、网络请求挂起、刷新页面后状态丢失、写入是否成功无法判断。判读：几次后停止、会不会重复写、会不会如实报告「结果未知」。

每轮实验留一份 JSON：任务原话、页面版本、事件日志、`/state`、产品给出的回执、屏幕录像的路径。
