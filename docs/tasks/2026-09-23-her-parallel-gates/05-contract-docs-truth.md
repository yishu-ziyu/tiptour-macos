# 工单 05：同步 Her 的工程事实源与验收文档

## 目标

消除未来 Agent 会把新双层事实模型改回旧逻辑的文档矛盾，并把所有活跃验收路径更新为 Her。

## 独占文件

- `AGENTS.md`
- 现有 `docs/development/**`
- `docs/local-development.md`
- `tools/voice-acceptance/README.md`

不得修改 Swift、脚本、Xcode 工程或 `docs/tasks/2026-09-23-her-parallel-gates/**`。

## 必须修正

- “每一步都必须独立验证才能继续”改为：每一步按 code-owned completion policy 判断；delivery-sufficient 直接动作可凭 sent 推进，结果型动作必须独立验证。
- “任何未独立验证动作都进入 uncertain_effect”改为双层事实的准确规则。
- 进度、verified history、satisfied history、userConfirmed 的语义分别写清。
- 活跃验收路径改为 `Her.app/Contents/MacOS/Her`。
- 区分当前文档与历史 evidence log；历史日志不得篡改。

## 验收标准

- 对活跃文档运行检索，不再出现旧产品路径或上述两条旧语义。
- `AGENTS.md` 与 `DesktopActionCompletion` 的真值表逐项一致。
- 文档明确：XCTest 是回归，不是 E2E 完成依据。
- 由一个未参与实现的 Reviewer 只读检查，能仅凭文档正确写出 A/U/C 三个验收预期。
