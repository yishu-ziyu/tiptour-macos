# 语音与任务生命周期分离：主 Issue 草案与接缝方案

日期：2026-09-22。状态：**实验实现已接线，默认关闭；Her 身份与 Personal Team 签名已迁移完成，等待 Her 首次权限与 API Key 配置后继续真实语音验证。尚未完成整仓融合或真人验收。**
执行：ChatGPT 主代理通过 DevSpace，直接读取实际 checkout；未委派。
本文件合并主 Issue、接缝决策、验收要求与核查记录，不另建平行规格。
GitHub `yishu-ziyu/tiptour-macos` 当前 `has_issues=false`，故只保留本地草案，不更改仓库设置。

## 0. 当前恢复入口（本轮续接，覆盖文末旧现场）

### Her 身份迁移（2026-09-22 晚）

最终产品名已确认改为 **Her**。当前 Xcode 产品身份已迁为 `Her.app` / `com.yishuziyu.her`，开发签名改用 Personal Team `87DM76C54G` 的 `Apple Development`，内部 Swift 模块和历史 `TipTour*` 类型暂不做全量改名。旧 `com.yishuziyu.tiptour` Keychain/TCC 数据不迁移、不删除；Her 通过正常 UI 重新写入自己的 provider keys，并重新取得 macOS 权限。Xcode 原生构建已成功，最终产物 `CFBundleExecutable=Her`，`codesign --verify --deep --strict` 通过，Authority 为 `Apple Development: yishuziyu@gmail.com (N7M4BXHV68)`，TeamIdentifier 为 `87DM76C54G`。

用户要求最终只保留一个产品主仓库；执行继续由当前主代理承担，重要架构变化先沟通。
已确认的 os/Swift 首轮路线不变，没有新 Node 运行时、仓库移动、旧仓库删除或用户数据迁移。
当前仍在 `main@099279d` 的未提交工作树上接续；没有提交、推送或修改其他项目。

### 已接上的实验路径

`--voice-task-continuity` 启用应用持有的任务路由器；语音连接只持有绑定句柄。
`DesktopTaskCoordinator.submit` 独立持有执行 Task，语音等待者取消不再销毁任务。
`task_control` 提供进度、续接和显式取消，写操作绑定 task/target-version/current-turn。
面板显示真实任务快照；快照更新注入模型上下文但不触发主动口播。旧连接不能操作新连接的任务。

共享执行层已经区分 completed/stopped/skipped，并按 operation ID 读取终结事实；
在途 driver 未返回时仍占用执行器。任务归属的已结算 workflow 被收回，避免暂停计划成为无法续接的占位。
任务 ID、动作 attempt ID、观察 ID 分离。元数据日志在接收及下发前原子保存；
恢复只恢复事实与保守暂停，不自动重发，没有长期记忆正文或输入内容迁移。

本轮在继承实现上新增失败复现并修复：

- 过期纠正先暂停现行任务、再判过期：改为控制生效前先校验，等待后的校验仍保留。
- 新开口覆盖断线暂停原因：只有打断正在运行的任务才取得“问进度后可自动继续”的资格。
- 问进度等待在途读回：先返回快照；续接意图只保存绑定信息，待旧动作结算后再次检查。
  取消、新轮次、断线或未确认效果都会使待续接失效，不引入第二个执行器。
- 最后一步已验证却因插话一直 paused，或未知效果被泛化为 paused：结果保留为 completed / uncertain_effect，
  显式取消仍优先保持 cancelled，已发生动作不重做。
- resume 的第二处宽松判断丢弃新 region：解析及路由共享同一个严格判断，不静默删掉用户限定。
- 自动续接进入同应用另一窗口：第一份新观察必须匹配已验证后态的 app/window/content version；
  本任务自己的已验证变化可继续，其他窗口/页面变化则保持暂停。
- 无法读取恢复文件却不显示问题、其他入口仍可动作：保留原文件、显示 storage_failed 并关闭准入。
- 旧 Gemini 工具可抢占保留任务，以及指针入口在忙碌时先感知/激活：统一前置拒绝，不消费下一轮工具名额。

### 仍未完成的部分

