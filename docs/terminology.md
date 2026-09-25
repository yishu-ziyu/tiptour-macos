# Terminology

One name per concept. Use these names in documents, commit messages, task hand-offs and code comments. Do not invent nicknames or metaphors for stages, metrics or components; when a code identifier exists, the identifier is the name.

Adopted 2026-09-23 after the user rejected metaphor names (在场, 记得, 收窄, 浏览器手, 教一遍, 光球, 身体, 克制) because they blur meaning when agents hand work to each other. Dated records written before that keep their original wording.

## Roadmap stages

Write a stage as `阶段 N：名称` (Chinese) or `Stage N: name` (English). Status and exit criteria: [ROADMAP.md](ROADMAP.md).

| # | 名称 | English | Replaces |
| --- | --- | --- | --- |
| 1 | 仓库合并与产品准则 | Repository consolidation and product principles | 准则与归档 |
| 2 | 语音对话质量 | Voice conversation quality | 在场 |
| 3 | 首次使用与界面设计 | First-run guidance and interface design | — (new) |
| 4 | 调用其他 AI 工具 | Delegating to other AI tools | — (new, 2026-09-25) |
| 5 | Chrome 扩展操作网页 | Chrome extension for web actions | 浏览器手 |
| 6 | 跨会话记忆 | Cross-session memory | 记得 |
| 7 | 移除 Gemini 并合并任务路径 | Remove Gemini and unify task paths | 收窄 |
| 8 | 录制演示并回放 | Record a demonstration and replay it | 教一遍 |
| 9 | 唤醒词与主动提醒 | Wake word and proactive prompts | 主动与唤醒词 |

Stages were renumbered on 2026-09-25; dated records before that use the old numbers (see [ROADMAP.md](ROADMAP.md) 取代关系).

## Value metrics

Definitions and targets: [PRODUCT.md](PRODUCT.md).

| 名称 | Measures | Replaces |
| --- | --- | --- |
| 响应延迟 | user stops speaking → her first audio (p50, real microphone) | 在场 |
| 打断延迟 | user starts speaking over her → her audio stops | 在场 |
| 虚报完成 | spoken completion claims that independent readback contradicts | 可信 |
| 跨会话记忆 | a fact said once is used in a later session | 连续 |
| 打扰控制 | proactive prompts the user accepts; false wake-ups per hour | 克制 |

## Components and states

| 名称 | Meaning | Code |
| --- | --- | --- |
| ThinkingOrb 状态指示 | the animated dot sphere showing connecting / listening / responding / idle | `TipTour/UI/ThinkingOrb/` (never "光球") |
| 系统级状态界面 | orb, captions, task progress; low-noise, off-centre | — |
| 角色形象 | a future embodied character; not built | — (never "身体") |
| 面板 | the menu bar panel | `CompanionPanelView` |
| 产品简介 | the six-part summary at the top of PRODUCT.md (what she is, for whom, why build her, first thing to do well, bottom line, not doing); every other section must agree with it | [PRODUCT.md](PRODUCT.md) |
| 验收任务 | the ten user sentences every stage is accepted against | [PRODUCT.md](PRODUCT.md) |
| 失败分析 | the user reads real runs, notes what went wrong in free text, then groups the notes into failure categories | — |
| 回执 | the per-turn receipt of what was delivered and verified | `DesktopTaskReceipt` |
| 提供方模式 | StepFun voice / JEV text / Gemini | `TipTourMode` |
| 冻结仓库 | 我的agent at tag `archive/2026-09-23-frozen` | [lineage.md](lineage.md) |
