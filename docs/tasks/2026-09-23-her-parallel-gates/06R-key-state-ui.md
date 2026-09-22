# 06R：保存事实、可读状态与界面恢复真正闭环

优先级 P1。解决“保存过却被说没保存”，同时不得反向变成“只是查到条目就说可使用”。

## 静态发现与边界

现有 06 证据自述签名 App/UI 尚未执行，本次不把隔离 Security 测试判为 UI 通过。
`KeychainItemState.available` 同时用于存在性成功与真正读取成功；`isUsable` 无法区分。
`itemExists` 使用 `self != .absent`，会将 unavailable/unknown 当成确定存在。
`applySelectedModeKeyState` 只要 itemExists 就 clearResolvedKeyFailure，可能清除仍存在的拒读错误；该清理函数又先要求 publishedVoiceKeyFailure，单独 JEV 的错误没有独立清理路径。
这些是当前源码可达问题，尚需按下表做签名 App 的实际 UI 复现，不能宣称都已在用户机器动态复现。

## 独占范围

`KeychainStore.swift`、`ProviderSetupView.swift`、`CompanionManager.swift`、`CompanionPanelView.swift`、`GeminiLiveSession.swift`。
仅后者的凭据读取/错误语义可以改，不恢复 Gemini 产品能力。不得改 01R 工具参数或 03R 总运行器。

## 决策与最小实现

1. 存在性查询不解密、不弹窗；成功只能证明“已保存”。实际取到非空、可解码值才证明“本进程可使用”。不凭“没有错误日志”证明可读。
2. 未知状态保留 unknown，不能表示条目存在或不存在。只有明确 itemNotFound 才提示保存；只知道拒读时说明“无法读取”，不要凭空断言从未保存。
3. 已保存可允许进入权限配置。就绪展示必须兼容拒读/未检查态；供应商启动前实际读取失败必阻断，不能用 hasSelectedModeKey 布尔值越过。
4. 保存成功仅清理本 provider 已被新证据解决的错误。仍拒读时保留拒读错误；presence 刷新不能冒充恢复。网络、麦克风、其他 provider 错误不被清除。
5. JEV 文本与 StepFun 语音错误各自闭环，不能要求先出现语音错误才清理 JEV 错误；Gemini 复用同一原因映射，不另做字串表。
6. 尽量复用现有状态类型与入口，不增加第二个凭据管理器。保留 service 级缓存隔离，DEBUG 故障不可进入 Release。

## 独立 E2E 门禁

在签名 DEBUG Her 的专用验收进程和隔离 service 中操作正常设置界面。使用仅供测试的非生产值；真实用户 API key 不读取输出、不覆盖、不复制。测试值不得发往真实供应商。登录、系统授权由用户本人完成。

| 用户路径 | 独立通过条件 |
| --- | --- |
| 未保存→启动被拒→设置保存→关设置→再开 | UI 即时显示已保存，旧“未保存”错误消失，不重启；独立条目检查相符 |
| 已保存→注入拒读→打开/关闭设置刷新 | 仍显示正确拒读原因；不显示“未保存”，也不变成“可使用”；供应商零调用 |
| 保持拒读→再次保存 | 写入成功不得隐藏仍真实存在的读取限制 |
| 移除拒读→实际读取成功→重试 | 只清理此 key 已解决错误，启动前取值成功；dummy 测试在网络边界停止，不泄露测试值 |
| 只触发 JEV 文本错误后修复 | 文本错误独立消失，无需先触发语音错误 |
| 其他网络/麦克风错误存在时保存 | 其他错误保留 |
| 未知/无法解析/冷启动仅能查到条目 | UI 分别报告未知、损坏或仅已保存；不将其等同 available |
| Xcode 重新构建后正常重启 | 正式 App 身份不变；隔离 item 仍通过真实读取验证，不依赖旧进程缓存 |

回执记载真实 OSStatus 与注入来源。使用 errSecInteractionNotAllowed 常量注入拒读是故障注入，不得包装成“系统自然拒读已实测”。
总结果至少保存 UI 文本或可访问性树的前后变化、provider/mode、状态来源、OSStatus、进程/构建、清理记录，不保存 SecureField 值。
缺签名 App/UI 证据为 NOT_RUN/BLOCKED，不以五个状态函数通过代替完成。