旧 harness 的 `TipTourLongTaskCoordinator` 仍有独立任务表，目前只与实验任务互斥，尚未改成同一任务所有者的兼容投影。
故不能把这一状态称作“全部入口已统一”或“几个仓库已经合并”。其他仓库仍是后续按能力筛选的来源。
恢复日志只保存当前任务的最小恢复元数据，不是长期历史库；不声称已经实现跨日自主任务或记忆融合。
真实供应商的异步任务上下文/工具控制尚未通过；真实桌面和真人麦克风也未验收，实验入口继续默认关闭。

### 本轮验证与真正的阻塞

- 修前失败日志：`/tmp/tiptour-resume-stale-correction-red.log`、`/tmp/tiptour-resume-pause-origin-red.log`、
  `progress-red.log`、`recovery-red.log`、`final-readback-red.log`、`router-red.log`、`window-red.log`、
  `operation-retire-red.log`、`legacy-gate-red.log`、`perception-gate-red.log`（后八个同样以前缀 `/tmp/tiptour-resume-` 开始）。
- 当前完整隔离回归：`/tmp/tiptour-resume-current-lifecycle.log`，87 XCTest + 30 Swift Testing 通过，含 16 项持续任务场景。
- 额外现有回归：`/tmp/tiptour-resume-stepfun.log` 14 项、`/tmp/tiptour-resume-jev.log` 16 项、
  `/tmp/tiptour-resume-perception.log` 14 项通过。它们与集成测试分层记录，不合计成真人成功率。
- 最终生产源集成 14 项通过：`/tmp/tiptour-resume-final-integration.log`，覆盖真实 engine/runner/router/session 的接缝，
  执行器与捕获在测试中使用无桌面副作用的夹具。最新 79 个应用源文件 typecheck 退出 0：
  `/tmp/tiptour-resume-final-typecheck.log`。`git diff --check` 通过；没有把旧版本的通过当作最新版本通过。
- 旧 TipTour 身份的 Build action `87153-19`、`87153-20`、`87153-21` 均 succeeded；Her 身份迁移后的 `87153-22` 与最终 `87153-23` 也 succeeded。全程未从终端运行 xcodebuild。
  最终构建位于原 DerivedData 的 `Debug/Her.app`，Bundle ID `com.yishuziyu.her`，TeamIdentifier `87DM76C54G`，Apple Development 签名验证通过。未安装到 `/Applications`，也未启动 Her 的正常产品入口。
- 新增 `VoiceTaskContinuityProbe` 使用真实 session/router，但输入和执行器为公开夹具；
  独立启动 DEBUG 探针并自行退出，没有打开麦克风、播放声音、注册热键或操作桌面。
  结果在 `/tmp/tiptour-continuity-live.GoPVed/result-with-keychain-status.json`：
  `phase=keychain`、`keychain_status=-25293`、`provider_connection_attempted=false`。
  这是本机 Keychain 认证失败，不是 StepFun API 失败，也不能解读成用户填写了错误 API key 或密码。
  没有读取 .env 作兜底、输出密钥、修改 ACL 或弹出无人看守的认证窗口。

### Her 授权后的真实接口与桌面证据

用户已在 Her 正常入口重新授予辅助功能、屏幕录制、麦克风，并写入 Her 自己的 StepFun Key。一次 Xcode 原生重建后 Key 仍可读，日志无 `-25293`。随后重跑两轮连续任务探针：`/tmp/tiptour-continuity-live.GoPVed/result-her-after-auth.json`，结果 `passed=true`、`provider_connection_attempted=true`、麦克风未打开、扬声器未播放、桌面动作数为 0。第一轮真实模型调用 `status`，同一 task 保持 `paused`；重连后的第二轮调用 `cancel`，绑定新 turn ID 后同一 task 进入 `cancelled`。

进一步用生产 Realtime session/router/engine 和 Safari 本地夹具执行“请点击右边的设置按钮”。模型连续两次把 `右边` 错发为 `right_click`；第二次已保留原 goal，证明不是用户目标丢失，而是动作字段的同音误判。新增代码边界后，工具参数仍可审计为原始 `right_click`，但执行合同恢复为 `click + region=right`。真实独立 `/state` 结果为 `selected=right-setting`、`clicks=1`，且 decision packet 记录 `action=click`、`region=right`、`location_filtered_in_code`。对应隔离回归增至 StepFun 17 项通过，79 源文件 typecheck 与 Xcode Build action `87153-26` 通过。

