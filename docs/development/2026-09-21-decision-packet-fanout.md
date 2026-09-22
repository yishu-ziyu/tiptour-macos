# Decision Packet + speculative fan-out

> **文档性质：历史证据日志（2026-09-21 记录，冻结）。**
> 本文件只保留当天的真实过程、失败与结论，不随代码演进而更新，也不得为"变绿"而改写。
> 分类标注由 2026-09-23 的文档核对工单添加，正文一字未改。当前事实见根目录 `AGENTS.md`
> 与本目录 `README.md`。

日期：2026-09-21。基线：当前 `main@6dbba3a` 的未提交 voice/computer-use 改动。

## 先确认现状

当前 `JevGrounding.request` 已经把 `done / absent / pick / kind` 四个窄问题放进同一次
System One 请求，因此 speculative fan-out 不是新增一个服务。真正的问题是：`pick` 和 `kind`
独立回答，代码没有保证“这个 target 是针对这个 action 选的”；更严重的是 voice
`DesktopTaskCoordinator` 当前只消费 target，JEV 返回的 `decision.action` 没有进入执行 step。

外部参考也指向同一个模式：一次请求里并行询问 operation 与每个 operation 对应的 target，
代码只消费被选 operation 的 target；低概率分支不能产生副作用。这个模式应落在现有 JEV
决策边界，不应先把每个 Realtime utterance 都改走 JEV。

## 最小方案

第一版不扩工具、不加模型、不重写语音会话，不改变已有显式 action 的优先级。

1. JEV 一次请求并行问：
   - `done`
   - `absent`
   - `action`: click / double_click / right_click
   - `target_click`
   - `target_double_click`
   - `target_right_click`
2. 代码先读 `action`，只消费对应的 `target_<action>`。另外两个 target 回答即使高分也不能执行。
3. 新增 `DesktopDecisionPacket`，统一表示本次执行所需的结构化事实：
   `intent / action / target / where / scope / confidence / requires_perception / requires_planning / evidence`。
4. 如果 `act_on_screen` 显式给了 action，packet 记录并锁定该 action；JEV 只选 target。
   如果顶层 action 被省略（现有协议默认 click），才允许 JEV 的 action head 决定三种 pointer primitive。
5. exact target / open_app 等不需要 JEV 的路径也生成 deterministic packet，避免系统里出现两套动作语义。
6. packet 跟随本轮 action record，并记录不含屏幕原文的结构化 trace。执行器仍然只接受既有 primitive。

## 为什么暂时不做更多

- 不给 action/target probability 拍脑袋设自动执行阈值。现有流量没有标注数据，阈值必须通过真实失败样本校准。
- 不让 JEV 生成自由文本、输入值或应用名称；代码/Realtime 仍绑定这些精确值。
- 不把所有语音意图先路由一次 JEV。那会增加新网络 hop，而且目前没有证据证明它比 Realtime tool call 更快或更准。
- 不扩到 move/drag 等新 primitive；先证明现有 click 三分支的 fan-out 是一致的。

## 验收

1. 一个 JEV HTTP request 同时包含 action 与三种 target head。
2. `action=double_click` 时，即使 `target_click` 的最高概率更高，也只能消费 `target_double_click`。
3. 被选 target 必须来自当前 observation；`__none__` 仍能零动作退出。
4. 显式 `right_click` 不会被 JEV 的 action head 改成 click。
5. 未显式 action 的 pointer 请求允许 JEV 把默认 click 修正为 double/right，并真实传入 executor。
6. exact label、open_app、纠正/取消、单目标一次副作用预算保持现有行为。
7. 每次下发动作都有一个 packet；默认 trace 至少能看到 source/action/scope/confidence 是否存在，屏幕文字仍不进入公开日志。
8. `scripts/test-jev.sh`、受影响 voice lifecycle tests、全应用 typecheck 通过；不从终端运行 xcodebuild。

## 失败即回退条件

如果 fan-out 让 JEV 响应格式不稳定、延迟显著上升，或者 action-conditioned target 在真实样本上比当前
pick+kind 更差，保留 `DesktopDecisionPacket`，将 JEV question set 回退为旧实现；不要为了维护新抽象而保留坏行为。

## 当前执行记录

- `JevGrounding` 已改为 6 个同请求 head：`done / absent / action / target_click / target_double_click / target_right_click`。
- 显式 pointer action 通过 `forcedActionKind` 只消费自己的 target head；模型 action head 即使高分不同意也不能覆盖。
- 顶层 action 省略时才设置 `allowsActionDecision=true`；coordinator 会把 JEV 选出的 pointer primitive 真正写回执行 step。
- 每个真实下发 action 现在携带 `decision_packet`；默认 VoiceTask trace 记录 source/scope/action/target confidence，不公开屏幕文字。
- JEV 纯测试最终 16 项通过；完整 voice/task lifecycle 53 项通过，其中 Decision Packet contract 23 项；
  StepFun 工具契约 13 项通过；全应用 typecheck 退出 0（仅保留仓库既有 warning）。
- 最终 Xcode Build action `87153-13` succeeded。
- 新增 `--jev-fanout-probe` 只读生产候选并调用真实 JEV，不执行 action engine。首次运行被现有 Keychain 的无交互访问挡住：`JEV Keychain key unavailable`，因此本轮没有伪称真实 API 延迟或在线兼容性已实测。探针代码保留，用户正常解锁 Keychain 后可立即复跑。
- 没有添加未经校准的 confidence threshold，也没有把所有 Realtime utterance 额外路由一次 JEV。
