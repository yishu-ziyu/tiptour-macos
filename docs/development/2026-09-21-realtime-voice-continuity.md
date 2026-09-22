# Realtime 音色连续性与交互延迟

> **文档性质：历史证据日志（2026-09-21 记录，冻结）。**
> 本文件只保留当天的真实过程、失败与结论，不随代码演进而更新，也不得为"变绿"而改写。
> 分类标注由 2026-09-23 的文档核对工单添加，正文一字未改。当前事实见根目录 `AGENTS.md`
> 与本目录 `README.md`。

日期：2026-09-21。问题来自用户 21:25–21:26 的真实 StepFun 会话：音色听起来跳变，工具轮缺少连续实时感。

## 现场证据

VoiceTask 默认日志显示：

- 21:25:50.555 最终转写，21:25:50.864 普通回复首音频，间隔约 309ms。
- 21:26:06.287 `act_on_screen` tool call 已到；21:26:06.570 第一段 Realtime 音频才开始。
- 21:26:07.233 动作验证成功；07.237 请求精确回执；07.639 回执音频被拒绝。
- 21:26:08.693 前一段播放才排空；08.903 又开始一段普通 Realtime 音频。

因此普通对话的模型首包并不是主要瓶颈。工具轮出现了多个相邻 response，用户听到的是多段独立语音生成，
同时工具结果和原 response 生命周期发生重叠。

## 根因

`StepFunTurnLifecycle.recordResponseCreated()` 过去只负责从 interrupted 回到 idle，没有把“response 已经在生成”
记录下来。StepFun 实际可能先发 function call、后发第一个 audio delta。于是 tool call 到达时 phase 仍是 idle，
客户端误判为“原 response 已经播放结束”，立即提交工具结果并创建第二个 response。

随后 `expectedSpokenReceipt` 已经属于第二个 response，但第一个 response 的 done/transcript 先到，旧语音被误当
作回执验证并拒绝；真正的回执 response 再到时 expectation 已清空，于是又按普通语音播放。一次动作因此形成
“工具前语音 → 被错配的回执 → 第三段语音”的链路。

另外，session.update 已经固定 voice，但此前每次 response.create 仍重复传 voice。官方 Realtime 语义允许 session
级 voice 持续控制后续响应；会话出音后 voice 也不应再改变，因此 response-level voice override 没有必要。

## 已实施

1. `response.created` 立即把 lifecycle 标记为 `awaitingResponseDone`。tool call 在首个 audio delta 前到达也不会提前开第二个 response。
2. 一旦当前 response 出现真实 tool call，立即清掉已经排队的工具前语音，并抑制该 response 后续 audio/transcript。
   工具轮只允许最终“已验证回执”成为可听语音。
3. `response.create` 不再重复传 voice；voice 只在 session.update 固定一次。保留 text+audio modalities。
4. system instruction 明确禁止模仿、性别/年龄/角色声线切换；情绪只允许轻微调整语速与停顿。
5. 新增 `input_audio_buffer.speech_stopped` 观测，首音频日志记录 `ms_since_speech_stopped` 和
   `ms_since_response_created`，以后不再用“speech_started 到 transcript_final”猜 VAD 延迟。
6. session.updated 记录 `voice_matches_request` 和服务端是否返回 effective voice；不记录密钥或原始语音。

## 当前验证

- 新增回归先失败，证明 tool-call-before-first-audio 的旧状态机会错误进入 `finishTurnWithToolResult`。
- 修复后完整 `scripts/test-stepfun-voice-lifecycle.sh`：53 项 XCTest + 24 项 Swift Testing 全部通过。
- 全应用 typecheck 退出 0；只剩仓库原有 warning。
- 真实听感、服务端 effective voice 与新的 speech-stop→first-audio 延迟仍需新构建上的下一轮真人会话验证。

### 21:46–21:47 真人复测

- `session.updated` 明确返回 `voice_matches_request=true`，服务端生效 voice 与请求的自定义 `voice-tone-*` 一致。
- 普通对话：speech_stopped → first audio 约 72ms；Realtime 本身的首包不是主要延迟来源。
- `open_app` 工具轮：旧 response 的 preamble 已被 `tool_preamble_audio_suppressed` 丢弃；最终回执 response 首音频在其 `response.created` 后约 653ms。
- 用户仍主观听到明显音色漂移。因此客户端切换 voice ID 已基本排除；剩余可控差异是回执 response 的“原样朗读”response-level instruction。现已移除：`spoken_response_exact` 写入 tool result，后续 response 继承正常 session 声学条件，客户端继续用 transcript 做逐字验收。
- 如果下一轮仍明显漂移，并且 `voice_matches_request=true`、每个工具轮只有一个 audible response，则问题收敛到 StepAudio 3 Realtime 对当前自定义 voice 的跨 response 声学稳定性；下一步应做官方内置 voice A/B，而不是继续堆本地音频路由。

## 下一轮判定

如果日志显示 `voice_matches_request=false`，优先处理服务端 voice 配置/自定义 voice 兼容，而不是继续调播放器。
如果 `voice_matches_request=true`，且每个工具轮只剩一段最终语音但用户仍明显听到换声，则问题收敛到
StepAudio 3 Realtime 对当前自定义 `voice-tone-*` 的跨 response 音色稳定性；届时应 A/B 一个官方内置 voice，
不要再通过增加本地语音路由掩盖它。

如果普通对话 `ms_since_speech_stopped` 持续很低而工具轮高，继续优化工具 response 生命周期；如果二者都高，
再调整 server VAD/音频上行，而不是先改 JEV 或 Computer Use。