该真实桌面动作仍返回 `uncertain_effect`：驱动确认输入已送达，独立测试页也确认右侧按钮生效，但通用产品验证器只接受目标 selected/focused、输入值读回或显式 expected_label；它不会把任意页面变化当作用户目标完成。这个结果证明目标与动作路由已经正确，也暴露出下一项需要裁决的事实层边界，不能把外部验收页的 `/state` 偷渡成通用产品能力。

本轮曾出现一次轮询和一次探针启动的工具安全拦截；同一连接上的单次普通重试成功，
没有转换命令通道绕行。当前阻塞已定位为 Keychain 认证，不能再归因为“源码无法写入”。
两个探针进程均已退出，无临时执行器留在后台；原产品未被本轮停止或重启。

下一步所需的外部条件：首次正常启动 Her，由用户完成新的 Accessibility / Screen Recording / Microphone 授权，并在 Her 设置中重新录入 StepFun key。然后先验证 Her 自己的 Keychain item 能跨一次重新构建继续读取，再重跑已准备的两轮合成语音探针。通过后再安排真实桌面与真人体验，不以复制旧 TipTour secret、关闭校验或换供应商绕过身份迁移。

## 1. 主 Issue：办事期间可以继续说话

用户交给助手一个多步骤任务；询问进度不会把任务取消，补充条件更新同一任务；
明确取消后不再下发后续动作；语音重连不丢掉任务身份和进度；已经发生的动作不被抹掉或盲目重做。

用户已确认先在 os 内收拢任务所有权，授权修改产品代码与隔离验证；不提交、推送、合并、安装、
替换运行中的应用、开启麦克风或操作真实桌面。不移动用户数据，不导出或借用其他项目密钥。

本轮首先服务已有的 1–6 个显式步骤桌面任务，步骤仍由真实用户请求经模型形成并通过既有校验。
这可以验证持续对话与任务并存，**不代表已实现任意自主研究、跨日后台工作或完整崩溃自动续跑**。
这些更长任务的执行器接入仍是后续融合工作，不能拿固定动作剧本替代。

## 2. 已核对的版本与边界

| 来源 | 本轮基线 | 状态与用途 |
| --- | --- | --- |
| `os` / `yishu-ziyu/tiptour-macos` | `main@099279d0ac5fde297ebf1860db559673c63a85db` | 修改前工作树干净；唯一计划写入的产品仓库 |
| `我的agent` / `yishu-ziyu/yishu` | `feat/issue-35-duplex-voice@a4afa31c8c5796b705f8701250301963257490b5` | 只读；有未跟踪 `.statamcp/`，未读取其内容或清理；本地 main 仍为 `13b95b5` |
| `yishu-ziyu/kairos` | Private，`main@5b562688381b86b2dcb21a4513426c2dc1aea25f` | 通过本机已授权 gh 只读核对远端 HEAD；沿用同一不可变版本前轮已读源码，不克隆或修改 |
| `Desktop/AI 产品/Yishu` | 用户数据目录 | 本轮不读记忆正文、不写入、不迁移；旧代码默认 Documents 路径与此处的关系仍未核实 |

Yishu 的 NOTES 仍记录语音 PR #36 NOT_READY、生命周期评估 PR #37 等待合并。
不把不同分支、不同应用或尚未完成的真人验收算成一个已交付产品。
后续执行前重新核对 HEAD 与工作树；本记录不替代届时的现场。

## 3. 源码核查：实际断点

以下路径未带前缀时均相对 `os`。这里描述源码行为，不是本轮运行复现结论。

