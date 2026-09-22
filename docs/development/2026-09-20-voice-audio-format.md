# 语音启动与重复打断排查

> **文档性质：历史证据日志（2026-09-20 记录，冻结）。**
> 本文件只保留当天的真实过程、失败与结论，不随代码演进而更新，也不得为"变绿"而改写。
> 分类标注由 2026-09-23 的文档核对工单添加，正文一字未改。当前事实见根目录 `AGENTS.md`
> 与本目录 `README.md`。

分支：`fix/voice-player-format`。本记录不等于真实对话验收通过。

## 实际故障与修复

- 用户反馈开始后一直转圈、说话无回应。Xcode 日志显示 WebSocket 和 session ready 成功，但 `GeminiLiveAudioPlayer.attach` 在连接播放器时抛出 AVFAudio `-10868` 异常，尚未启动麦克风。
- 新增直接连接真实 AVAudioEngine 的回归测试，旧代码复现相同异常并以 signal 6 退出。播放器改用 Float32 格式，收到的 24kHz 单声道 PCM16 按小端解码、归一化后再排队播放；两种 provider 仍共用原播放器。
- 第一版修复后，用户确认有声音，但反复打断或重复。运行时输入格式为 7 通道，原转换器平均所有通道。StepFun 改为启用 Voice Processing 后明确请求单声道，并使输出节点输入格式与收音格式一致。保留全双工，不在模型说话时关闭麦克风。

## 已验证

- `scripts/test-stepfun-voice-lifecycle.sh`：20 项通过，包括真实音频图连接、PCM16 转换、取消队列迟到回调、视觉请求格式与异常回复，以及原有 14 项话轮测试。
- Xcode 的 `tiptour-macos` scheme / My Mac 构建并运行修复版。
- 实际日志确认 Float32 播放器连接成功；最新版本输入、输出均为单声道 24000Hz，Voice Processing 未被 bypass；界面收到回复文本。但用户在保持安静时仍观察到自行打断，不能据此认定回声已消除。
- `git diff --check` 通过。

## 音色核对

- 用户要求查找 By-Your-Side 已配置的音色。该项目 `agent/src/voice-session.ts:16` 的正式配置为 `voice-tone-T3kZb9MwL2`，流式 TTS 实验也使用相同 ID。
- TipTour 的 `StepFunConfiguration.realtimeVoice` 已改用该 ID，并通过 Xcode 构建运行。未改动 By-Your-Side。
- 实际 `session.updated` 返回 `requestedVoice=voice-tone-T3kZb9MwL2, effectiveVoice=voice-tone-T3kZb9MwL2`。用户仍听到音色变化，因此“服务端接受配置”不等于音色听感稳定。官方中文 Realtime 文档支持自定义音色，但未单独说明 3-preview 的克隆一致性保证。
- 用户随后确认“现在用 mac 的麦克风也不会自行打断了”。同次日志的两轮响应在 idle 状态接收下一次语音，未见播放期间插话。保留当前 24kHz 单声道收音配置；不据此推断所有环境均通过。

## 屏幕读取与播放完成

- 旧 `describe_screen` 仅返回本地控件标签；项目中的 StepFun 视觉客户端未接入语音路径。现在工具通过共享引擎获取截图，遵守截图开关，再调用 `step-3.7-flash` 返回与用户问题有关的视觉描述。视觉描述不能成为坐标或点击依据，点击继续使用本地编号及 JEV。
- 原视觉描述提示要求自然文本，但请求启用了 JSON Mode；现在明确请求并解析 `description` 字段。保留截图原来的 JPEG/PNG data URL，测试覆盖格式传递与缺失字段。
- Apple SDK 明确默认 `scheduleBuffer` 完成回调相当于 DataConsumed，可能早于开始播放。改用 DataPlayedBack；清空或拆卸时递增队列代数，旧回调不能减少新回答的待播数。取消播放等待后及时退出，避免被取消的 sleep 在主线程空转。
- 新版经 Xcode 构建并运行。真实屏幕问答、主观音色一致性仍待用户测试，不能由 URLProtocol 固定回复或构建成功替代。
- 运行中的引擎 `/v1/visual-context` 实际返回 `screenshotAllowed=true, screenshotIncluded=true`，JPEG 为 1710×1112，证明当前截图路径可用；尚不能证明视觉 API 和语音续轮完成。
- `scripts/test-stepfun.sh` 14 项、`scripts/test-jev.sh` 12 项通过，保留原编号动作规则。

## 编码工具

- Codex 全局 MCP 配置已加入本机 `serena-mcp-stdio` 与 `codegraph-mcp-stdio` 启动器，未修改原有 MCP 条目。
- 已通过真实 MCP 握手查询本仓库：Serena 找到 `TipTourEngine/visualContext`，CodeGraph 找到 `StepFunRealtimeToolRouter.describeScreen`。Serena 使用 Swift 语言服务，项目配置位于 `.serena/project.yml`。本会话通过本机 MCP 客户端调用；新配置不代表当前会话的原生工具列表已热加载。
- 初次 SourceKit 缺少 Xcode 编译上下文，导致跨文件查询为空及 Cannot find type 误报。安装 Homebrew `xcode-build-server` 1.3.0 后，使用已核实的 DerivedData 路径通过 `config --build_root ... -workspace ... -scheme tiptour-macos` 生成本机 `buildServer.json`；已先读其实现，确认这个参数分支不调用 xcodebuild。该文件包含本机路径，已加入 gitignore。
- 补齐后 Serena 在 `StepFunRealtimeToolRouter.swift` 返回零错误，并正确查到 `StepFunVisionClient.describeScreen` 在路由器中的跨文件引用。使用 [xcode-build-server 的 Xcode 日志集成](https://github.com/SolaWing/xcode-build-server#bind-to-xcode)；后续只需在 Xcode 构建刷新日志。

## 待验收

- 扬声器连续三轮完整回答，不自行打断或重复；停止后结束收音。
- 主动插话能取消旧回答；重新开始可正常对话。
- 耳机路径尚未验证。系统 Voice Processing 仍有初始化警告，不能由 enabled 标志推断消回声效果。

## 开发入口

用 Xcode 打开仓库内 `tiptour-macos.xcodeproj`，选择 `tiptour-macos` / My Mac 后 Run。运行前结束该 scheme 的旧实例，避免测试旧应用。构建成功只能证明可编译，仍需核对控制台的收音启动与用户实际听到的结果。

依据：本机 SDK `AVAudioIONode.h` 要求 Voice Processing 的输入节点输出格式与输出节点输入格式相同。Apple 的 [AVAudioEngine 语音处理介绍](https://developer.apple.com/videos/play/wwdc2019/510/) 说明输入、输出共同参与消回声。
