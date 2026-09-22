# 工单 02：让任务进度语言服从双层事实

## 用户问题

当前 `completedStepCount` 同时包含：动作已送达、系统已验证、用户已确认。Her 却会统一说：

> 已确认 1/2 步。

这把 delivery-confirmed 错说成 system-verified。

## 目标行为

进度播报只陈述可以证明的事实：

- 混合证据或仅送达：`任务尚未完成，已处理 1/2 步。`
- 全部已处理步骤均为系统验证时，才允许使用“已确认”。
- 用户确认必须说“你已确认”，不能伪装成 Her 独立验证。

## 独占文件

- `TipTour/Voice/DesktopTaskContract.swift`
- `TipTour/UI/CompanionPanelView.swift`
- `TipTour/Voice/VoiceTaskContinuityProbe.swift`

不得修改 Coordinator 推进规则、StepFun tool contract、driver 或 journal。

## E2E 验收

扩展现有 continuity probe，使用真实 StepFun 和生产 session/router，但使用无副作用 fixture executor，跑以下用户旅程：

1. 开始两步任务。
2. 第一步仅 `delivery_confirmed` 后，用户问“做到哪里了？”
3. Her 返回进度。
4. 用户明确取消。

必须满足：

- 进度文本包含“已处理 1/2 步”或语义完全等价文本。
- 不得包含“已确认 1/2 步”。
- 任务 ID 不变，progress turn 与 cancel turn 不同。
- 询问进度不重复第一步，也不提前执行第二步。
- 取消后状态为 cancelled。

再跑一条全部已系统验证的两步 fixture：只有这条路径允许“已确认 2/2 步”。

## 完成定义

两条真实 provider E2E 都通过；UI 面板和语音使用同一证据语义。不得新增一个只供测试调用的摘要函数。