| 证据位置 | 观察到的行为 | 对本轮的影响 |
| --- | --- | --- |
| `TipTour/App/CompanionManager.swift:348`，`startStepFunVoiceSession` | 每次启动语音都新建 router 和 session | 任务不能继续由该次 router 的生命周期隐式持有 |
| `TipTour/Voice/StepFunRealtimeToolRouter.swift:25–46`、`:88–134` | router 持有 executor/coordinator；`interrupt()` 同时中断 coordinator 并停止共享 WorkflowRunner | 不能只从语音代码删掉一个 cancel；观察、执行依赖也不能仍弱引用将被销毁的 router |
| `TipTour/Voice/StepFunRealtimeSession.swift`，`startToolWork`、`handleUserStartedSpeaking`、`cancelOutstandingToolWork` | session 持有整次工具工作的 Task；插话会取消工具工作并抛弃结果投递 | 声音、结果订阅和任务执行必须拆开取消语义 |
| 同上，`rebuildSessionAfterDiscardedFollowup` | 特定迟到 follow-up 竞态通过重建连接处理；连接历史会丢失 | 不能删除已有竞态防护；产品上下文要独立于连接保存 |
| `TipTour/Voice/DesktopTaskCoordinator.swift`，`run` | 已有 taskID、turnID、targetVersion、明确步骤预算、已验证历史与 uncertain_effect；状态保存在对象内 | 提升现有所有者，不再平行制造另一套任务真相 |
| `TipTour/Core/TipTourEngine.swift:2871–3185`，`TipTourLongTaskCoordinator` | harness 已有另一套显式步骤队列、任务字典、事件与取消；并非通用模型规划循环 | 不能忽略后再加第三个协调器；其完成状态也不能直接升级成语义验证成功 |
| `TipTour/Core/TipTourEngine.swift:1320–1496`，`submitSingleActionWorkflowPlan` | 会激活应用；遇到已有 activePlan 会 stop；这发生在后续部分参数校验之前 | 新入口即使最终被拒，也可能干扰已有工作；授权与占用检查必须早于这些副作用 |
| `TipTour/Workflow/WorkflowRunner.swift:197–364` | start 替换当前 operation token；pause 取消解析任务；resume 重新解析当前动作 | 不能把现有 pause/resume 直接当成安全任务续接，尤其不能重发结果未知的动作 |
| `TipTour/Voice/DesktopTaskExecutor.swift`，`execute`、`executeOpenApplication` | 部分下发后取消检查会提前退出独立验证；打开应用还可能做一次 LaunchServices reopen | 插话后仍须收集已下发动作的结果；reopen/激活同样属于需约束的副作用 |
| `TipTour/Voice/StepFunRealtimeClient.swift:335–410` | 工具输出按 callID 返回；已有不主动发声的窗口数据注入与独立响应请求接口 | 异步任务结果不能复用旧连接 callID；新的任务上下文注入和播报时序仍需供应商探针验证 |

跨仓库复用证据（同一已核对版本）：

- `我的agent/packages/runtime/src/turn-execution-context.ts`：产品统一组装执行上下文，执行器不自行补另一份事实；复用这个边界。
- `我的agent/packages/runtime/src/resource-lease.ts`：`processResourceLease` 是进程内 Map，不是跨应用锁；不能复制到 Swift 后就宣称互斥成立。
- `我的agent/packages/runtime/src/trusted-task-receipt.ts`：可信回执标记是进程内 WeakMap；JSON 中传一个 verified 布尔值不能继承该信任。
- `我的agent/packages/runtime/src/model-loop/model-session.ts`，`createYishuAgentSession`：当前创建的是自研 `YishuModelSession`，不能按旧 Pi 命名推断已接入 Pi SDK。
- `kairos/apps/kairos/Sources/AgencyRuntime/RunLedger/RunLedgerContracts.swift`：租约、取消 generation、授权绑定和幂等标识可参考；不整包搬入账本。
- `kairos/apps/kairos/Sources/AgentHub/PiAgencyExecutionCoordinator.swift`：存在面向特定浏览任务的硬编码步骤提示，不移植为通用规划规则。

## 4. 接缝决策：首轮留在 Swift，不立即接入 Node

**建议：先把 os 已有任务所有权收拢，再引入跨仓库的长任务运行时。**
这修订了前轮“可接受先接一个 TS 运行时”的倾向：深入读取发现 os 自己已经有两条任务管理路径，
现在接入第三套并不能替代修复现有取消、占用和验证接缝。这个选择是范围与维护成本判断，非性能测试结论。

| 方案 | 收益 | 本轮代价与风险 | 决定 |
| --- | --- | --- | --- |
| 在 os 内提升既有任务所有者 | 保留最新语音/感知/验证；不用接旧语音栈；直接覆盖本轮短流程 | 必须合并入口的事实归属，补保守持久化与正确占用边界；不自动获得后台研究能力 | 推荐首轮 |
| 立即接入 Yishu TS runtime/kernel | 为记忆、委派、长期任务提供可复用基础 | Swift/TS 协议、状态映射、进程故障、可信回执与跨入口授权均需适配；旧语音不能沿用 | 等实际长任务需求进入下一阶段再选 |

目标调用关系（设计，不是当前实现）：

