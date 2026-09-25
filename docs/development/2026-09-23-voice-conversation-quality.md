# 阶段 2：语音对话质量——语音默认、起名、人格、ThinkingOrb 状态、延迟测量

日期：2026-09-23。`docs/ROADMAP.md` 阶段 2 的工作契约与证据记录。
「契约」一节随实现修改；「证据」一节是现场记录，只追加，不改写失败。

## 契约

| # | 可观察的变化 | 不接受的替代 | 评判方式 | 证据 |
| --- | --- | --- | --- | --- |
| P1 | 全新安装时，设置第 1 步是起名，第 2 步里「阶跃 · 实时语音」排第一并默认选中 | 只改文案、老用户被强制切换模式 | 用户在 Xcode 构建后看设置流程；老用户的已存模式不变 | 截图 / 用户确认 |
| P2 | 起的名字保存在本机；设置 → Models 能看到并修改同一个名字；面板标题显示这个名字 | 名字只存在界面状态里、重启丢失 | 改名 → 退出重开 → 仍在 | 用户确认 |
| P3 | 真实阶跃会话里问「你叫什么名字」，她用这个名字回答；没起名时如实说还没有名字 | 单测断言提示词里含名字 | `--voice-route-probe` 用合成语音走真实阶跃端点，转写里出现名字；真人麦克风再问一次 | `out/acceptance/presence-*/` 探针 JSON |
| P4 | ThinkingOrb 在面板标题和光标旁显示：连接中、聆听、回应各有不同形态，空闲时缓慢呼吸 | 静态图标、只换颜色 | 用户在真实会话里看 | 用户确认 |
| P5 | 真麦克风会话后得到两个数：说完 → 她第一声（p50）、插话 → 服务器判出插话（p50，本地开口时刻为估计值） | 合成探针的数字、只报单次 | `scripts/acceptance/voice_latency_report.py` 读取会话期间的统一日志 | `out/acceptance/presence-latency-*/latency.json` |

插话延迟的口径：本地停播在收到服务器 `speech_started` 的同一时刻发生，所以主要耗时在「用户开口 → 服务器判出」。
本地开口时刻取她说话期间、经过回声消除后麦克风能量第一次超过阈值的时刻。背景噪音会让它偏早，从而让延迟偏大；这个数是上界估计，不是精确值。

不在本步：唤醒词、记忆、删除 Gemini、角色形象。

本文件 2026-09-23 前名为 `2026-09-23-presence.md`；下方证据中的旧阶段称呼按原样保留，统一名称见 [../terminology.md](../terminology.md)。

## 证据

### 2026-09-23 实现完成、Xcode 构建前

以下都是回归或接缝检查，不是 P1–P5 的完成证据。

- `scripts/typecheck-local-app.py`：改动前后均 `TYPECHECK_EXIT=0`，警告数 54 → 54（全部为原有弃用警告）。
- `scripts/test-jev.sh`：16 项通过（含改为 `.stepfun` 的默认模式断言）。
- `scripts/test-stepfun-voice-lifecycle.sh`：30 项通过。
- `voice_latency_report.py` 解析检查：临时进程以 `com.yishuziyu.her` / `VoiceTask` 写 6 条假事件，经真实 `log stream` 采集后，报告得出首声 n=1（同一轮只计第一段、回执音频排除 1 条）、插话 n=1、无本地开口 1 条，与构造一致。
- P3 合成输入已生成：`out/acceptance/presence-persona-inputs/utterance-b5f6a758beb9be4b.pcm`（「你叫什么名字？」，Tingting，1.19 s）。

### 构建后要跑的

```sh
APP_BINARY=~/Library/Developer/Xcode/DerivedData/tiptour-macos-gtcdcfrkrqlavldfoxxsyfksnyrq/Build/Products/Debug/Her.app/Contents/MacOS/Her
INPUT=out/acceptance/presence-persona-inputs/utterance-b5f6a758beb9be4b.pcm
"$APP_BINARY" --voice-route-probe "$INPUT" out/acceptance/presence-persona-named -companionName 小满
"$APP_BINARY" --voice-route-probe "$INPUT" out/acceptance/presence-persona-unnamed -companionName ""
python3 scripts/acceptance/voice_latency_report.py record   # 真麦克风会话，Ctrl-C 结束
```

