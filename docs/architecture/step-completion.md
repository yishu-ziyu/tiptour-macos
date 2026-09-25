# Step completion truth table (code-owned)

Part of the [architecture overview](README.md). Moved verbatim from `AGENTS.md` on 2026-09-23.

`DesktopActionCompletion` in `TipTour/Voice/DesktopTaskContract.swift:193` is the only source of truth for "does this step count as done". The coordinator, the receipt, the spoken summary and the telemetry all read these predicates (`DesktopTaskContract.swift:327`, `:332`, `:337`); nothing may re-derive its own completion rule.

The policy is chosen per step, not by the model (`DesktopStepCompletionPolicy`, `DesktopTaskContract.swift:162`): `open_app` and `type` are always `outcome_required`; `click`, `double_click`, `right_click`, `press_key`, `shortcut` and `scroll` are `delivery_sufficient` only when the step carries no explicit `expected_label`.

| Delivery | Outcome evidence | `delivery_sufficient` | `outcome_required` |
| --- | --- | --- | --- |
| `not_sent` | `not_observed` | not satisfied — task ends `paused` | not satisfied — task ends `paused` |
| `sent` | `not_observed` | **satisfied**, basis `delivery_confirmed` | **`uncertain_effect`** |
| `sent` | `system_verified` | satisfied, basis `system_verified_outcome` | satisfied, basis `system_verified_outcome` |
| `sent` | `user_confirmed` | satisfied, basis `user_confirmed_outcome` | satisfied, basis `user_confirmed_outcome` |
| `unknown` | any | **`uncertain_effect`** | **`uncertain_effect`** |

`unknown` never co-occurs with outcome evidence in practice: the executor only reports `system_verified` once `delivery == .sent` (`DesktopTaskExecutor.swift:99`, `:187`), so that row means "the driver could not say whether the input landed".

- `satisfied` (`DesktopTaskContract.swift:194`) is true when outcome evidence is `system_verified` or `user_confirmed`, or when the policy is `delivery_sufficient` and delivery is `sent`. Nothing else satisfies a step.
- `uncertain_effect` (`DesktopTaskContract.swift:203`) is true only when delivery is `unknown`, or delivery is `sent` with an `outcome_required` policy and no outcome evidence. A `delivery_sufficient` step that was sent is never uncertain; a step that was never sent is `paused`, not uncertain.
- `verified` (`DesktopTaskContract.swift:325`) is a compatibility view meaning `outcomeEvidence == .system_verified` only. Old JSON consumers still read it; it is never an input to a decision.
- The task advances to the next step only when the current one is satisfied (`DesktopTaskCoordinator.swift:648`). A satisfied step counts as done even when interruption arrives before the receipt is returned (`DesktopTaskCoordinator.swift:640`), and a satisfied step is never re-dispatched by a later resume.
- Spoken wording stays separate from completion: `delivery_confirmed` only names the input action ("已点击「…」。", "已按下 enter。", "已向下滚动。") and never claims a result; only `system_verified_outcome` claims a confirmed result, with action-specific wording (`已确认「X」已启动。` / `文字已输入，并已读回确认。` / `已确认「X」的操作结果。`); `user_confirmed_outcome` says "你已确认上一轮操作已经生效。" (`DesktopTaskContract.swift:344`, `:394`, `:437`).

Progress and history — the counters, the two history lists and the difference between a system verification and a user confirmation must never be merged into one "done":

| Field | Meaning |
| --- | --- |
| `completedStepCount` / `totalStepCount` | steps counted done so far / plan length. Progress while `status` is `running` or `pausing`; it is not a completion claim |
| `verifiedActionHistory` | summaries of steps whose effect the **system** independently verified. Never contains delivery-only or user-confirmed steps |
| `satisfiedActionHistory` | summaries of every step that counts as done — delivery-confirmed direct inputs, system-verified outcomes and user-confirmed outcomes. This is the list the decision model receives as already-done history |
| `user_confirmed` | outcome evidence the **user** supplied through `uncertain_resolution: confirmed_succeeded`. It satisfies the step, enters the satisfied history as `用户已确认结果`, never the verified history, and performs no new side effect (`DesktopTaskCoordinator.swift:445`) |

`uncertain_resolution` values: `confirmed_succeeded` records the user's confirmation (no new side effect, `promoted_to_verified=false`), `confirmed_failed` lifts the block and leaves the attempt attempted-unverified, `retry_same` re-runs the same goal with the recorded target pinned so the decision layer cannot pick the runner-up, and `replace_target` requires `intent=correct` plus an explicit new target. Uncertain records are scoped to their task chain, so a brand-new instruction is never blocked by an older task's uncertainty (`DesktopTaskCoordinator.swift:349`).
