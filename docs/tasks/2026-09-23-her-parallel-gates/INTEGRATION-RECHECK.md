# 集成复验与下一批裁决

本次检查基线：`integration/her-action-facts-baseline@aa57ea589134cd6989c1f37d966423b240fa26ac`。
检查开始时工作树干净；产品代码没有被本次复验修改。下面区分实际执行结果和静态检查发现。

## 裁决

**代码已集成，但真实用户路径尚未验收通过。07 暂不启动。**

Xcode 原生 Build action `87153-28` 已成功；构建路径为本 checkout 对应 DerivedData 的 `Debug/Her.app`，二进制修改时间为 2026-09-23 06:14:09 +0800。
因此当前不再缺“用户手动 Build”这一步。使用集成版本实跑后，暴露的是运行器前置条件和工具参数兼容问题。
该二进制 SHA-256：`d3f4295d6baa4cb15dbd124c03827a361999159cb5341a7bb6a185b615b2d7f2`；运行器身份记录确认 bundle/team/signature/freshness 均通过。它的凭据检查仅证明 StepFun 条目存在，实际供应商已连接由本次 probe 日志另行证明。

实际执行命令：

```sh
python3 scripts/acceptance/her_voice_e2e.py \
  --app '/Users/mahaoxuan/Library/Developer/Xcode/DerivedData/tiptour-macos-gtcdcfrkrqlavldfoxxsyfksnyrq/Build/Products/Debug/Her.app' \
  --out out/acceptance/integrator-20260923-0615 \
  --repeat-scenario two_step_display_settings_scale=3 \
  --require-evidence-language
```

## 实际证据

| 项目 | 本次结果 | 证据及边界 |
| --- | --- | --- |
| 集成构建 | PASS | Xcode 的 completed=true、status=succeeded；没有使用终端 xcodebuild |
| A：右侧设置 | FAIL / 环境前置不足 | 参数为 click + region=right，但探针日志 `accessibility:false`，Driver 返回 `AXInputError error 3`；运行器报告 clicks 增量 0，selected=null，events=[] |
| C：两步语音，第 1 次 | FAIL / 参数契约冲突 | 真实模型同时返回顶层 action=click 和两个 steps；validatedSteps 在进入补救门禁前拒绝多步/单步混用；无动作发生 |
| C：第 2 次改述 | FAIL / 参数契约冲突 | “先点…再点…”仍返回 action + steps，遭同样拒绝 |
| C：第 3 次、Continuity、U | NOT_RUN | 因已确认辅助功能前置不足而停止后续桌面实验；不计失败重试成功率，也不替换为隔离测试 PASS |
| 清理 | 完成 | 19475 无监听、无 runner/probe/fixture 遗留进程；用户原 Her PID 10531 未停止 |

原始报告位于上述证据目录的 `scenario-artifacts/<scenario>/run-N/realtime.json` 与 `probe-voice_task.log`。
中止发生在第三次 C 的页面准备阶段，运行器执行了清理，但没有写出总 `result.json`。**这是运行器的另一处缺口，不能把缺失总报告说成成功。**
本次没有打开麦克风或播放音频，没有完成真人语音验收。辅助功能为何在该子进程中不可用尚未确定；直接启动 Mach-O 而非 LaunchServices 的调用身份是待核查假设，不是已经证实的根因。不得因此重置 TCC 或修改授权数据库。

两个 C 报告还带有没有来源证明的 expected_label（如“显示设置页面已打开”）。它目前没有走到执行阶段；应作为紧接着需要处理的风险，不得先归为已实测的验证失败。

## 六项取舍

1. 旧二进制意外运行：保留为修复前/无效验收证据，不删除、不转成通过。以后身份/新鲜度/权限不成立必须在供应商与 Driver 调用前阻断。
2. JEV 缺失：维持 JEV 可选。无 JEV 的 StepFun 路径仍须通过；真正 JEV 专项单列 BLOCKED，不借用旧仓库密钥，也不以 StepFun fallback 冒充 JEV 验证。`security` CLI 返回 44 是命令退出码，报告不得将其写成原生 OSStatus 44。
3. 01 范围：不做全局模糊改写。仅为实际复现的“有序 steps + 冗余顶层 action”补一条有明确条件、可审计的无损规范化，或令正式模型调用稳定符合契约。矛盾目标、操作、数量及用户限定仍拒绝。不得统一丢弃 expected_label 让用例变绿。
4. 06：保存状态与可使用状态分离。条目存在可作为“已保存”和进入权限配置的依据，不能等于“已就绪”。只有成功读取可用值才能放行供应商调用；unknown 不能推断为存在。刷新存在性不能清掉仍然有效的拒读错误。
5. Gemini 同类文案纳入 06R 共用凭据语义修复，不借机恢复 Gemini 产品能力；旧诊断路径单列 08，低于阻塞项优先级，不迁移旧日志。
6. 07：待 01R/03R/06R 的真实门禁完成，集成重跑后才讨论放行；08 不阻塞 07。不默认启用实验入口，不新建运行时。

## 本批并行分工

| 工单 | 独占产品/工具文件 | 独立验收 |
| --- | --- | --- |
| [01R](01R-sequence-contract.md) | StepFunRealtimeTools.swift、StepFunRealtimeToolRouter.swift；专属重放证据 | 同一两步原话 3 连过，加改述；无参数拒绝、无丢步骤、无伪造后置条件 |
| [03R](03R-runner-preconditions.md) | scripts/acceptance/**、场景 JSON、fixture.py、VoiceRouteProbe.swift、必要的 DEBUG preflight | 缺权限零调用；正确入口可执行；中断必有报告；A/C 不能用 uncertain 冒充完成 |
| [06R](06R-key-state-ui.md) | KeychainStore.swift、ProviderSetupView.swift、CompanionManager.swift、CompanionPanelView.swift、GeminiLiveSession.swift | 真正设置→保存→拒读/恢复→启动路径；不谎报缺失/可用，不清掉有效错误 |
| [08](08-diagnostic-identity.md) | DesktopVoiceTrace.swift | Her 新诊断只进 Her 目录，旧目录不改，默认无原文诊断 |

代码可以四路 worktree 并行；**同一台 Mac 的原生 Build、签名产物和真实桌面验收串行**。不同文件无冲突不代表能同时操纵同一前台窗口、同一 DerivedData 或同一钥匙串验收服务。
01R/06R 不修改 03R 总运行器，每人提供自己证据包中的验收输入/预期；03R 接线。公共 AGENTS/README 由集成负责人按最终事实更新，各分支不争抢。
本批从上述不可变源码基线分出 worktree；本目录新增说明先由集成人员保存为可分发的工单快照，禁止复制其他 worktree 的未提交业务代码。
