# 桌面伙伴验收

此目录只提供本地测试页；真实客户端和任务入口使用 Debug 构建中的显式探针参数。
不读取环境密钥或其他项目配置，密钥由签名应用正常读取自己的 Keychain。
Release 构建没有这些入口。探针不打开麦克风，不自动播放输出音频。

先在 Xcode 构建 `tiptour-macos`。不要从终端运行 xcodebuild。

## 独立结果页面

```sh
python3 tools/voice-acceptance/fixture.py
```

用普通 Safari 窗口打开 `http://127.0.0.1:19475`。页面只有测试控件。
真实桌面输入需要短暂独占该窗口；自动化浏览器的控制浮层可能拦截外部鼠标事件，
不能把这种干扰当成通用模型或驱动的结论。
页面包含左右两个同名“设置”按钮，以及“打开显示设置”→“缩放选项”两步路径。
`GET /state` 独立返回 `selected`（左右分别是 `left-setting`、`right-setting`）、
`clicks`、`menu_open` 和有序 `events`。缩放按钮仅在菜单打开后出现，
服务端也拒绝在菜单打开前选中 `scale`。`POST /reset` 只重置此测试数据；
重置后刷新 Safari 标签页，确保可见状态与服务端一致。

## 四种 Debug 探针

以下 `APP_BINARY` 指 Xcode 构建产物的 `TipTour.app/Contents/MacOS/TipTour`。
它仅是命令中的路径占位符，不是新的凭据配置。

```sh
APP_BINARY --desktop-task-probe com.apple.Safari '{"goal":"点击检查官网部署状态（3）","target_label":"检查官网部署状态（3）"}' /tmp/task-result.json
APP_BINARY --voice-route-probe /tmp/input.pcm /tmp/voice-comparison
APP_BINARY --voice-task-probe com.apple.Safari /tmp/input.pcm /tmp/voice-task
APP_BINARY --jev-fanout-probe com.apple.Safari '点击检查官网部署状态（3）' /tmp/jev-fanout.json
```

- `desktop-task-probe` 调用生产工具路由、协调器和执行引擎；输出任务回执。
  只有日志明确出现 `decision provider=JEV` 且 `/state` 与目标一致，才算真实 JEV 决策验收；
  精确目标直达或 `decision provider=StepFun general` 都不能替代这一项。
- `voice-route-probe` 用合成输入和生产工具声明检查 Realtime 的转写、音频和工具请求。
  它不执行工具，也不调用独立 TTS。
- `voice-task-probe` 现在使用完整生产 `StepFunRealtimeSession`，不是另一套工具循环。
  同样执行每轮一次桌面任务、Realtime 音频播放与已验证回执播报。
  输出 `realtime.json` 中的 `calls`、`tool_results`、`rendered_texts`，以及 `realtime-output.pcm`。
  只有输入麦克风和输出扬声器被替换为 PCM；不验证真人声音、回声消除或扬声器打断。
  `completed` 仅指探针正常结束；任务是否完成仍须检查回执和独立 `/state`。
- `jev-fanout-probe` 只读取当前应用的本地候选并调用生产 JEV question set。
  它一次发送 `done/absent/action/target_click/target_double_click/target_right_click`，
  写入选择、概率、margin、token 与耗时；输出必须包含 `executed=false`，不会调用 action engine。

输入必须是 **无 WAV 文件头**的 24 kHz 单声道 PCM16 小端字节。可用系统 `say`
产生测试语音，`afconvert` 转成 WAV 后通过 Python `wave.readframes` 提取 PCM。
不得将 WAV 容器直接当 PCM 发送。

验收必须同时读取 `/state`，并对照工具回执和真实页面。错误、暂停、结果文件缺失均不算通过。
测试完成后关闭专用标签页并停止测试服务器。不要保留用户桌面截图或私人语音到仓库。
