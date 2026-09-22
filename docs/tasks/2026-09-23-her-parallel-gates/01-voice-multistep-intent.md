# 工单 01：修复多步骤自然语音把网页控件误判为应用

## 用户问题

用户说：

> 点击打开显示设置，然后点击缩放选项。

当前真实 StepFun 入口稳定输出：

```json
{"action":"open_app","application":"显示设置"}
```

Her 因而尝试启动名为“显示设置”的应用，而不是点击网页里的两个控件。

## 目标行为

对于明确描述网页/窗口控件的顺序操作，Her 必须提交显式步骤：

```json
{
  "goal": "...",
  "intent": "new",
  "steps": [
    {"action":"click","target_label":"打开显示设置"},
    {"action":"click","target_label":"缩放选项"}
  ]
}
```

`open_app` 只用于真正的应用启动请求，例如“打开 Safari”“启动豆包”。

## 独占文件

- `TipTour/App/CompanionManager.swift`
- `TipTour/Voice/StepFunRealtimeTools.swift`
- 必要时 `TipTour/Voice/StepFunRealtimeToolRouter.swift`
- 可新增一个小型、代码所有的 intent normalization 文件

不得修改 task contract、journal、action driver、acceptance runner 或其他工单文件。

## 实现约束

- 先保存当前失败的真实 provider 证据，再改代码。
- 不能把“打开显示设置”“缩放选项”写死进产品逻辑。
- 不能只靠一句更长 prompt；必须有代码层的合法性门禁，使明显的“点击控件”请求不能以 `open_app` 进入执行器。
- 门禁不得把“打开 Safari”“启动系统设置”等真实应用请求改成 click。
- 多步骤必须仍受 1–6 步预算、精确目标和每步结果门禁约束。
- 模型第一次输出错误时，修复不能扩展成对多个候选试点。

## E2E 验收

使用签名后的 Her、真实 StepFun、生产 `StepFunRealtimeSession`、生产 router、Safari 本地 fixture 和独立 `/state`。

至少运行以下三次：

1. “点击打开显示设置，然后点击缩放选项。”
2. “先点打开显示设置，再点缩放选项。”
3. 再重复其中任一句，验证不是偶然成功。

每次都必须：

- tool call 不含 `open_app`。
- tool call 包含两个 click steps。
- `/state.events == ["open-menu", "scale"]`。
- `/state.selected == "scale"`。
- 第一步 `completion_policy=outcome_required` 且 `outcome_evidence=system_verified`。
- 第二步为 `delivery_sufficient + delivery_confirmed`，除非已有独立结果验证。
- `status=completed`，没有额外点击，没有改试其他控件。

三次必须连续通过；一次失败即不通过。

## 回归场景

在同一 E2E 运行中再验证：

- “打开 Safari”仍调用 `open_app`，并确认可见前台窗口。
- “点击右边的设置按钮”仍为 `click + region=right`。
- “右键点击设置按钮”仍为 `right_click`。

## 完成定义

真实自然语音入口连续三次通过，不以 `--desktop-task-probe` 代替。XCTest 只能作为回归，不算本工单验收。
