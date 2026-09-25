# docs/development 索引与文档性质

本目录混放两类文档。读之前先确认你看的是哪一类，改之前先确认你有没有被授权改它。
分类说明由 2026-09-23 的"规则与验收文档真相"工单添加，只标注性质，不改写任何历史正文。

| 文件 | 性质 | 维护规则 |
| --- | --- | --- |
| `README.md`（本文件） | 现行索引 | 随时更新 |
| `2026-09-21-trustworthy-desktop-control.md` | 现行控制契约（`AGENTS.md` 指向的当前契约） | 契约/验收章节必须与代码一致，可修改；`执行记录`、`最终记录` 两节是当时的现场记录，不改写 |
| `2026-09-22-voice-task-lifecycle.md` | 现行持续任务方案与接缝记录 | 方案、接缝决策、验收矩阵可修改；`本轮验证与真正的阻塞`、`第 8 节历史现场` 及其中列出的本机 `/tmp` 日志是历史记录，不改写 |
| `2026-09-23-voice-conversation-quality.md` | 现行阶段契约（阶段 2，原名 `2026-09-23-presence.md`） | 契约一节可修改；证据一节只追加，不改写 |
| `2026-09-23-first-run-and-interface.md` | 现行阶段契约（阶段 3） | 契约一节可修改；证据一节只追加，不改写 |
| `2026-09-25-claude-code-delegation-map.md` | 现行工作契约（「把活交给 Claude Code」这一段的唯一地图，阶段 4 最小版本） | 随每步更新；到达目的地后冻结 |
| `2026-09-25-listen-and-baseline-map.md` | 停放的工作契约（「能听见你并跑出失败清单」，2026-09-25 停放） | 恢复前不改；恢复时从步骤 1d 接着走 |
| `2026-09-25-product-definition-map.md` | 工作契约（产品定义这一段的地图，2026-09-25 已到达并冻结） | 只在收件箱追加 |
| `2026-09-23-acceptance-infrastructure.md` | 现行约定文档 | 与代码冲突时以代码与 `AGENTS.md` 为准 |
| `2026-09-20-desktop-companion-acceptance.md` | 历史证据日志（2026-09-20，冻结） | 不改内容 |
| `2026-09-20-voice-audio-format.md` | 历史证据日志（2026-09-20，冻结） | 不改内容 |
| `2026-09-20-voice-click.md` | 历史证据日志（2026-09-20，冻结） | 不改内容 |
| `2026-09-20-voice-rebuild.md` | 历史证据日志（2026-09-20，冻结） | 不改内容 |
| `2026-09-21-decision-packet-fanout.md` | 历史证据日志（2026-09-21，冻结） | 不改内容 |
| `2026-09-21-open-app-1349-postmortem.md` | 历史证据日志（2026-09-21，冻结） | 不改内容 |
| `2026-09-21-realtime-voice-continuity.md` | 历史证据日志（2026-09-21，冻结） | 不改内容 |
| `evidence/2026-09-20-*.log` | 原始测试输出（2026-09-20，冻结） | 不改内容；不得用新运行覆盖失败记录 |

## 三条硬规则

1. 历史日志里的失败、阻塞、未通过项必须原样保留。用新的运行覆盖旧的失败记录来"变绿"属于伪造证据。
2. 当前事实只写在 [`docs/README.md`](../README.md) 标为 Current 的文档和根目录 `AGENTS.md` 里。历史日志只回答"那天那台机器上发生了什么"，不随代码演进而更新。
3. 历史日志里某条事实已经过期时，在现行文档中写正确版本并说明它取代了哪一份记录的哪一条，
   不要回到旧文件里改那句话。

## 步骤完成判据的唯一权威

任何文档描述"这一步算不算完成""算不算 verified""算不算 uncertain"时，唯一权威是
`TipTour/Voice/DesktopTaskContract.swift` 里的 `DesktopActionCompletion`，以及
[`docs/architecture/step-completion.md`](../architecture/step-completion.md) 中与之逐项对应的真值表。
不得自行推导，也不得把"未独立验证"直接等同于 `uncertain_effect`。

## 常见过期项

写新文档或改旧文档时，这些是最容易再次过期的地方，每次都要回代码核对：

- 产物路径：现在是 `Her.app/Contents/MacOS/Her`、bundle ID `com.yishuziyu.her`、
  Team `87DM76C54G`；Xcode target/scheme 仍叫 `tiptour-macos`，Swift module 仍叫 `TipTour`。
- 测试脚本名与可传参方式：见 [`docs/guides/build-and-verification.md`](../guides/build-and-verification.md)；
  `scripts/test-jev.sh`、`scripts/test-local-perception.sh` 不接受 Swift test filter，
  两个 StepFun 脚本接受。
- 各源文件的近似行数：以 [`docs/architecture/key-files.md`](../architecture/key-files.md) 为准，误差超过 50 行时按
  `AGENTS.md` 的文档同步规则更新，`scripts/check-docs.py` 会检查。
