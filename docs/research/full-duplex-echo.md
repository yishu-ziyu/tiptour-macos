# 全双工还是半双工：别的产品怎么处理「听见自己」

现行研究文档，2026-09-25 建立。起因：审视 [Samuel](https://github.com/sambuild04/screen-voice-agent) 时发现它靠「她说话时关麦」解决回声，用户要求先弄清 Her 是否要坚持全双工，再决定怎么修[停放的阶段 2](../development/2026-09-25-listen-and-baseline-map.md) 步骤 1d「她听到自己的声音、自言自语」。方法按 [tw93/Waza](https://github.com/tw93/Waza) 的 `learn`（只用一手资料，矛盾摆明）和 `think`（先看 2–3 个成熟实现再设计，给一个推荐和一个最小做法）。

## 两种做法

- **全双工**：她说话时麦克风照常把声音发给模型，用户开口就能打断她。前提是回声消除把她自己的声音从麦克风里减干净。
- **半双工**：她说话时不发麦克风的声音，说完才发。不会听见自己，但用户不能用嘴打断她。

## 一手资料

| 来源 | 做法 | 给用户留的退路 |
| --- | --- | --- |
| [ChatGPT Voice 帮助页](https://help.openai.com/en/articles/8400625-voice-mode-faq) | 全双工，边说边听 | 被打断时建议戴耳机、换安静环境；可以口头要求「等我说开始再回答」 |
| [OpenAI 开发者论坛：Mac 应用自己打断自己](https://community.openai.com/t/voice-mode-not-working-in-mac-app-cutting-off/1245791) | 2025-04 某次更新后，Mac 应用每说两三个字就被自己的声音打断 | 用户报告，属于实现层面的回归 |
| [Gemini Live API](https://ai.google.dev/gemini-api/docs/live-api/capabilities) | 默认检测到用户说话就打断（`START_OF_ACTIVITY_INTERRUPTS`） | 提供 `NO_INTERRUPTION`：检测照常，但不打断正在说的回答 |
| [OpenAI Realtime VAD](https://developers.openai.com/api/docs/guides/realtime-vad) | `interrupt_response` 默认打断 | 可关掉自动打断，由客户端自己决定何时打断、何时回答 |
| [LiveKit Agents 轮次文档](https://docs.livekit.io/agents/logic/turns/) | 全双工；`min_duration`、`min_words` 过滤短促声音 | 「假打断」：检测到声音先停下，若在 `false_interruption_timeout`（默认 2 秒）内没转写出字，就从原处接着说 |
| [Pipecat 用户静音策略](https://docs.pipecat.ai/server/utilities/filters/stt-mute) | 默认全双工 | 可选静音策略：只在开场白、工具调用期间，或 `ALWAYS`（她每次说话都静音，即半双工） |
| [HeyClicky](https://www.heyclicky.com/)（开源版 [farzaa/clicky](https://github.com/farzaa/clicky)，Her 的前身之一，见 [lineage.md](../lineage.md)） | 按住 Ctrl+Option 才录音，松开后语音识别（AssemblyAI）→ Claude → ElevenLabs 合成语音；识别和合成是分开的两步，麦克风只在按住时开，不会听见自己 | 按下快捷键先停掉正在播放的语音（`CompanionManager.swift` 的 `handleShortcutTransition`），即用按键打断 |
| Samuel `src/hooks/useRealtime.ts` | 声明支持打断（`interrupt_response: true`），但她一开口就关麦，回答生成完再等 1.5 秒（开场白 3 秒）才开；另外丢掉与她上一句重合的转写 | 实际是半双工；用户说「那不是我说的」可撤回上一轮 |
| [阶跃实时接口文档](https://platform.stepfun.com/docs/zh/api-reference/realtime/chat) | `turn_detection` 只有 `prefix_padding_ms`、`silence_duration_ms`（默认 100）、`energy_awakeness_threshold`；没有「自动打断」开关，`speech_started` 只是「一般用于打断场景」的通知 | 打断与否完全由客户端决定：Her 在 `StepFunRealtimeSession.handleUserStartedSpeaking()` 里自己停播、自己发取消 |
| [Apple WWDC23：语音处理新功能](https://developer.apple.com/videos/play/wwdc2023/10235) | `isVoiceProcessingInputMuted` 静音后，`setMutedSpeechActivityEventListener` 仍能报告「有人在说话」 | 半双工时仍可知道用户想插话（未验证在她放音时是否会被回声触发） |

## 从资料里得出的

1. **全双工是一线产品的默认，半双工是回声压不住时的退路。** ChatGPT、Gemini、LiveKit、Pipecat 都默认全双工，也都给了退路：戴耳机、不打断模式、假打断恢复、静音策略。没有一家把半双工当目标。
2. **退路分两类。** 一类保留打断、过滤误报（LiveKit 的假打断、最短时长和最少字数；OpenAI、Gemini 关自动打断后由客户端判断）；一类直接不听（Pipecat `ALWAYS`、Samuel）。前一类要能在打断发生后很快判断「刚才是不是真人」，后一类代码最少。
3. **Mac 外放本来就难，但 Her 的问题不是物理极限。** 同一台 Mac、同样开系统语音处理，最小程序放音期间麦克风为 −60 到 −67 dBFS，Her 里为 −22 到 −33 dBFS（证据见[停放地图](../development/2026-09-25-listen-and-baseline-map.md) 2026-09-25 的决定），差 30–40 dB。ChatGPT Mac 应用也因为一次更新出过同样的症状。更可能是 Her 的实现把回声消除弄失效了，原因未定。
4. **矛盾处：** LiveKit 文档说，实时模型自己做轮次检测时，框架的大部分打断选项不起作用；Her 用的阶跃不会自己打断，打断由 Her 决定，所以这些做法 Her 都能用。Samuel 的配置写着支持打断，实际因为关麦做不到；以代码行为为准。

## 选项

| | 做法 | 保留插话 | 改动 | 风险 |
| --- | --- | --- | --- | --- |
| 最小 | 半双工：她说话到放音结束再过 1.5 秒之前不发麦克风声音，并丢掉与她上一句重合的转写 | 否 | 麦克风回调里加一个开关；恢复绑在「播放放完」上，并加超时兜底 | 某轮没正常结束时麦克风可能一直不恢复，所以超时兜底必须有 |
| 推荐 | 默认全双工；一旦发现回声（转写与她正在说或刚说完的话重合），本次会话剩下的时间自动改成半双工，并记录下来 | 回声消除正常时（如戴耳机）保留 | 最小做法加一处检测和一个会话内状态 | 每次会话第一次回声仍会打断她一次；之后不再发生 |
| 放后面 | LiveKit 式假打断：听到声音先暂停不取消，转写回来确认是真人再打断，否则接着说 | 是 | 要处理阶跃自动为回声那一轮生成的回答（取消、删除），LiveKit 的阶跃插件里已报告过取消时序的竞争 | 回声频繁时她会一顿一顿；复杂度最高 |
| 以后可加 | 学 HeyClicky：半双工期间按一个键就能让她停下（旧仓库 `YishuDuplexAudioFloor.swift` 也定过「开口只停声、不取消任务」的约定，见 lineage.md） | 按键可以 | 一个快捷键动作 | Ctrl+Option 现在用来开关整段会话，要另选按键或区分短按和长按 |
| 根治 | 查清 Her 里回声消除为什么比最小程序差 30–40 dB | 是 | 未知 | 原因未定；停放地图里下一步本是「戴耳机对照」 |

推荐项与根治不冲突：推荐项保证外放时不再自言自语，根治恢复外放时的插话。

用户于 2026-09-25 选了推荐项，已在分支 `fix/echo-half-duplex-fallback` 实现（`HalfDuplexMicrophoneGate`、`OwnSpeechEchoDetector`，行为见 [provider-modes.md](../architecture/provider-modes.md)），尚未在真实构建上验收。验收：用 MacBook 外放连聊 5 句，识别出的「用户的话」里没有她上一句的原话；若出现一次回声，此后她不再被自己打断，也不回答自己。

## 还不知道的

- 阶跃在客户端取消回答、删除对话项上的具体行为，没有在真实会话里测过。
- Apple 静音时的说话检测在她放音时会不会被回声误触发，没有测过。
