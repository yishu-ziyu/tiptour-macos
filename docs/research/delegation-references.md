# 把活交给编程智能体：开源项目怎么做

现行研究文档，2026-09-25 建立。回答[阶段 4 最小版本地图](../development/2026-09-25-claude-code-delegation-map.md)里「还没弄清的」前几项。用户要求「不要猜，参考现有的开源且优质的项目」，所以每个结论都指向具体项目的源码或文档。

## 看了哪些项目

2026-09-25 用 `gh api` 核对存在、活跃度和许可证。

| 项目 | 星数 | 最近推送 | 许可证 | 为什么看它 |
| --- | --- | --- | --- | --- |
| [slopus/happy](https://github.com/slopus/happy) | 2.4 万 | 2026-09-22 | MIT | Claude Code / Codex 的手机和网页端，带实时语音；最接近「用嘴派活」 |
| [BloopAI/vibe-kanban](https://github.com/BloopAI/vibe-kanban) | 2.8 万 | 2026-09-19 | Apache-2.0 | 把任务派给 Claude Code、Codex 等并审查改动 |
| [smtg-ai/claude-squad](https://github.com/smtg-ai/claude-squad) | 8500 | 2026-08-20 | AGPL-3.0 | 管理多个编程智能体会话；只看设计，不借代码 |
| [screenpipe/screenpipe](https://github.com/screenpipe/screenpipe) | 2.2 万 | 2026-09-25 | 源码可见（非开源） | 本机记录屏幕并给智能体当上下文；只看设计，不借代码 |

## 各自怎么做

**分辨「派活」还是别的**：happy 不单独做分类。语音模型手里有 `messageClaudeCode` 和 `processPermissionRequest` 两个工具，由它在对话里决定调不调；提示词要求它默认把用户当成在口述、先记下，等用户把要求说完再发，自己不做重大决定（`packages/happy-app/sources/realtime/voiceSystemPrompt.ts`）。发给哪个会话也不猜，就是用户正在看的那个（happy 仓库的 [voice-architecture.md](https://github.com/slopus/happy/blob/main/docs/voice-architecture.md) 的 Session Routing 一节）。

**智能体做完或卡住**：happy 把「做完了」和权限请求作为一条消息推给语音；有人正在说话时排队，安静了再一起说（同上文档，Context Delivery 一节）。

**权限**：happy 通过官方 Agent SDK 的 `canUseTool` 回调把每次权限请求转给用户，用户可以顺带放行同一类请求（`packages/happy-cli/src/claude/utils/permissionHandler.ts`）。vibe-kanban 不用 SDK，直接启动命令行：`claude -p --output-format=stream-json --input-format=stream-json`，需要审批时加 `--permission-prompt-tool=stdio`，经标准输入输出应答；不需要审批时给 `bypassPermissions`（`crates/executors/src/executors/claude.rs`）。它之所以敢给最大权限，是因为每个任务都在单独的 git 工作区和分支里跑，用户看完差异再合并（README）。

**当前项目**：两个项目都不猜。happy 的会话就是用户在某个目录里启动的那个；vibe-kanban 由用户事先登记项目。

**用户最近在做什么**：screenpipe 不替智能体打包上下文。它在本机持续记录（优先读无障碍树，OCR 兜底；过滤密码框等；约 20GB/月），然后通过 MCP 或技能文件让 Claude Code 等在需要时自己查（README）。

## 本机实测

2026-09-25，Claude Code 2.1.280，在临时 git 仓库里运行 `claude -p "把 a.txt 的内容改成 world，然后只回复 DONE" --output-format stream-json --verbose --permission-mode auto --no-session-persistence`：退出码 0，约 8 秒，文件确实被改，`git status` 独立读回为 ` M a.txt`；事件流含 `task_summary` 进度事件和结尾的 `session_id`；本次花费 0.13 美元等值。用户全局钩子也被触发，在仓库里生成了 `.statamcp/`。

Codex 0.156.1 的 `codex exec` 支持 `-C <目录>`、`--sandbox`、`--json`、`resume`，尚未实测。

## 使用条款

[Claude Code 法律与合规页](https://code.claude.com/docs/en/legal-and-compliance)（2026-09-25 读）：第三方不得把 Claude 登录做进自己的应用，也不得替用户转发订阅额度；但不妨碍最终用户用自己的订阅登录**未修改的** Claude Code 二进制。Her 调用用户本机安装的原版 `claude`、不接触登录凭证，属于后一种。订阅的用量上限按「普通的个人使用」设计，Her 不应在后台反复调用。Codex 的条款尚未查。

## 结论与决定

用户 2026-09-25 逐条选定，记录在地图的「已做的决定」：

1. 学 happy：Ctrl+K 改成和她对话，她边聊边攒需求，把要发的内容给用户看，用户确认才交出去；她手里有「交给 Claude Code」和「让 JEV 点屏幕」两个工具。
2. 学 vibe-kanban：每次派活在单独的 git 工作区里跑，权限用 `auto`；汇报时附上差异，用户同意后再合并。
3. 学 happy：当前项目跟着用户最近使用 Claude Code 的目录；用户说了别的项目名就用那个。
4. 学 screenpipe：用户交给她的案例和她记下的事存在本机一个文件夹里，派活时告诉 Claude Code 在哪、怎么查，由它按需读取。
