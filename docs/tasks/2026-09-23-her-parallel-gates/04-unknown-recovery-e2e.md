# 工单 04：用真实故障路径验收 delivery unknown 与旧日志恢复

## 目标

补上当前最重要的 E2E 缺口：输入已经打到页面，但 Driver 回执丢失时，Her 必须记录 unknown、停止、不得重复副作用。另用真实恢复路径证明 v1 journal 不会被误判完成。

## 独占文件

- `TipTour/Actions/ActionExecutor.swift`
- `TipTour/Workflow/WorkflowRunner.swift`
- `TipTour/Voice/DesktopTaskJournal.swift`
- `TipTour/Voice/VoiceRouteProbe.swift`
- 新增 DEBUG-only fault/recovery probe 文件

不得修改 task contract、Coordinator、StepFun tool schema 或 acceptance runner。

## 实现约束

- 故障注入只能存在于 DEBUG 探针，Release 不可见。
- 必须经过正式 Action Driver；不能用假的 executor 直接返回 unknown。
- 注入点在“真实副作用已经发送后、确认结果返回前”，只注入一次。
- 不增加通用重试开关，不改变生产默认行为。

## E2E 场景 U：回执丢失

用户路径：

1. 打开本地 fixture。
2. 通过生产语音/工具路由点击右侧设置。
3. Driver 实际完成点击后，DEBUG fault 丢弃本次成功确认，使产品看到 delivery unknown。
4. 在同一任务中请求继续。

必须观察到：

- `/state.selected == "right-setting"`。
- `/state.clicks == 1`。
- 首轮 receipt `delivery=unknown`、`status=uncertain_effect`。
- 继续后 `/state.clicks` 仍为 1。
- 同一 attempt 不被重发，不改点左侧按钮。
- 最终语言明确“不确定，已停下”，不能说没操作，也不能说完成。

## E2E 场景 R：v1 journal 恢复

通过 DEBUG recovery probe 使用临时 Application Support 目录写入真实 v1 JSON，然后启动实际恢复流程。

必须观察到：

- 旧 `verified=false` / completed 快照恢复为 `recovery_required`。
- 没有桌面动作发生。
- 普通 resume 被拒绝。
- 用户明确 cancel 后任务终结，旧日志不被自动重放。
- 不覆盖不可读原文件。

## 验收标准

- U、R 都通过真实文件/真实 Driver 路径。
- Release 构建不含可触发 fault 的用户入口。
- E2E 证据包含 before/after `/state`、attempt ID、journal bytes 摘要和回执。
- 现有隔离测试继续通过，但不能替代以上 E2E。
