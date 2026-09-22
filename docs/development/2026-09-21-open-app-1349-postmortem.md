# 13:49 open_app 未下发：溯源、复盘与修复契约

> **文档性质：历史证据日志（2026-09-21 记录，冻结）。**
> 本文件只保留当天的真实过程、失败与结论，不随代码演进而更新，也不得为"变绿"而改写。
> 其中的本机路径、源码行号与测试计数只对当时有效。分类标注由 2026-09-23 的文档核对工单
> 添加，正文一字未改。当前事实见根目录 `AGENTS.md` 与本目录 `README.md`。

调查日期：2026-09-21，日志时间为本机 UTC+8。项目 `os`，HEAD `6dbba3a`，含既有未提交改动。
本轮只读运行状态、日志、源码并执行名称解析小样；未启动目标应用，未改生产源码、权限、语音配置或原始诊断开关。

## 结论与证据边界

本轮事件不是“JEV 选错按钮后点击失败”。生产路由已经拿到 `open_app`，经过整屏观察后返回
`not_sent`，没有实际下发动作。原有持久化 Pipeline 日志没有出现这轮的工作流提交或应用启动记录；
结合代码中的返回路径，证据指向新增 `DesktopTaskExecutor` 的前置检查，而非启动后的结果验证。

已在同一台 Mac 上复现一个确定缺陷：适配层的名称预检查找得到 WeChat、Calculator、Google Chrome，
找不到“微信”“计算器”“谷歌浏览器”。这些应用实际存在。名称值前后带空格也不能通过。
这证明中文名称映射缺失足以阻断合法请求，但不证明 13:49 那轮的实际参数就是其中某个中文名。

13:49 的原话、application 参数及具体拒绝 detail 未写入默认日志。stdout/stderr 指向 `/dev/null`，
`~/Library/Application Support/TipTour/VoiceDiagnostics` 不存在。不能恢复没有记录过的字段；
不能把“应用未找到”或“窗口变化”中的任何一个写成该轮已证实的唯一触发分支。

## 1. 现场时间线

进程：PID `70053`；构建产物时间：`2026-09-21 01:57:19`。
用户轮次：`8E103023-BE72-49BD-B00A-E6B23F86407D`。
任务：`28573700-B7D1-4484-BB6E-3E0F581707BC`。
观察/执行追踪：`40F01E0A-E6CC-43E1-B949-72A884DF3AAD`。

| 本机时间 | 原始事件 | 可作出的判断 |
| --- | --- | --- |
| 13:49:21.883 | user_turn_started | 用户轮次开始 |
| 13:49:24.582 | input_transcript_final，correlation=item_id | 收到最终转写事件；内容未记录 |
| 13:49:25.281 | tool_requested，act_on_screen，call_0_1681 | 模型确实调用工具 |
| 13:49:26.794 | scene_observed，target_count=95 | 工具请求到观察完成约 1513 ms |
| 13:49:26.795 | action_attempt_started，action=open_app | 尝试进入应用打开执行路径；不是送达确认 |
| 13:49:26.839 | action_evidence，not_sent，verified=false | 44 ms 内返回未下发 |
| 13:49:26.839 | task_finished，paused，new_action_count=0 | 无实际新动作 |
| 13:49:26.877 | tool_result_submitted、speech_scheduled | 回执交还会话并排入 TTS |
| 13:49:36.749 | playback_drain_finished，0 buffers、tts_pending=false | 播放流程排空；不证明用户听清 |

`current_action_count=1` 数的是一次尝试记录，`new_action_count=0` 才对应实际动作历史；两者不矛盾，
但当前命名容易误导。后续日志应明确区分 attempted / sent / verified。

第二份来源：`~/Library/Application Support/TipTour/logs/tiptour-2026-09-21.jsonl`。
对 `13:49:24–13:49:28` 的完整时间过滤只返回三个 Pipeline 事件：