```text
Realtime / JEV / Gemini / localhost harness
  → 已验证的任务或动作请求 → 应用级 DesktopTaskCoordinator
  → 既有 TipTourEngine / WorkflowRunner / ActionExecutor
  → 独立结果读回 → 同一任务事实 → 当前有效的语音与界面订阅
```

所有权具体要求：

1. **任务唯一所有者**：提升现有 `DesktopTaskCoordinator` 为应用级对象，统一目标版本、步骤进度、动作事实与终结。
   `TipTourLongTaskCoordinator` 的任务/事件端点只保留兼容投影，停止独立决定同一任务的最终状态。
   它原有确定性动作序列与语音的结果验证语义不同；保持可表达的差异，不能统一成一个虚假的 completed。
   现有观察、选择与执行依赖改由应用级对象提供；只移动必要职责，不复制感知实现，不把新逻辑堆进 CompanionManager。
2. **桌面占用唯一调度**：在既有 engine/runner 边界统一准入，先校验与取得占用，再激活应用或下发动作。
   `runPointerAction`、workflow-plan、harness tasks、JEV/Gemini 及 retry/resume/skip 等本轮可达入口都必须核查。
   无权的新请求返回 busy/拒绝，不自动 stop 旧任务；只有明确针对当前任务的控制请求能改变它。
   占用保持到已下发操作停止并完成有界结果核查；若不能证明已停止，阻止新执行器接手。
3. **语音只拥有呈现与连接**：麦克风、播放、连接 generation、响应与结果订阅仍归 session。
   工具调用的等待者可以停止，但应用级执行 Task 与其事实不能随之被销毁。
   发声只使用当前连接/响应上下文，不向新连接回填旧 function_call_output。
4. **事实独立保存**：连接重建使用应用级任务快照；不得将历史回执、网页内容或重连摘要视为新的执行授权。
   首轮本地持久化仅保存必要身份、版本、步骤类型/索引、目标指纹、动作送达/验证状态，不存音频、截图、输入正文或凭据。
   动作下发意图先持久化；失败则零新动作。应用重启后仅恢复保守暂停/待核查，不自动执行；缺失参数必须重新取得。
   持久化在私有、非 Git 的独立位置完成，不使用或迁移现有 Yishu 记忆目录。

本轮“唯一桌面调度”覆盖此产品的可达入口，**不代表能约束另一独立应用或任意外部脚本**。
当前 os 不接入新的 Codex/Pi 子进程。将来启用外部执行器前，必须补可验证的跨进程占用与停止交接，不能沿用进程内锁作证明。

## 5. 交互、恢复与结果契约

| 输入/事件 | 立即行为 | 后续行为 |
| --- | --- | --- |
| 收到用户开口事件 | 同一处理分支先清待播音频，不等待转写或模型；关闭后续桌面动作的下发门 | 已下发动作继续有界核查；不把任务写成 cancelled |
| 仅询问进度 | 从当前任务快照回答，不创建新任务、不重置预算 | 仅当暂停原因是本次插话、身份/版本/窗口/授权仍有效且无未知效果时，允许继续原已授权步骤 |
| 补充/纠正 | 保留 taskID，更新目标版本；旧版本尚未下发动作失效 | 收妥旧动作事实后重新观察/定位；不能把旧目标结果算作新目标进度 |
| 明确取消 | 关闭后续下发门，进入取消收尾；不可逆动作不假装撤销 | 停止执行并登记已发生部分，再完成终结与占用释放；迟到事件不得复活任务 |
| 意图不清或没有可归属转写 | 不猜测取消、新任务或恢复 | 保持必要暂停，要求补充，不用关键词白名单判断 |
| 断线或明确关闭语音 | 关闭连接相关订阅，桌面后续动作暂停 | 任务仍可查询；明确关闭不得自动开麦；重连必须绑定新连接身份 |
| 已送达但回执丢失/读取失败 | 记录结果未确认，不把空回执当作未执行 | 只回读；无法排除重复副作用时不自动重试 |

任务控制采用结构化请求，绑定当前真实用户轮次及 taskID/目标版本；具体 schema 在实现前与既有工具一起校验。
供应商 callID/responseId 不能充当长期任务或动作尝试 ID。重复调用命中同一 attempt 时不重复下发。
来自过期轮次、历史、网页或工具数据的控制请求无权执行；控制意图缺失时保持暂停。

