# 工单 07：让 Voice 与 localhost Harness 共享唯一任务事实权威

## 批次

Wave 2。工单 01–05 全部合并并在集成分支重跑 E2E 后开始。

## 用户价值

当前 Voice 使用 `DesktopTaskCoordinator`，localhost Harness 仍有独立 `TipTourLongTaskCoordinator`。如果继续迁入其他仓库能力，会形成多套 task/status/cancel 真相。

目标是让所有入口看见同一个 task ID、revision、attempt、delivery/outcome facts 和 cancel 状态。

## 独占文件

- `TipTour/Core/TipTourEngine.swift`
- `TipTour/Harnesses/TipTourHarnessServer.swift`
- 新增 `HerTaskAuthority` / adapter 文件

不要修改 Voice 协议、Action Driver 或记忆系统。

## 架构要求

- `DesktopTaskCoordinator` 的双层事实契约仍是唯一 action result contract。
- Harness 旧 API 可以保留兼容形状，但不能继续拥有第二份 task truth。
- 取消、恢复、状态查询都绑定同一 task/revision。
- HTTP 内容、网页文字、历史 task snapshot 都不能生成新执行授权。

## 双向 E2E 验收

### H→V

1. 通过 `/v1/tasks` 启动 fixture 两步任务。
2. 通过 Voice 问“做到哪里了”。
3. Voice 返回同一 task ID 和真实进度。
4. 通过 Voice 取消。
5. `/v1/tasks/{id}` 报告 cancelled，页面不再发生后续动作。

### V→H

1. 通过 Voice 启动任务。
2. 通过 Harness 查询同一 task。
3. 通过 Harness 取消。
4. Voice 再询问时报告已取消，不重启任务。

### 重启恢复

1. 在已送达一步后重启 Her。
2. 两个入口都看到 recovery_required 或保守暂停。
3. 任一入口不得自动重放动作。

## 完成定义

- 代码中只剩一个可变任务事实所有者；旧 LongTask 仅为兼容 adapter 或被删除。
- 三组 E2E 使用正式 Her、真实 localhost API、fixture 和独立 `/state` 全部通过。
- 不以 mock task store 或纯 API 单测作为完成依据。