- 13:49:25.252：engine/observe，active_bundle=com.openai.codex，active_plan=none。
- 13:49:26.740：engine/targets，95 个候选，reason=voice action observation。
- 13:49:26.762：engine/observe，仍是 com.openai.codex，active_plan=none。

因此 95 个候选是当时前台应用的界面控件，不是“95 个已安装应用”。
此处显示名为 ChatGPT，bundle ID 为 com.openai.codex，以标识为准，不据显示名推断产品版本。

工具拒绝后出现的 `-999` 分别在 13:49:28.817、13:49:30.921，时间晚于未下发判定，
不能将它们倒置为这轮拒绝的原因。当前 TTS 代码既允许任务取消，也会在 SSE 完成标记处退出读取；
单个取消错误不能独自证明用户打断或供应商故障。

## 2. 可重复的名称解析缺陷

运行了与 `DesktopTaskExecutor.swift:47–55` 相同的只读预检查：

```swift
let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: query)
    ?? NSWorkspace.shared.fullPath(forApplication: query).map { URL(fileURLWithPath: $0) }
let identifier = url.flatMap { Bundle(url: $0)?.bundleIdentifier }
```

小样只读取应用注册信息与 Bundle 元数据，没有调用 launch/open/activate。

| application 输入 | 当前预检查结果 |
| --- | --- |
| 微信 | NOT_FOUND |
| WeChat | /Applications/WeChat.app，com.tencent.xinWeChat |
| Weixin | NOT_FOUND |
| 微信应用 | NOT_FOUND |
| 计算器 | NOT_FOUND |
| Calculator | /System/Applications/Calculator.app，com.apple.calculator |
| Safari | 能解析为 com.apple.Safari |
| Safari浏览器 | NOT_FOUND |
| 谷歌浏览器 | NOT_FOUND |
| Google Chrome | /Applications/Google Chrome.app，com.google.Chrome |
| 前后各一个空格的 WeChat | NOT_FOUND |

中文用户说“打开微信”是正常输入。协议允许应用名称，程序却没有将自然叫法映射为已安装应用身份。
不能要求模型或用户必须猜出磁盘英文名来掩盖接口缺陷。`fullPath` 被弃用本身并不证明调用失败；
本次结论来自上表实测，而非弃用警告。

## 3. 二次开发引入了什么

### 不必要的屏幕前置条件

`DesktopTaskCoordinator.swift:151` 在检查 `step.action.needsTarget`（157 行）之前无条件 observe。
所以 `open_app.needsTarget == false` 只跳过候选选择，没有跳过截图、OCR/YOLO 和屏幕有效性检查。
路由 `StepFunRealtimeToolRouter.swift:138–170` 要求新截图、相同前台上下文和有效观察版本。
执行器 `DesktopTaskExecutor.swift:27–38` 再次要求 app/window/contentVersion 不变，并读一次 AX。
这些条件适用于点特定屏幕控件，却不是明确启动一个已安装应用的必要条件。

### 两套名称解析串联

上游基线 `5258246` 已通过 `WorkflowRunner → ActionExecutor → CuaActionDriver → AppLauncher.launch`
执行打开应用。本机 CUA 依赖版本为 `6c31427c763fcaf7277e1636772b064a38af9862`；
其 `Apps/AppLauncher.swift:221–313` 有文件名、bundle ID、运行应用名称和安装目录元数据的解析。
新增执行适配器在这之前另做 NSWorkspace 名称预检查；预检查返回 nil，既有启动器就收不到请求。
不能据此声称旧启动器对所有中文叫法一定成功，但两套解析已构成不一致的接受边界。

### 测试遗漏了真正失败的路径

`TipTourTests/StepFunTests.swift:131–136` 的“打开计算器”测试直接写入英文 `application: Calculator`，
然后只检查解码出的动作。`DesktopControlContractTests.swift:56–61` 检查参数是否合法。
隔离 lifecycle 脚本没有编译生产 `DesktopTaskExecutor` 和 `StepFunRealtimeToolRouter`。
此前实际桌面验收证明的是受控网页按钮及显式结果条件，不是中文应用启动。
语音探针当时又在 Keychain 处阻塞，尚未形成同构建、同输入的完整成功基线。