P3 通过条件：`presence-persona-named/realtime.json` 的 `transcript` 含「小满」；`presence-persona-unnamed` 的回答说明还没有名字，且没有自己编名字。

### 2026-09-23 13:12–13:14 第一次真人会话（13:12 构建）

用户结论：视觉交互没问题；语音「超级垃圾」，音色一直在跳，声调奇怪，回应有点呆。P4 用户认可，P1/P2 未单独确认（用户已完成过设置，名字未起）。

日志（`out/acceptance/presence-latency-20260923T052045Z/`，来自 `/usr/bin/log show --info`）：

- **两个 Her 同时在跑**：pid 10531（09:16 启动的旧构建）与 pid 52189（Xcode 新构建）各自发出 `realtime_voice_configured`。13:12:37–13:12:52 每次用户说话都产生两个 turn、两段回应音频；其中 52189 的一次 `barge_in_detected` 发生在它自己说话 97 ms 后，最可能是听到了 10531 的声音。10531 于 13:13:00 退出，之后三轮只有 52189。
  两路会话各自开启语音处理，互相听到、互相打断，这足以解释该时段的换声、怪声和答非所问。它不能解释 9-20/9-21 已记录的单会话换声。
- 单会话三轮：`voice_matches_request=true`；一次 `open_app` 完成并验证，回执逐字匹配后播放。
- 首声（服务器 `speech_stopped` 口径）n=8，p50 212 ms，36–860 ms；其中 6 个样本处于双进程时段。这个口径不含服务器等待静音的时间，低估了用户感受。
- 插话 3 次，本地开口全部未测到：−35 dBFS 阈值在她说话时从未触发，包括两次 5–6 s 的真实插话。

本轮修改（13:20 后，待构建）：

- `SingleInstanceGuard`：正常启动时先让其他交互式 Her 退出（3 s 后强制），带 `-probe`/`--preflight` 参数的探针实例不动。
- 音色开关：`defaults write com.yishuziyu.her stepfunRealtimeVoice <voice>`，默认仍为自定义音色；会话开始记录 `voice_session_starting` 的 voice。
- 测量：阈值降到 −45 dBFS 并报告她说话时的麦克风峰值；新增「估计的用户说完 → 首声」，含服务器静音窗口。
- 她的回话原文写入 `output_transcript_final` 私有字段，只在 DEBUG `voiceDiagnosticTraceEnabled` 打开时落到本机文件。

### 2026-09-23 13:36–13:37 第二次真人会话（仍是 13:12 构建）

用户：「只聊了两三句就跳音色。」日志（`out/acceptance/presence-latency-20260923T053741Z/`）：
只有 pid 52189 一个进程；一次 `realtime_voice_configured`，`voice_matches_request=true`；两轮普通对话，每轮一个 response、一段音频，没有工具、回执、打断或 response 级参数。
这排除了双进程和工具轮链路：客户端在这两轮之间没有发出任何会改变声学条件的东西。
与 2026-09-21 记录的判定一致，问题收敛到 `stepaudio-3-realtime-preview` 对自定义 `voice-tone-T3kZb9MwL2` 的跨 response 稳定性（或模型本身），待官方音色 A/B 区分。

为此新增客观测量，不再只靠听感：

- `Her --voice-consistency-probe <voice> <dir> <turn.pcm>...`：同一会话多轮合成输入，生产人格指令，无工具，每轮回复音频单独保存。
- `scripts/acceptance/voice_consistency_report.py`：每轮基频中位数、MFCC 音色向量、轮内前后半段差异作为基线；相邻轮 drift_ratio ≥ 1.6 或音高差 ≥ 5 半音判为换声。
  `--self-check` 用 macOS `say` 验证：同一音色 0 次、女→男 1 次、女→女 1 次，`SELF_CHECK=PASS`。阈值未在阶跃真实音频上校准，听感仍由用户裁定。
- 输入：`out/acceptance/voice-consistency-inputs/` 5 句日常对话（Tingting 合成）。

### 2026-09-23 13:44 构建上的探针结果

音色 A/B（同模型 `stepaudio-3-realtime-preview`、同 5 句输入、同人格，四次 `voice_matches_request=true`）：

