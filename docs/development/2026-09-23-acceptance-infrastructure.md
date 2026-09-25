# 2026-09-23 真实用户路径验收基础设施

状态：已合入 `integration/her-action-facts-baseline`（`54bc69b` 之后）。本文是活的约定文档；
历史尝试记录见同级日期日志。凡与代码冲突，以代码与 `AGENTS.md` 为准。

## 为什么建这套东西

返修轮真实 E2E（`out/acceptance/integrator-20260923-0615/`）暴露的三个失败全是基础设施形状：
探针进程身份导致辅助功能不可用、机器环境未受控、provider 参数形状漂移只在真实调用中可见。
结论：验收必须贴近真实用户路径（真实入口 → 真实 provider/执行器 → 受控桌面 → 独立状态读回 →
回执与语音 → 故障恢复），且判定必须独立于产品自报。

## 已建成（全部后台安全，不触碰前台）

| 组件 | 位置 | 作用 |
| --- | --- | --- |
| 受控宿主 App | `tools/cua-host/`（bundle `com.yishuziyu.her.cua-host`，:19476） | 已知 bundle ID、可命名控件（左右同名「设置」、「打开显示设置」→「缩放选项」、输入框、菜单、二级窗口），自带 `/state` 独立读回。`swift build` + `tools/cua-host/scripts/package-app.sh` 构建，**不自动启动** |
| 一键验收运行器 | `scripts/acceptance/her_voice_e2e.py` | 身份/新鲜度门禁 → 机器预检 → LaunchServices 启动 DEBUG Her（`-n` 新实例，不碰用户 Her）→ 合成 PCM 语音探针 → 真实链路 → 六层证据。退出码 0/1/3/4/130；任何终止路径都写总报告 |
| 机器预检 | `runner/machine_preflight.py` | 只读：端口、用户 Her 进程记录、二进制新鲜度、前台身份（ASN 解析）、锁屏；不可证明即不通过 |
| 独立证据复核 | `scripts/acceptance/verify_evidence.py` | 从证据包独立重推 PASS/FAIL，不信任产品 `passed`；接受 completed+逐项佐证 / 诚实 uncertain / cancelled+绑定有效且无未解释副作用 |
| 人工引导器 | `scripts/acceptance/manual_runner.py` | 人机回路场景：打印步骤→等人操作→机器独立验证（security 退出码、/state、ps 只读）；自身从不点 UI |
| 对话脚本 schema | `runner/conversation_driver.py` | 多轮 + 打断的脚本契约（turns: text/wait_ms/barge_in/expect）；3+ 轮与打断的应用侧探针待 Xcode 重建后补 |
| 形状监控/契约磁带 | `runner/provider_shapes.py`、`cassettes/` | 记录真实工具参数形状（action+steps 混用、结果句式 expected_label、拒绝原因）；磁带重放固定 `acceptance:false`，永不可冒充 E2E |
| 运行器侧故障原语 | `runner/runner_faults.py` | 只作用于本次创建的 fixture 子进程的终止/陈旧状态窗口；武装需具名 `authorized_by`；页面导航故障永不自动执行 |
| AX 工具链 | **未入库**：tools/ax-probe（`com.yishuziyu.her.ax-probe`）在任何分支上都没有提交（2026-09-23 核对），下列行为只是计划 | 只读快照另一 app 的 AX 树；`type-into` 仅在有用户创建的授权令牌时可用；无模式激活/聚焦任何 app |

## 使用方式（开发日常）

1. 改产品代码 → `bash scripts/acceptance/run_self_tests.sh` + 隔离回归套件（后台安全）。
2. 需要真实桌面证据 → 先跑 `runner/machine_preflight.py`；只有 verdict=ready 且**用户明确许可前台窗口**时，
   才运行 `her_voice_e2e.py`（它会自行完成 LaunchServices 启动、互斥、清理）。
3. 拿到 `out/acceptance/<id>/result.json` 后，用 `verify_evidence.py` 独立复核，不读产品自报 passed。
4. 人机回路（设置/钥匙串）用 `manual_runner.py`；它记录人的主张与机器事实两栏。

## 已知待办（诚实清单）

- 集成二进制陈旧（80+ 源文件新于 DerivedData 二进制）：真实桌面 E2E 待用户在 Xcode 重建后执行；
  重建后还应补齐：多轮对话探针（应用侧）、provider 断连/延迟类 app 侧故障缝。
- `harness /v1/act` 的字面区域约束已修（`TipTourEngine.swift`），真实验收（"右边的设置按钮" 落 right-setting）待前台许可窗口。
- AX 工具链要对 Her 面板做实操，需用户授予 AXProbe 辅助功能权限（用户动作，工具不自行索取）。
- 工单 07（统一任务事实权威）仍按用户裁决封存，待本轮门禁真实通过后另行启动。
