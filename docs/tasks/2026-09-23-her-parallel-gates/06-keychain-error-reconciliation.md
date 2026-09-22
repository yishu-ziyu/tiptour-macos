# 工单 06：保存密钥后立即消除错误状态并区分读取失败

## 依赖

工单 01 合并后再开始，因为两者都可能修改 `CompanionManager.swift`。

## 用户问题

用户已经在 Her 设置中保存 StepFun Key，但旧常驻进程仍显示：

> 未读到阶跃密钥：请在「设置 → 模型」保存密钥后重试。

该提示把“没有 key”“钥匙串读取失败”“旧错误未清除”混成一种状态。

## 独占文件

- `TipTour/Utilities/KeychainStore.swift`
- `TipTour/UI/ProviderSetupView.swift`
- `TipTour/App/CompanionManager.swift`

## 目标行为

- 保存成功后立即刷新 `hasSelectedModeKey` 并清除对应的 stale missing-key 错误。
- Key 不存在、读取被系统拒绝、解码失败分别有不同状态和文案。
- 不在 UI 显示 secret，也不为了刷新再次反复解密。
- 重建后 Key 仍可读，不能要求用户重复保存。

## 人机 E2E 验收

使用独立 Debug acceptance service/key name，禁止覆盖用户真实 `stepfunAPIKey`：

1. 启动 Her，触发“缺少密钥”状态。
2. 在真实设置 UI 保存 acceptance key。
3. 不重启 App，错误提示立即消失，状态变为已保存。
4. 关闭并重新打开设置，仍显示已保存。
5. Xcode 原生 Build 后重启 Her，仍能读取。
6. 模拟拒绝读取时，提示为“钥匙串读取失败”，不能说“请保存密钥”。

验收必须有 UI 截图或录屏、统一日志和 Keychain metadata；不得输出 key 内容。