| 运行 | 判为换声 | 相邻轮 drift_ratio / 音高差 |
| --- | --- | --- |
| `voice-consistency-custom-1`（`voice-tone-T3kZb9MwL2`） | 2 | 2→3：1.73 / −6.45 st；3→4：1.28 / +5.5 st |
| `voice-consistency-custom-2` | 1 | 3→4：2.11 / +2.7 st |
| `voice-consistency-official-1`（`linjiajiejie`） | 0 | 最大 1.12 |
| `voice-consistency-official-2` | 0 | 最大 0.94 |

结论（样本小，属强迹象而非定论）：自定义克隆音色在该模型上跨 response 换声，官方音色没有。试听文件：`out/acceptance/voice-ab/{custom,official}-{1,2}.wav`。
用户决定：默认音色改为 `linjiajiejie`；克隆音色仍可用 `stepfunRealtimeVoice` 切回。

P3 通过：`presence-persona-named` 回答「小满。」；`presence-persona-unnamed` 回答「还没有名字，你给我起一个吧。」；用户本机未存名字，未被改动。

「回应呆」的证据：四次探针的回复几乎都是一句话（「在的。」「好，去吧。」），被问「你最近在想什么」时把问题推回给用户。原因是本步加入的人格行「用户说得短你也短；嗯/好/在本身就是完整回复」，以及工具规则里的「回复一两句」。已改为有温度、会接话、会说自己的想法、闲聊一到三句；「回复一两句」限定为涉及操作时。待构建后用同一输入复测。

单实例保护：
- 两个非调试实例：`open -n` 启动 A（29995），再启动 B（30210），A 被关闭，只剩 B。通过。
- Xcode 调试中的实例（8039，状态 `SX`）对 `terminate()` 和 `forceTerminate()` 都无反应，两者都返回 true。原逻辑下新实例仍会继续启动，形成两个 Her。已改为：强制关闭后仍存活，新实例自行退出。待构建后复测。

### 2026-09-23 14:20 构建上的复测

- 单实例：Xcode 调试实例 81980 在跑时 `open -n` 新实例 255；3–10 s 内 255 自行退出，81980 保留并持有 19474。通过。
- 官方音色 + 第二版人格（`voice-consistency-persona2-official-{1,2}`）：换声 0/0。回复不再只有一两个字，但第 3、4 轮 62–74 字、12–20 s，三轮以提问收尾，第 3 轮复述用户原话。
- 第三版人格（`out/acceptance/persona-variants/persona-3.txt`，经 `-probePersonaFile` 不重建测试；`voice-consistency-persona3-official-{1,2}`）：回复 7–52 字，除一次 11 s 外都在 8.3 s 内；只有一轮提问。已逐字写入 `companionPersonaInstructions`（校验 identical），待构建。
- 换声：persona3-official-2 的 1→2 轮判为换声，ratio 1.65，音高 −1.75 st，前一轮是 1.6 s 的「在呢，你好呀～」。换用会话中位数基线重算 8 次运行，官方最高 1.65/1.51，克隆 1.71–1.9，仍重叠。
  结论：官方音色 6 次运行中 1 次落在分辨不清的区间，克隆 2 次运行中 3 次被判换声，其中两次明确。官方明显更稳，但不能说「不会跳」；该评判器只对大的变化可靠，阈值未改。
  试听：`out/acceptance/voice-ab/persona3-official-2.wav` 的前两句就是这一对。

### 2026-09-23 14:33–14:34 第三次真人会话（14:32 构建，官方音色，第三版人格）

用户：「声音不跳，但是回话没有那么自然，而且会断音。」日志 `out/acceptance/presence-latency-20260923T063518Z/`：

- 只有一个进程；`voice_session_starting voice=linjiajiejie`。
- 用户最后一次出声 → 服务器 `speech_stopped`：4488、5648、5655 ms（配置 `silence_duration_ms=100`）。因此「用户说完 → 首声」p50 6923 ms（4513–9333）。这段时间麦克风一直低于 −45 dBFS，不是用户在说话。
- 14:34:05 她说话时服务器报 `speech_started`，本地播放被清空，此时麦克风峰值只有 −38 dBFS（此前的真实插话为 −16 到 −20 dBFS）。疑似假插话，这是一种「断音」。另两次打断后用户各说了约 10 s（打开应用、问屏幕），属于真实插话。
- 本地开口估计在她说话时 4.0–5.1 s 前就触发：−45 dBFS 会被回声残留越过，插话延迟这个数现在不可用。