因此“参数可解码、纯状态测试通过、按钮可以点击”不能推出“中文语音可以打开应用”。
这属于本轮实现与验收设计责任，不能归咎于用户需求、JEV 性能或笼统的二次开发复杂度。

### 可诊断性不够

具体 detail 被归入原始诊断隐私字段；默认状态只有 not_sent。隐去原话不要求同时隐去
`app_not_found`、`context_changed`、`automation_disabled` 等不含内容的原因码。
现在恰好缺少定位历史拒绝分支所需的这层原因，补全日志应先于再次真人试错。

## 4. 已实施修复

未引入新模型、第二套运行时或新的总协调器。保留现有取消、回执、权限与真实目标保护；
已删去 open_app 不需要的屏幕依赖，并复用共享启动路径。

1. 在观察之前按动作区分准备工作：open_app 使用 context-only observation；click 准备新鲜控件；type 检查指定字段焦点。
   打开应用保留用户授权、任务世代/取消检查，不依赖截图开关、OCR 候选数或来源窗口内容版本。
2. 新增 `DesktopApplicationResolver`：规范化输入，从顶层已安装 `.app`、运行应用及 Spotlight `kMDItemDisplayName`
   读取名称并合并到 bundle ID；过滤嵌套 helper app。支持中文本地化名称及少量明确品牌别名。
   名称必须落到已安装应用的 bundle ID；多个匹配才澄清，无匹配才 app_not_found。
   后续执行与验证携带同一个 bundle ID，不在适配器和驱动中重新解释同一字符串。
3. 通过既有 WorkflowRunner/ActionExecutor 打开或激活应用；启动器成功后确认目标 bundle 的进程真实存在。
   前台身份仍用于后续步骤的 pinned-app 保护，但不把测试宿主随后抢回焦点误判成“应用没有打开”。
4. `action_evidence` 默认公开 `failure_stage`、`reason_code`、delivery 与 verified，不记录应用原话；
   用户原话、窗口文字和原始参数保持默认不记录。无需先开启整段原始语音诊断才能修名称缺陷。
5. 启动期间 `openApp` 不再被无关的应用激活通知取消；其他点击/输入步骤仍保持原来的跨应用暂停保护。
   `open_app` 成功后的验证不再额外刷新 OCR/YOLO。

### 修复后的证据

- `DesktopControlContractTests` 19 项通过，其中新增：open_app 不调用 screen observer；中文/英文应用名绑定同一 bundle；
  品牌别名只有已安装时才有效；真实歧义不任意选第一个。
- 本机只读目录解析：`微信` / `微信应用` / `WeChat` → `com.tencent.xinWeChat`；
  `计算器` → `com.apple.calculator`；`谷歌浏览器` → `com.google.Chrome`。
- `DesktopControlContractTests` 最终 19 项通过；本地感知/Workflow pause policy 14 项通过；
  全应用 typecheck 退出 0；最终 Xcode Build action `87153-11` succeeded。
- 真实 `desktop-task-probe` 使用 `application="计算器"`：`ActionExecutor` 实际打开
  `com.apple.calculator`，目标进程存在。一次复测因测试宿主随后抢回前台而被旧验证器误判为未确认；
  验证口径已改为“启动器成功 + 目标 bundle 进程存在”。若任务还要继续操作该应用，下一步仍通过
  pinned app/window 约束保护，不会因为“已启动”就向错误前台发送输入。VoiceTask 动作前记录的是
  `mode=context_only,target_count=0`，不再为 open_app 构造 95 个屏幕候选。
- 第一次真实复测还暴露 WorkflowRunner 会被中途 `com.cmuxterm.app` 激活取消；该失败被保留，
  随后增加 openApp 原子切换策略并复测通过，没有把失败覆盖成成功。
