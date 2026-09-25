# 谱系：并入 os 的旧仓库

现行文档。2026-09-23 起，`os` 是唯一开发仓库。下列仓库已冻结：不再提交，只作迁移来源和考古。
`kairos` 与 `Javis` 已于 2026-09-25 由用户决定删除（本地目录与 GitHub 仓库），不再作为来源；`docs/development/` 冻结记录中对它们的引用以此为准。
所有路径相对 `/Users/mahaoxuan/Desktop/AI 产品/`。产品方向见 `docs/PRODUCT.md`。

## 冻结点

| 仓库 | 冻结 tag | 提交 | 冻结时所在分支 | 备注 |
| --- | --- | --- | --- | --- |
| `我的agent`（奕枢） | `archive/2026-09-23-frozen` | `a4afa31` | `feat/issue-35-duplex-voice`（包含 `main`） | 另有 6 个未合并分支原样保留；#36 免按键采集在真机上是断的 |
| `Yishu` | 不是 git 仓库 | — | — | 奕枢的运行时数据与用户个人记忆；不是代码，不入库 |
| `By-Your-Side` | 不在本谱系内 | — | — | 用户 2026-09-23 决定：不纳入本仓库的规划和合并，也不冻结、不改动 |

tag 只在本地创建，未推送。仓库目录可在对应能力于 `os` 跑通后再删除，删除前需用户确认。

## 迁移清单

状态：`待迁`、`已迁`（附 os 中的位置）、`放弃`。迁的是契约和思路，不整文件复制；Swift 代码迁入时按 `os` 的命名和边界重写。

### 来自我的agent（奕枢）

| 内容 | 来源 | 去处 | 状态 |
| --- | --- | --- | --- |
| 朋友口吻、先出声再做事的说话规则 | `我的agent/packages/runtime/src/persona.ts` | 人格提示词 | 已迁口吻与诚实几条：`CompanionManager.companionPersonaInstructions`。「先出声再做事」未照搬：模型自由说的开场白与 `os` 的工具前语音压制契约冲突；2026-09-24 改为由应用说一句固定受理（见 `docs/PRODUCT.md`「已定的方向」），未实现 |
| 光标指向与到达标记 | `我的agent/apps/clicky/leanring-buddy/OverlayWindow.swift`、`OverlayMarks.swift`、`YishuMark.swift` | 现有 Overlay | 待迁 |
| Blobatar 哈希形象（MIT） | `我的agent/apps/clicky/leanring-buddy/YishuBlobatar.swift` | 角色形象候选 | 暂缓 |
| 可见记忆契约：`记忆.md` 唯一真相、忘记删不净即报错 | `我的agent/packages/kernel/src/memory/` | Swift 重写 | 待迁（阶段 6：跨会话记忆） |
| 播放完成语义、句尾静音裁剪 | `我的agent/apps/clicky/leanring-buddy/YishuSpeechClipPlayer.swift` | 语音播放 | 待迁，遇到对应问题时 |
| 免按键双工的边界：界面说在听就必须真在采、预录缓冲、开口只停声不取消任务 | `我的agent/apps/clicky/leanring-buddy/YishuDuplexAudioFloor.swift` 等 | 唤醒词/免按键阶段 | 只迁契约，不迁实现 |
| 语音延迟闸门口径 | `我的agent/evals/voice/check-latency.mjs` | 响应延迟与打断延迟测量 | 已按 `os` 遥测重写：`scripts/acceptance/voice_latency_report.py` |
| 已踩的坑：本机回环请求须绕过 7897 代理（否则每次 +1.4 s）；不要在 `cancel()` 里调 `URLSession.invalidateAndCancel()`（会崩） | `我的agent/docs/ARCHITECTURE.md`、`agent-learning/wiki.md` | 参考 | 只读参考 |
| StepFun 订阅版 `stepaudio-2.5-realtime` 中文指令 0/12 不调工具 | `我的agent/evals/voice/exp5-stepfun-tools/results.md` | 参考；`os` 因此走开放平台 | 只读参考 |
| Node runtime/kernel、EverOS（Python）、`agent-core`、8787 worker、Stagehand | — | — | 放弃（第二运行时） |

### 来自 Yishu（用户数据）

| 内容 | 来源 | 去处 | 状态 |
| --- | --- | --- | --- |
| 用户写下的记忆条目 | `Yishu/记忆.md`、`Yishu/Memory/personal/` | 可见记忆文件建好后，由用户确认再导入 | 待定（阶段 6：跨会话记忆）；不进 git |

## 竞品研究

本地产物（`out/` 被 gitignore）：
- `out/research/2026-09-23-competitors.md`：Meta Muse、Incredible、Today AI 等 15 个产品的对比，每条带来源。
- `out/research/2026-09-23-teardown.md`：Today、Incredible、Littlebird 安装包静态拆解（未运行）。原始文件在 `/tmp/her-teardown/`。