推断（未证实）：服务器能量阈值 `energy_awakeness_threshold=2500` 对该环境底噪或回声残留过敏。本轮加入：

- `stepfunVADEnergyThreshold`（UserDefaults，1–5000，默认 2500），会话创建时注入客户端；`user_speech_stopped` 记录 `vad_energy_threshold` 和 `mic_level_dbfs_at_speech_stopped`（平滑后的房间电平）。
- `Her --vad-probe <out.json> <speech.pcm> <noise_dbfs> <tail_s>`：前置 2 s 噪音、语音叠加同电平噪音、再接尾部噪音，按实时节奏上传，记录服务器 start/stop 相对真实语音的时刻和纯噪音误触发次数。

用户补充（问卷）：断音两种都有，既有话说一半被切断，也有一卡一卡但话说完了；不自然主要是语气语调和内容，没选「等很久」；同意打开诊断记录（已执行 `defaults write com.yishuziyu.her voiceDiagnosticTraceEnabled -bool true`）。

针对「一卡一卡」，本轮先测量，不直接加缓冲垫：
- 播放器此前把奇数字节的音频块整块丢弃（PCM16 采样可能被切在两块之间），会造成可听的断点。改为把多出的 1 字节留给下一块。
- 每次回复结束时，`playback_drain_finished` 记录 `underruns`（新块到达时队列已播空的次数）和 `odd_byte_chunks`。
- 多轮探针记录每块的到达时间和字节数；`voice_consistency_report.py` 据此模拟「首块即播」的播放，报告卡顿次数、最大空档和消除卡顿所需的缓冲垫时长。用构造数据核对：过快到达 0 次，过慢 49 次，停顿 500 ms 报告 1 次空档、需 300 ms 缓冲垫，奇数块正确计数。
- 新增 `pitch_range_semitones`（单轮音高四分位距），作为语调平淡程度的客观参考。
- 语气对比：`out/acceptance/persona-variants/instructions-{current,expressive}.txt` 只差一行，把「情绪变化只能轻微调整语速和停顿」改为允许语调和节奏随情绪自然起伏。该行是为压克隆音色漂移加的，现在可能在压平语气。通过 `-probeInstructionsFile` 对比，不重建。

### 2026-09-23 下午 14:52 构建上的探针结果（未开麦克风）

语气对比（`tone-{current,expressive}-{1,2}`，官方音色，同 5 句输入，四次 `voice_matches_request=true`）：

- 两份指令的回复文字几乎逐字相同，只有一轮不同。改这一行不改变她说什么。
- 单轮音高四分位距均值：current 4.32 / 4.66 st，expressive 4.83 / 4.87 st。差别在运行间波动范围内，不能说 expressive 明显更有起伏。
- 换声：expressive 0/0；current-2 的 1→2 轮被判换声（音高 −7.0 st，drift_ratio 1.16）。第 1 轮是 1.5 s 的「在呢，你好呀。」，音高 326 Hz，只有音高差越线、音色差很小，更像打招呼时语调偏高，不是换人。
- 试听：`out/acceptance/voice-ab/tone-{current,expressive}-{1,2}.wav`。

播放连续性（同四次运行、20 轮回复，每块的到达时间）：

- 音频到达速度是实时播放速度的 1.5–3.3 倍；块与块之间的最大空档 22–35 ms；奇数字节块 0 个。
- 只要有约 35 ms 的缓冲垫就不会播空。网络送达不是「一卡一卡」的原因；待查的是本机播放和假插话清空，需要新构建上的真人会话遥测（`playback_drain_finished` 的 `underruns`）。

服务器 VAD（`vad-probe/`，同一句 4.85 s 合成语音，前 2 s、后 8 s 白噪音）：