- 最终真实复测仍使用中文 `application="计算器"`：回执 `completed`，`delivery=sent`、`verified=true`，
  `ActionExecutor` 记录打开 `com.apple.calculator`，最终任务 app 绑定为 `com.apple.calculator`。
  最终探针日志中只有探针自身为兼容旧验收页做的前置 NativeDetector 扫描；`open_app` 的生产协调器
  记录 `context_only,target_count=0`，成功后也不再触发 OCR/YOLO 刷新。

## 5. 验收条件

| 场景 | 通过条件 |
| --- | --- |
| 中文名、英文名、已安装 bundle ID | 指向同一实际应用；不能依赖手工把中文换成英文参数 |
| 目标未运行、没有可见图标 | 启动并确认正确 bundle 进程存在；后续输入再验证前台身份 |
| 当前窗口变化或无截图 | open_app 不被无关视觉条件拦截 |
| 明确用户停止/新任务取代 | 取消检查仍有效；不产生迟到启动 |
| 不存在或真实歧义的应用 | 零错误启动，原因码明确 |
| 打开应用快速路径 | OCR/YOLO、远程视觉、JEV 调用次数均为 0 |
| 真实中文语音 | 生产转写/工具参数/解析身份/启动结果关联；独立 OS 读回与播报一致 |
| 基础回归 | 原有精确点击、纠正、停止、当前/历史回执隔离仍成立 |

真实中文语音（麦克风→Realtime 转写→工具参数→上述启动路径→TTS）仍需用户侧最终听感/拾音验收；
这里的成功证据是生产桌面任务路由，不把它夸大成真人语音端到端已经通过。

## 21:47 豆包复盘：进程存在不等于用户看见窗口

真人语音要求打开豆包时，Pipeline 记录 `open_application` 从 Google Chrome 发起，并在约 0.5 秒后把
`com.bot.pc.doubao` 标记为 frontmost；十几秒后的 observe 仍把 active/frontmost bundle 记录成豆包。
但用户肉眼没有看到豆包窗口。随后检查当前运行态确认：`/Applications/Doubao.app` 主进程及多个 nested helper
进程都存在，但 CGWindowList 的 on-screen layer-0 窗口数为 0。

这证明上一版“启动器成功 + 目标 bundle 进程存在”仍然过宽。现在 `open_app` 的完成条件改为：

1. 目标安装包（含其 Contents 内 helper bundle）有真实 on-screen layer-0 窗口；
2. 当前 foreground application 属于这个安装包；
3. background wrapper 已运行但无窗口时，额外做一次有界 LaunchServices reopen；仍无可见窗口则回执保持未验证，明确不能说已打开。

真实复测从“豆包进程存在、visible window=0”开始。新路径发起“打开豆包”后，回执 `completed`、
`delivery=sent`、`verified=true`；独立 CGWindowList 读回得到 1 个豆包 layer-0 窗口（1200×1069），
且 frontmost bundle 为 `com.bot.pc.doubao`。因此这次成功是“用户可见窗口”级别，不再只是进程级别。

同一事故还暴露 `describe_screen` 的错误取景：本地 perception 和远程视觉都曾以“光标所在 display”作为图像来源。
当目标 app 没有可见窗口时，整屏 OCR/YOLO 还能读取桌面/其他应用；远程视觉则会诚实描述那张错误截图，于是出现
“active app=豆包，但看到桌面壁纸”的自相矛盾结果。现已改为：无目标窗口时禁止 whole-display visual candidates；
screen question 先检查目标 app 的可见窗口，并用 ScreenCaptureKit `desktopIndependentWindow` 直接截该窗口。
“你看到了吗”这类 yes/no 问题完全本地回答；普通文字/控件问题优先 AX/OCR 本地快答；只有图片、颜色、图表等真正
视觉语义才进入远程 Vision。
对于参考 jev-use：已核对其 README 的 Apple Speech、按住说话后松开执行、独立 open 动作和 AX 循环描述；
尚未在这台机器上对中文应用名称做参考项目 A/B。不能用演示或 README 保证其在相同条件下必然成功。