异步执行要显式区分“接收任务的回执”和“执行结果”：前者不能说做完，后者只在当前有效呈现链路投递。
可以合并过期进度消息，但不能丢掉最终事实。数据注入不自行触发任务，更不能构造一条假的用户指令。
已有 follow-up 竞态的连接重建保护、回执转写核对、uncertain_effect 与精确目标限定均保留。
如果供应商对异步结果投递的行为不满足要求，先停在该接缝，不用旧 callID、额外 TTS 或硬编码成功口播兜底。

## 6. 实现顺序与验收矩阵

用户确认本方案后，在同一主 Issue 内依次推进，不预先开多条并行写入路径：

- **A：失败表征与准入边界**。补生产接缝测试：插话导致任务丢失、busy 请求抢占旧计划、取消后结果丢失；先红再修。
- **B：唯一任务所有者与语音控制**。收拢两条任务入口，分离停声/暂停/纠正/取消；让状态查询走正式工具入口。
- **C：连接恢复、持久化和有界核查**。保留当前供应商竞态防护，验证异步结果投递；未解决的关键探针阻塞真实动作验收。
- **D：受控页面及真人验收**。只有前三部分相关检查通过，且用户安排独占验证窗口后才操作真实界面。

| 场景 | 独立 evaluator / 必需证据 | 通过条件 |
| --- | --- | --- |
| 正常多步骤 | 正式模型/工具入口 + 受控页面 `/state` 或 AX/DOM | 顺序与实际目标一致；不同标签/顺序的第二份请求也成立，不使用测试句专用计划 |
| 执行中问进度 | session 事件 + 任务快照 + 页面动作计数 | 停播；taskID 不变；不取消/重置预算；安全恢复后没有重复动作 |
| 执行中纠正 | 两个目标的独立状态 + revision/attempt 事件 | 旧目标未下发动作为零；已发生部分可追溯；新目标结果不借用旧证据 |
| 明确取消 | 执行器停止证据 + 页面动作计数 | 取消准入后零新下发；终结不复活；旧工作未停不交接占用 |
| 语音重建 | 新旧连接 generation + 重建前后任务快照 + 独立页面 | 身份/进度/纠正保留；不回填旧 callID、不复播过期结果；明确关闭不自启 |
| 效果发生、回执丢失 | 故障注入 + 页面计数 + task 状态 | 效果最多为本次已下发动作；状态未确认；恢复不重复下发 |
| 两入口竞争 | 实际 voice 与 harness 的准入链路 + 带时间的动作记录 | 重叠下发为零；被拒请求不能激活应用/停止旧计划；其他可达入口同门 |
| 迟到/重复事件 | 乱序与重复注入 + task/attempt 快照 | 不重复动作、不覆盖新版本、不复活终态；迟到真实结果仍登记 |
| 保存失败与进程重开 | 隔离目录写失败/重开测试 | 保存失败不接收执行；未结算动作重开后暂停/待核查，不自动重试 |

分层记录结果：隔离逻辑测试、生产接缝集成、真实桌面、真人麦克风四者不可互相冒充。
现有 `scripts/test-stepfun-voice-lifecycle.sh` 在临时 Swift 包中测试相关真实源文件，但**不包含完整 engine、router 和 WorkflowRunner**；
因此其全绿不足以证明新准入边界正确，实现时必须补生产接缝测试。再按受影响范围运行其他既有回归。
不从终端运行 xcodebuild，不更改签名、TCC、模型/音色默认值或隐私开关。

时延沿用 `DesktopVoiceTrace` 记录必要身份与状态，不写原始内容。
分别测：收到开口事件→本地清队；speech_stopped→首个实际可听输出；动作下发→独立验证完成。
当前开口事件来自 server VAD，不能把第一个指标写成“用户真实开口到停止出声”。
本轮未测基线；实现阶段先固定样本和场景报告 p50/p95，再确定数值门槛，禁止套用模型首包或单次最佳值。

## 7. 待验证假设、回退与本轮交付

实现目标：先消除错误抢占、错误完成与取消丢证据，再连接应用级任务和语音订阅。
硬性门槛：被拒请求零激活/零下发/不停止旧计划；每次动作有独立身份；停止不等于完成；
已下发动作的事实不能被订阅取消抹掉；旧执行未收尾不能接收新执行。相关隔离回归与全应用 typecheck 必须通过。
优化项：不新增供应商、不改变音色，不引入 Node，不改变旧数据；不以减少检查换低延迟。