| 能量阈值 | 噪音 dBFS | 服务器判定说完，距语音结束 |
| --- | --- | --- |
| 2500 | −80 | 3918 ms |
| 2500 | −55 / −45 | 1071 / 1096 ms |
| 4500 | −80 / −55 / −45 | 1072 / 1077 / 1094 ms |
| 2500（重复 6 次） | −60 | 1067–1734 ms，中位约 1230 ms |

- 噪音电平和能量阈值都没有把等待拉长；10 次中 9 次在 1.1–1.7 s，1 次 3.9 s。
- 真人会话中的 4488–5648 ms 在合成输入上没有复现。服务器判定开口也比真实开口晚约 0.8–1.1 s。
- 合成口径下估计「说完 → 首声」约 2.0–2.7 s（判定说完 1.1–1.7 s + 首块音频 0.7–1.1 s），仍高于 1.2 s 目标。
- 未证实的推断：真人路径多出的约 3 s 来自服务器收到的真实麦克风流（经过系统语音处理后的尾音或残留电平），或上传落后于实时。要靠新构建上 `user_speech_stopped` 的 `mic_level_dbfs_at_speech_stopped` 区分。

探针本身的问题：`--voice-consistency-probe` 读取输入失败时仍以 0 退出，输出目录为空；相对路径按应用的工作目录解析，不是调用者的目录。

### 2026-09-23 实时模型可用音色（`out/acceptance/voice-catalog/`）

用户认为 `linjiajiejie` 不好听。对 TTS 文档官方音色清单里的 36 个 ID，逐个在 `stepaudio-3-realtime-preview` 上开一次会话，输入是同样的两句合成语音：

- 可用 25 个（`session.updated` 生效音色与请求一致）：elegantgentle-female、livelybreezy-female、jingdiannvsheng、wenroushunv、qingchunshaonv、yuanqishaonv、linjiajiejie、qinqienvsheng、wenrounvsheng、jilingshaonv、ruanmengnvsheng、youyanvsheng、lengyanyujie、shuangkuaijiejie、wenjingxuejie、linjiameimei、zhixingjiejie、wenrounansheng、yuanqinansheng、cixingnansheng、zhengpaiqingnian、qingniandaxuesheng、boyinnansheng、ruyananshi、shenchennanyin。
- 不可用 11 个，服务器返回 400 `voice ... is not valid`：tianmeinvsheng、wenrougongzi、vibrant-youth、lively-girl、soft-spoken-gentleman、magnetic-voiced-male、zixinnansheng、shuangkuainansheng、ganliannvsheng、qinhenvsheng、huolinvsheng。
- 各音色的回复文字几乎相同，只有音色不同。试听文件：`voice-catalog/<id>.wav`。

### 2026-09-23 晚：用户选定音色，设置里可切换

用户试听 `voice-catalog/` 后选出三个官方音色，默认用温柔熟女，并要求把自己的克隆音色一起列出来。四个候选各跑 2 次 5 轮换声探针（`voice-pick-<voice>-{1,2}`，全部 `voice_matches_request=true`）：

| 音色 | 判为换声 | 说明 |
| --- | --- | --- |
| `wenroushunv` 温柔熟女 | 1 / 2 次运行 | run 1 的 1→2 轮：ratio 1.86、音高 −1.5 st；第 1 轮是 1.5 s 的短问候，音高差小 |
| `qingchunshaonv` 清纯少女 | 0 | 最大 ratio 1.18 |
| `jingdiannvsheng` 经典女声 | 1 / 2 | run 1 的 1→2 轮：ratio 1.83、−3.6 st，同样落在短问候之后 |
| `voice-tone-T3kZb9MwL2` 克隆 | 3 / 2 | run 1 连续三对：−12.45 st、+10.7 st（ratio 4.17）、−6.6 st（ratio 4.04），明确换声 |

官方音色的被判换声都落在短问候和下一句之间，属于该评判器分辨不清的区间，由用户试听裁定；克隆音色是明确的换声。
实现：设置 → Models 在阶跃模式下新增「她的声音」，四个选项，温柔熟女为默认，克隆音色带「多轮对话里可能突然换成别的声音」提示；从下一次会话生效。类型检查 `TYPECHECK_EXIT=0`，`test-stepfun-voice-lifecycle` 30 项、`test-jev` 16 项通过。尚未在 Xcode 构建后由用户在界面上确认。
