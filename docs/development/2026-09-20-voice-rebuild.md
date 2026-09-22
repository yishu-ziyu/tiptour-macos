# 2026-09-20 阶跃语音重构开发日志

> **文档性质：历史证据日志（2026-09-20 记录，冻结）。**
> 本文件只保留当天的真实过程、失败与结论，不随代码演进而更新，也不得为"变绿"而改写。
> 分类标注由 2026-09-23 的文档核对工单添加，正文一字未改。当前事实见根目录 `AGENTS.md`
> 与本目录 `README.md`。

记录时间：2026-09-20 04:37 CST。
项目：`/Users/mahaoxuan/Desktop/AI 产品/os`。

## 当前交付状态

**源码修改、独立审查、隔离测试及 Xcode 构建已完成；真实麦克风连续对话尚未验收。**

新版已通过 `open …/TipTour.app --args --show-panel` 启动，启动检查时 PID 为 92309；`codesign -v` 返回成功。这仅证明启动及签名验证通过，不代表能听到回答或能控制桌面。

本轮改动仍在工作区，尚未提交或推送。记录时最近提交为 `abe5659`，不要将该提交当成本轮重构版本。Xcode 生成了本机 `xcuserdata/mahaoxuan.xcuserdatad/`，不属于产品改动，不应随开发日志一起提交。

## 起因与范围

用户实际反馈“完全不能对话”，此前以构建成功、探针收到音频数据代替产品体验验收，判断不充分。本轮优先重做阶跃语音收发、音频生命周期、管理器接入和可见错误，不是全产品功能重写；Gemini 删除、视觉双模型路由和桌面执行完整验收不在本轮完成范围。

## 修改内容

| 文件 | 修改 |
| --- | --- |
| `TipTour/Voice/StepFunRealtimeClient.swift` | 单一串行发送队列保证音频与控制消息顺序；握手错误、发送失败及时返回；接收事件有序投递并隔离旧连接 |
| `TipTour/Voice/StepFunRealtimeSession.swift` | 移除模型说话期间丢弃麦克风数据的半双工做法；启用 AVAudioEngine Voice Processing 消回声，启用失败明确报错；生成结束后等待播放队列排空；取消、迟到音频和工具结果用运行身份/轮次状态隔离 |
| `TipTour/App/CompanionManager.swift` | 纯语音不再依赖桌面控制权限；启动任务由管理器持有并取消；订阅校验会话身份；失败清理后可直接重试；状态、转写、错误分离 |
| `TipTour/UI/CompanionPanelView.swift` | 中文连接/聆听/回应状态、可见错误和转写；保留已有权限入口，缺桌面权限不再误报为完全无法对话；截图开关仅供 Gemini |
| `TipTour/UI/ProviderSetupView.swift` | 中文辅助标签及切模式会结束会话的说明 |
| `TipTour/App/TipTourApp.swift` | 支持 `--show-panel`；重新打开应用时展示面板，不自动录音 |
| `TipTourTests/StepFunRealtimeSessionLifecycleTests.swift` | 新增生命周期与迟到事件回归 |
| `scripts/test-stepfun-voice-lifecycle.sh` | 在临时 SwiftPM 包中编译真实客户端、会话和音频依赖并执行状态测试，不构建安装版 app |

## 协作与 review

两个实现代理分别处理语音底层和管理器/UI，限定文件范围避免相互覆盖；独立 reviewer 在实现后复核。主代理复跑测试并通过 Xcode 的 AppleScript `build workspace document` 发起完整构建。

review 发现并修复：

1. 打断后的迟到音频可重新激活旧响应：中断状态丢弃旧音频及完成事件，直到新响应开始；增加对应测试。
2. 启动失败留下会话对象，下一次点击被当成停止：失败回调清理对象并保留可见错误。
3. 取消与握手完成竞争可能留下 socket：过期运行身份分支显式断开连接。
4. Gemini 新启动沿用旧错误提示：启动时清理旧转写及错误。
5. 完整 Xcode 构建发现 `defer` 内 `guard … else { return }` 不合法：改为条件清理，重新构建成功。隔离语法解析未捕获此问题，不能代替完整构建。

## 验证与复现

在项目根目录运行：

```bash
cd "/Users/mahaoxuan/Desktop/AI 产品/os"
bash scripts/test-stepfun-voice-lifecycle.sh
bash scripts/test-stepfun.sh
bash scripts/test-jev.sh
```

预期分别通过 14、14、12 项，共 40 项。证据输出保存在同目录 `evidence/2026-09-20-*.log`。测试覆盖纯状态与规则，不覆盖真实扬声器回声、麦克风权限弹窗或桌面点击。

完整 app：Xcode `tiptour-macos` scheme 的 build action 返回 `succeeded`；未宣称全仓零警告。构建日志保存为 `evidence/2026-09-20-xcode-build.log`。

产物位置：

`/Users/mahaoxuan/Library/Developer/Xcode/DerivedData/tiptour-macos-gtcdcfrkrqlavldfoxxsyfksnyrq/Build/Products/Debug/TipTour.app`

验收契约：[voice-rebuild-acceptance.md](../voice-rebuild-acceptance.md)。

## 撤回之前未经充分验证的结论

- “VLM 坐标完全不可用”：先前把疑似 0–1000 归一化 xyxy 当作像素。`[442,390,622,467]` 换算到 900×560 为 `[397.8,218.4,559.8,261.5]`，接近真实按钮。应重新确认协议和评测，不能据此排除模型定位能力。
- “回声/钥匙串就是无法对话的已确认根因”：它们是代码风险或观测到的访问提示，没有足够运行证据证明是所有失败的唯一根因。
- “模型说话期间关闭麦克风修复全双工”：这实际上取消了同时听说能力，已移除。
- “response.done 等于播完”：它只标记服务端响应结束，本地播放仍可能排队。
- “稳定签名意味着授权永久不失效”：只验证过 designated requirement 相同，不能保证所有 TCC/钥匙串授权在所有更新中保留。
- “只能从终端构建”：Xcode 自带 AppleScript build 接口已实际验证可用；从哪个入口构建并不决定 TCC 是否保留，签名、路径和系统策略才相关。

## 剩余验收与交接

- 真机连续三轮中文对话；至少一轮扬声器、一轮耳机，检查 Voice Processing 实际效果。
- 插话、停止、连接中取消、失败后重试，检查没有旧回复复活或后台麦克风继续上传。
- 验证实际音频格式与服务端 VAD 话轮结束，记录时间点；不要再从模拟音频结果推断真实麦克风体验。
- 权限或钥匙串被拒时错误可见，可恢复，不静默退回“就绪”。
- 桌面点击仍须单独验收：陈旧/歧义目标、取消与实际执行互斥等不能由本轮语音状态测试证明。
- 不将密钥、用户桌面截图或语音内容写入日志或提交。
