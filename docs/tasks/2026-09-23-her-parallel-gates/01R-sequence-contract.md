# 01R：真正打通多步工具参数，而不放宽授权

优先级 P1。只处理 [集成复验](INTEGRATION-RECHECK.md) 已披露的工具契约接缝；继承全部安全、Git 和构建约束。

## 问题证据

真实 StepFun 在两个改述下均给出以下形状：

```json
{"goal":"点击打开显示设置，然后点击缩放选项","intent":"new","action":"click","steps":[{"action":"click","target_label":"打开显示设置","expected_label":"显示设置页面已打开"},{"action":"click","target_label":"缩放选项","expected_label":"缩放选项页面已打开"}]}
```

`StepFunActionArguments.validatedSteps` 先因顶层 action 与 steps 混用抛错；新增的 declaredControlClickSteps 没有机会运行。上面 expected_label 也没有独立来源证据。
复现结果是“任务参数不完整或有冲突，没有执行”，不是 Keychain、JEV 或 Driver 故障。

## 独占范围

- `TipTour/Voice/StepFunRealtimeTools.swift`
- `TipTour/Voice/StepFunRealtimeToolRouter.swift`
- 本工单自己的证据目录 `out/acceptance/01R-sequence-contract/`

不得修改 CompanionManager、任务完成事实模型、验收总运行器、其他工单文件或目标权限。需要超出范围时由集成人员先重新分工。

## 实现要求

1. 先通过真实入口保留修前失败；不得只重放手填 steps 后宣布语音规划已通过。
2. 统一单步/多步规范化与校验顺序，删除重复判断。未知字段、未知动作、超预算和真实矛盾仍拒绝。
3. 冗余顶层 action 只能在明确定义的不冲突条件下规范化：不得丢失目标、方向、锚点、文本或用户要求；不能让多步坍缩为一动作。非冗余冲突不能“以 steps 为准”悄悄接受。
4. `goal` 是模型输出的字段，不等于已独立确认的原始转写。保留原始音频测试文本、原始参数及有效计划三层证据；不能宣称基于 goal 的补救能够证明所有原始用户意图都被保留。
5. expected_label 必须有合理来源与明确语义。优先保持代码推导的下一步依赖及已有验证路径；对模型自造的后置条件通过正常规划/参数反馈修正，不注入夹具文案，不统一删除所有后置条件，也不降级强验证。
6. 模型调用/规划修复必须有预算与终止条件；没有发生动作的参数重试和 delivery unknown 后的动作重试严格区分。后者仍禁止自动执行。
7. 正确的单动作、真实 open_app、明确右键、相对位置和连续输入不得被新规则改写。

## 独立 E2E 验收

使用集成后的 03R 正式入口或已有正式 voice-task-probe；签名、新鲜度与权限先通过。只在本地受控页面产生副作用。

| 场景 | 放行条件 |
| --- | --- |
| 原话两步 | 同一原话连续 3 次；每次 fresh reset；events 恰为 open-menu→scale；仅两条当前 action，无第三次副作用 |
| 改述两步 | “先点…再点…”单独至少一次；相同顺序与结果，不得替代原话 3 连过 |
| 两层事实 | 第一步因下一步依赖为 outcome_required 且 system_verified；末步遵守真实完成依据；completed=2/2 不靠全局放宽 |
| 普通单步 | 右侧设置仅右侧点击一次；非目标动作不被注入 region；原本正确动作保持语义 |
| 合法应用请求 | 在只路由不执行的正式语音探针中，真正打开应用仍保留 open_app；禁止为验收擅自操作用户应用 |
| 冲突/伪造条件 | 经正式 router 提交有矛盾的参数，零副作用且原因明确；不能为了完成任务忽略明确的用户后置条件 |

所有失败保留，不能重复运行到偶然成功后抹掉失败。交付 result.json 包含 raw arguments、有效计划及规范化原因、task/turn/attempt、独立 state、回执、音频转写和全部试次。
真实桌面依赖未就绪时标 BLOCKED。现有单测/静态回归不是完成标准。
