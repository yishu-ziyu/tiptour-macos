# 工单 03：建立 Her 一键真实路径验收运行器

## 目标

把当前散落的手工命令收敛为一个可重复运行、自动清理、输出结构化证据的 Her E2E runner。它不修改产品行为。

## 独占文件

- 新增 `scripts/acceptance/**`
- `tools/voice-acceptance/fixture.py`
- 可新增 `tools/voice-acceptance/scenarios/**`

不得修改任何 `TipTour/**/*.swift`、`AGENTS.md` 或 Xcode 工程。

## 运行入口

建议：

```bash
python3 scripts/acceptance/her_voice_e2e.py \
  --app "/.../Debug/Her.app" \
  --out out/acceptance/03-her-e2e
```

## 必须自动检查

- App 为 `Her.app`，Bundle ID `com.yishuziyu.her`，Team ID `87DM76C54G`。
- 二进制不早于产品源码；否则 BLOCKED，不能拿旧进程验新代码。
- Keychain 只检查存在性和可访问状态，不输出 secret。
- 启动/停止 fixture，重置 `/state`，准备 Safari，运行 probe，读取报告，清理 probe 与 fixture。
- 不杀正常用户 Her，除非用户显式授权；探针使用独立进程并自行退出。

## 场景

Runner 至少支持：

- A：单步“点击右边的设置按钮”。
- C：两步“点击打开显示设置，然后点击缩放选项”。
- Continuity：查询进度，重连后取消同一任务。
- Unknown：由工单 04 提供的真实故障注入场景。

03 可在 01/04 未合并前开发，但最终 PASS 必须在集成分支重跑。

## 证据判定

每个场景必须同时比较：

```text
用户原话
模型工具参数
Her receipt
独立 /state
最终播报
进程退出与清理
```

以下均不能单独判 PASS：退出码 0、工具返回 completed、模型说完成、页面任意变化、日志出现 PASS。

## 验收标准

- 一个命令可以从空闲环境完成全部场景。
- 失败时保存最小证据并退出非零。
- 成功时写 `result.json`，其中每个场景有独立 PASS 和依据。
- 连续运行两次结果一致，第二次无端口占用、残留进程或旧 `/state` 污染。
- 不保存用户私人音频、屏幕截图或 API key。
