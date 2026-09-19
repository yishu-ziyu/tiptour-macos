# 模型调研实测记录（2026-09-20）

所有结论均来自对 `yishu-ziyu` 账号的真实调用，密钥存放于 git-ignored 的 `.env`。
复现方式见 `tools/stepprobe`。

## 1. 账号可用性（Step Plan 通道 `/step_plan/v1`）

| 模型 | 纯文本 | 图像输入 | 备注 |
| --- | --- | --- | --- |
| `step-3.7-flash` | 200 | **200** | 多模态，三档 `reasoning_effort` |
| `step-5-preview` | 200 | **200** | 思考型，延迟不可用（见 §3） |
| `step-3.5-flash` | 200 | 400 `model_incompatible` | 明确不支持图像 |
| `step-router-v1` | 200 | 400 `model_incompatible` | 仅路由 `deepseek-v4-pro` ↔ `step-3.7-flash` |
| `step-3.5-preview` | 404 | — | 文档列出但账号无权限 |
| `step-5` / `step-5-preview-0801` | 404 | — | 不存在 |

`step-5-preview` 可用但阶跃文档索引尚未收录；`step-3.5-preview` 相反（文档有、账号无）。
**账号可用性必须实测，不能信文档。**

## 2. 实时语音（开放平台通道 `/v1/realtime`）

协议兼容 OpenAI Realtime：`session.update` / `input_audio_buffer.append`（base64 pcm16，20–30ms 分块）/
`conversation.item.create` / `response.create`；服务端回 `response.audio.delta` /
`response.audio_transcript.delta` / `response.thinking.delta`。
自定义 Tool Call 可用（`type:"function"`，回 `function_call_output` 后需手动 `response.create`）。
单会话上限 30 分钟。参考实现：`github.com/stepfun-ai/Step-Realtime-Console`。

两条通道的模型集不同，且计费账户不同：

| 通道 | 地址 | 实时模型 | 计费 |
| --- | --- | --- | --- |
| 开放平台 | `wss://api.stepfun.com/v1/realtime` | `stepaudio-3-realtime-preview`（限免）等 | 按量充值 |
| Step Plan | `wss://api.stepfun.com/step_plan/v1/realtime` | **仅** `stepaudio-2.5-realtime` | 套餐 Credit |

## 3. 「眼睛」模型延迟

| 模型 | effort | JSON Mode | 延迟 | tokens |
| --- | --- | --- | --- | --- |
| `step-3.7-flash` | low | 开 | **1.23s** | 480 |
| `step-3.7-flash` | medium | 开 | 1.48s | 476 |
| `step-3.7-flash` | high | 开 | 1.61s | 468 |
| `step-5-preview` | — | 开 | **12.4s** | 702 |

`step-5-preview` 是思考型（先出 `reasoning_content`），在实时点击链路中不可用。
`reasoning_effort` 对延迟影响有限（low 比 high 省约 380ms），但 **JSON Mode 必须开**：
不开会返回 ````json` 围栏加另一套 schema，解析成本高。

## 4. ⚠️ 集成陷阱：token 预算被 reasoning 吃光

`reasoning_effort=low` 仍会产生 `reasoning_content`，且它计入 `max_tokens`。
`max_tokens=400` 时实测 `finish_reason=length`、`content` 为**空字符串**——模型只想完没说。
**任何调用视觉模型的代码都必须给足 `max_tokens`（≥1500）并检查 `content` 非空。**

## 5. ⚠️ 核心结论：VLM 不能用于产出点击坐标

在 3420×2224 Retina 真实截图上放置三个已知位置的高对比度标记（真实框 60–140px），
让 `step-3.7-flash` 返回像素框，反映射后：

| 输入宽度 | 标记 A 反映射 | 真实 | 横向误差 |
| --- | --- | --- | --- |
| 3420px | 坐标系完全失效 | (300,180,390,270) | — |
| 2000px | (149,140,195,209) | (300,180,390,270) | ~150px |
| 600px | (2964,798,3135,969) | (300,180,390,270) | ~2700px |

坐标行为不随输入分辨率线性变化，返回框尺寸在 19–30px 间跳变，无稳定标定系数。
**不要用 VLM 的像素坐标直接驱动点击。**

### 由此确定的架构分工

本地感知（AX / CoreML / OCR）提供**精确像素框**与控件 ID；VLM 只做**语义消歧**——
把候选区域编号后问「哪个编号是 Save 按钮」，返回编号而非坐标。这把坐标问题整个绕开了。

| 角色 | 承担者 | 职责 |
| --- | --- | --- |
| 嘴 + 耳 + 意图 | StepAudio Realtime | 全双工听说、调 function call |
| 眼睛 | `step-3.7-flash` | 候选区域的**语义选择**，不产生坐标 |
| 手 | Jev `jev-1.13.0` | 对候选做类型化决策，confidence 兜底 |
| 坐标真值 | 本地感知 | CoreML / AX / OCR / 浏览器 DOM |

这与 `AGENTS.md` 既有的 grounding 优先级一致（先本地 ID/marks，再 AX，再 DOM/CDP，
最后才退到截图坐标）——实测数据支持把「截图坐标」这条降级为最后手段。

## 6. Jev（TypeSafe）

官方文档与本地实测（`By-Your-Side/out/experiments/typesafe-natural-*`）：

- 端点 `POST https://api.typesafe.ai/v1/systemone`，`jev-latest` → `jev-1.13.0`
- 三种问题类型可混在一次调用并行评估：`choice` / `score` / `noul`
- **只接受文本**：string / JSON object / 文本数组。图像、音频、视频均不支持——
  Jev 永远不可能是「眼睛」，非文本输入必须由我们预处理成文本
- **英文准确率最好，CJK 明确更低**。中文候选集必须实测，并依赖 `probabilities` 分布
  做三档路由（高置信自动执行 / 中置信需确认 / 低置信不动）
- 限速 250k tokens/秒、1200 RPM；上下文 64k（state 单独 32k）
- 别名会漂移；阈值是针对版本调的情况下应锁版本 ID
- 价格 $0.042/Mtok 输入，**输出免费**

本地 24 例实测：中位延迟 **272ms**（最长 1318ms），中位 609 input tokens。
Jev 相对本地规则：参数错 5→0、误接受 2→0，代价是 11/13 需要正向兜底。
**「不会编造」是真的，Jev 选择宁可回退。**

## 7. 待验证

- [ ] `stepaudio-3-realtime-preview`（开放平台通道）与 `stepaudio-2.5-realtime`（Step Plan 通道）的
      实际延迟与音质差异
- [ ] Realtime 的 function call 事件流：文档自相矛盾（`response.output_item.added` 说 item 仅支持
      `message`，function call 示例却是 `type:"function_call"`）
- [ ] 24kHz mono pcm16 输入假设（官方 demo 写 24000，正文未说明）
- [ ] Jev 在**中文**候选控件集上的准确率 vs 英文
- [ ] state 增大（10/50/200 个候选控件）时 Jev confidence 的退化曲线
- [ ] 「编号语义消歧」方案的实际准确率（替代 VLM 直接给坐标）
