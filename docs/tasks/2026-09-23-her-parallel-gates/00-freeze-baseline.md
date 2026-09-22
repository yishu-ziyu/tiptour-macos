# 工单 00：冻结 Her 当前可并行基线

## 目标

把当前已保存但未提交的 27+ 文件改动冻结成所有工程 Agent 可以共同引用的本地 commit。此工单不改变任何产品行为。

## 执行人

仅集成负责人执行。其他 Agent 在收到 baseline commit SHA 前不得开始。

## 操作要求

1. 读取 `AGENTS.md` 和当前任务文档。
2. 确认 Xcode 文档 `modified=false`。
3. 确认 `git diff --check` 通过。
4. 重跑当前完整回归与 Xcode 原生 Build。
5. 确认没有 probe、fixture 或临时 Her 进程遗留；正常用户 Her 进程可保留，但必须记录 PID 与二进制路径。
6. 将当前改动形成一个本地基线 commit，建议分支 `integration/her-action-facts-baseline`。
7. 不 squash 历史，不改代码，不自动 push。远程团队确需共享时，先取得用户授权再 push 该集成分支。

## 验收标准

- 工作树干净。
- 生成唯一 baseline commit SHA。
- Xcode 原生 Build succeeded。
- Her 二进制时间不早于所有产品源码。
- 签名为 `com.yishuziyu.her / Team 87DM76C54G`。
- 完整回归、typecheck、diff check 全部通过。
- `out/acceptance/00-baseline/result.json` 记录 SHA、构建结果和测试结果。

## 不允许

- 不修改源码或测试。
- 不把临时 `/tmp` 报告提交进仓库。
- 不在 main 上开启多个写入 Agent。