最脆弱假设：当前 StepFun 会话能在不交叠旧响应的条件下接收独立任务快照并可靠回答进度/播报结果。
既有窗口数据注入只能证明已有编码路径，不能证明新增异步任务协议已被服务端接受；必须做有界探针。
其他风险：executor 内取消会提前退出回读；旧 harness 的完成语义弱于语音语义；界面 retry/skip 可能形成旁路。
上述风险都阻塞对应验收，不能以增加一个 runtime 或仅通过 coordinator 单测来掩盖。

实现初期保留旧路径作为可回退基线；若需开关则默认关闭新入口，不允许同一任务双写两套协调器。
回退前先停新任务、核查在途动作并停止执行器；保留新事实记录，不把旧入口自动绑定到未确认任务。
不迁移记忆、不增加后台研究框架、不整仓重构，不复活 Kairos 已删除的产品规划文档。

## 8. 历史现场：最初的动作身份修复与写入拦截（已被第 0 节覆盖）

最终目标已进一步确认：多个源码仓库收敛为一个产品仓库、一个应用；先沿 os 实现，旧仓库作为迁移来源保留。
日常执行与验证由主代理负责；主干、运行时、数据权威等架构变化先与用户讨论。未授权删除旧仓库或迁移私人数据。
续接核对发现上轮补丁把 completed 标记接到了“缺少 point handler”的失败分支，实际完成分支仍是 stopped。
既有隔离语音测试未编译真实 WorkflowRunner，因此不能证明该接线。本次先增加完整生产源码的无设备集成测试。

用户已确认方案，无需重复询问架构选择。接手基线仍为 `main@099279d`；继承本文件，原跟踪源码无未提交改动。

已实现的独立准备项：每次动作生成独立 attempt ID；观察 ID 继续作为观察证据，不再兼任动作 ID。
协调器回执、动作事件的 trace_id 与 executor 三条引擎调用使用同一 attempt ID。
未经过协调器的旧调用仍以观察 ID 兼容，不宣称全产品幂等或生命周期分离已经实现。
变更仅涉及 `DesktopTaskCoordinator.swift`、`DesktopTaskExecutor.swift` 及对应测试。

红绿证据：固定同一观察、执行两个明确步骤，修前只产生一个唯一动作 ID，断言失败；
修后动作 ID 唯一、观察 ID 保留，executor 接收的 attempt ID 与回执相同。
修前日志 `/tmp/tiptour-lifecycle-A-red.log`，首轮定点日志 `/tmp/tiptour-lifecycle-A-focused.log`。

新增发现：`TipTourEngine.waitForWorkflowSettlement` 仅凭 `activePlan == nil` 返回 completed；
因此 stop 清空计划可能被误读为完成。该判断与忙碌准入、在途 driver 收尾必须一起修，不能仅改口播。
本次针对 `WorkflowRunner.swift` 的同一主链路补丁连续两次被工具以
“OpenAI 无法确定请求的安全状态，已拦截此工具调用”拒绝；Git diff 确认该文件没有改动。
没有改换连接或命令通道应用被拦截补丁。已删除本轮尚未接线的 WorkflowExecutionState 草稿及其测试，
测试脚本恢复原样，避免留下孤立框架；这些草稿测试不能计为已交付能力的证据。

后续仍从 A 的准入/停止事实生产接缝继续。B（应用级唯一任务所有者）和 C（重连/持久化）未实现，
D（真实桌面/真人）未执行。没有模型请求、安装、开麦、提交、推送或用户数据变更。
最终保留实现的验证：`scripts/test-stepfun-voice-lifecycle.sh` 退出 0，71 项 XCTest + 30 项 Swift Testing 通过；
日志 `/tmp/tiptour-lifecycle-A-final-tests.log`。对 76 个实际应用源文件的 typecheck 退出 0，
日志 `/tmp/tiptour-lifecycle-A-final-typecheck.log`；存在仓库既有类别的并发/弃用 warning，未顺手修改。
`git diff --check` 通过；人工核对最终 diff，三处 executor 引擎调用均沿用本次 attempt ID，
无本轮遗留的未接线模块。跟踪文件变更为 3 个（29 行新增、6 行删除），外加继承并更新的本方案文档。
`WorkflowRunner.swift`、`TipTourEngine.swift` 和测试脚本均与 HEAD 一致，主链路补丁未写入。
上述测试证明动作身份准备项和既有隔离回归，不证明准入修复、语音持续任务或真人体验已经通过。
