# Her 并行工程工单：真实用户路径门禁

这组工单把当前验收中发现的问题拆成互不抢文件的独立工作流。每个工单必须由一个独立 Agent、一个独立 worktree、一个独立分支完成。完成不以单元测试数量、覆盖率或模型自评为准，只看真实产品入口产生的可复验证据。

> 最新状态：Wave 1 与 06 已合入 `aa57ea5`；2026-09-23 原生 Build 成功后的真实复验未通过。请先读 [集成复验与裁决](INTEGRATION-RECHECK.md)，执行 01R / 03R / 06R；08 为非阻塞整理，07 暂不放行。下面的冻结基线和 Wave 1 分工保留为原批次流程，不表示当前仍未提交。

## 总目标

1. 多步骤自然语音不再把网页控件误解为应用。
2. 进度播报不把“动作已送达”说成“结果已确认”。
3. 所有关键验收都能从正式 Her Debug 构建出发，一条命令生成证据包。
4. delivery unknown 与旧恢复日志通过真实故障/恢复路径验证，而不是只做纯函数断言。
5. 仓库规则、产品文档与代码事实一致。
6. 以上门禁完成后，再统一 Voice 与 localhost Harness 的任务事实权威。

## 测试原则

完成标准按以下优先级判断：

```text
真实用户意图
→ 正式产品入口
→ 真实供应商 / 真实执行器 / 受控页面
→ 真实世界副作用
→ 独立状态读回
→ Her 回执与语音
→ 故障后的恢复与防重复
```

- 单元测试不是任何工单的完成门禁，不新增覆盖率目标。
- 现有 XCTest / Swift Testing 只作为回归保护，不能替代 E2E。
- 每个 E2E 必须产出 JSON 证据，不以退出码或日志中一个 PASS 字样判定成功。
- 合成 PCM 可以验证生产语音协议链路，但不能冒充真人麦克风验收。
- 所有真实桌面动作只能打到 `tools/voice-acceptance/fixture.py` 提供的本地页面。
- 禁止使用真实用户网页、私人数据、旧仓库密钥或截图作为夹具。

## 并行前置：必须先冻结基线

当前 checkout 有大量已保存但未提交的修改。多人并行之前，必须先执行 `00-freeze-baseline.md`，形成一个所有 worktree 都能引用的不可变 commit。没有基线 commit，不允许创建并行 worktree。

## 分工与文件锁

| 工单 | 可并行批次 | 独占文件范围 | 依赖 |
| --- | --- | --- | --- |
| 00 冻结基线 | Gate 0 | Git 元数据，不改产品代码 | 无 |
| 01 多步骤语音意图 | Wave 1 | `CompanionManager.swift`、`StepFunRealtimeTools.swift`、必要时 `StepFunRealtimeToolRouter.swift` | 00 |
| 02 证据感知进度语言 | Wave 1 | `DesktopTaskContract.swift`、`CompanionPanelView.swift`、`VoiceTaskContinuityProbe.swift` | 00 |
| 03 Her E2E 总运行器 | Wave 1 | `scripts/acceptance/**`、`tools/voice-acceptance/fixture.py`，不改产品代码 | 00 |
| 04 真实 unknown / recovery 故障验收 | Wave 1 | `ActionExecutor.swift`、`WorkflowRunner.swift`、`DesktopTaskJournal.swift`、`VoiceRouteProbe.swift`、新增 DEBUG probe | 00 |
| 05 规则与验收文档真相 | Wave 1 | `AGENTS.md`、现有 `docs/development/**` / `docs/local-development.md`、`tools/voice-acceptance/README.md`，不改本任务目录和产品代码 | 00 |
| 06 Key 保存后错误状态闭环 | Wave 1B | `KeychainStore.swift`、`ProviderSetupView.swift`、`CompanionManager.swift` | 01 合并后 |
| 07 单一任务事实权威 | Wave 2 | `TipTourEngine.swift`、`TipTourHarnessServer.swift`、新增 task authority/adapter | 01–05 合并后 |

任何 Agent 不得修改其他工单的独占文件。确实需要跨界时，停止并由集成负责人重新切分，不允许两个分支同时编辑同一核心文件后再靠人工解决大冲突。

## 工作树规则

每个工单：

```text
一 Agent
一 Issue
一独立 worktree
一 workspaceId
一份 out/acceptance/<issue-id>/ 证据
```

建议分支：

```text
fix/her-voice-multistep-intent
fix/her-progress-evidence-language
test/her-e2e-runner
test/her-unknown-recovery-e2e
docs/her-contract-truth
fix/her-keychain-error-reconciliation
feat/her-unified-task-authority
```

开发中不得从其他 worktree 拷贝未提交文件。合并顺序由集成负责人控制：`01 → 02 → 04 → 03 → 05 → 06 → 07`。03 可提前开发，但最终证据必须在 01、02、04 合并后的集成分支重跑。

## 所有工单共同禁止事项

- 不运行终端 `xcodebuild`；正式构建只能用 Xcode 原生 Build。
- 不默认开启 `--voice-task-continuity`。
- 不修改其他仓库，不迁移 Yishu 私人数据。
- 不新增第二套任务协调器、第二套 TTS、Node runtime 或供应商。
- 不为了测试硬编码“打开显示设置”“缩放选项”“设置”等夹具文案到产品逻辑。
- 不把模型说成功、工具调用返回、页面任意变化当成目标完成。
- 不自动重试 delivery unknown。
- 不顺手做全仓 TipTour → Her 类型改名或无关 warning 清理。

## 统一证据包

每个工单至少生成：

```text
out/acceptance/<issue-id>/result.json
out/acceptance/<issue-id>/commands.txt
out/acceptance/<issue-id>/app-identity.json
out/acceptance/<issue-id>/README.md
```

`result.json` 至少记录：

```json
{
  "commit": "...",
  "app_bundle": "Her.app",
  "bundle_id": "com.yishuziyu.her",
  "team_id": "87DM76C54G",
  "entrypoint": "...",
  "provider_connection_attempted": true,
  "synthetic_audio": true,
  "microphone_opened": false,
  "desktop_fixture_only": true,
  "scenarios": [],
  "passed": true
}
```

每个场景必须同时保存：用户原话、模型工具参数、task/turn/attempt ID、Her 回执、独立 `/state`、最终语音文本、失败恢复结果。

## 最终汇报

每个 Agent 只按以下结构汇报：

1. 原本用户会遇到什么问题。
2. 是否做成。
3. 真实 E2E 怎么跑，独立状态发生了什么。
4. 失败注入与恢复发生了什么。
5. 实际修改文件。
6. 未完成或需要裁决的内容。

不得用“新增了多少测试”“覆盖率多少”“Reviewer 认为没问题”代替真实结果。
