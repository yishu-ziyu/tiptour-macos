# 03R：运行器必须在正确进程身份与真实前置条件下验收

优先级 P1。不是改判定让失败变绿，而是使每个 PASS/FAIL/BLOCKED 都有真实来源。

## 本次发现

- 当前 runner 直接 Popen Her Mach-O。该子进程实测 accessibility=false；正常产品是否有权限不能替代这个进程的状态。具体权限差异原因尚未证实。
- browser_stage 用 `lsappinfo front` 输出直接查找 bundle ID，本机输出实际为 ASN；前台等待失败只警告，仍进入执行。
- 新构建的 A/C 已进入供应商/Driver，但缺少必要辅助功能权限；应更早 BLOCKED。
- 用户中断后 finally 清理成功，但 `_finish` 未运行，总 result.json 缺失。
- A/C 的场景预期仍接受 uncertain_effect：这可以记录安全失败，却不能证明“纯点击不再不确定”的成功标准。
- `os_status_code=44` 实际记录的是 security 命令退出码，且存在性查询命名成 keychain_accessible；不得与原生 OSStatus/实际解密成功混为一谈。

## 独占范围

`scripts/acceptance/**`、`tools/voice-acceptance/scenarios/**`、`tools/voice-acceptance/fixture.py`、`TipTour/Voice/VoiceRouteProbe.swift`，必要时新增一个小型 DEBUG preflight 源文件。不改任务业务语义、01R/06R 文件或生产用户权限。

## 实现要求

1. 先核查 macOS 实际调用身份；采用正常签名 App 的受支持启动方式并在目标进程内做只读 preflight。不得通过修改 TCC、reset 权限、sudo、放宽 ACL 或私自签名解决。
2. preflight 记录 bundle/team、DEBUG 能力、PID、二进制标识、所需辅助功能/屏幕权限、前台 app/window/受控页面身份。无所需权限时，供应商调用数=0、Driver 调用数=0。不在无人看守时弹权限窗。
3. 元数据存在、实际可读、供应商认证成功分别记录；原生 OSStatus 与 CLI exit_code 分开。JEV 仅在对应专项中必需，无 JEV 的 StepFun 路径不得全部 BLOCKED。
4. 前台环境不确定、屏幕锁定或页面不是本地 fixture 时停止，不能只警告后继续。后续场景重复核查，不让旧的 foreground 结果长期有效。
5. 只管理本次创建的 probe/fixture。不得按名称杀用户 Her/Safari，不能关闭已有私人标签页；标记本次测试页并只清理它们。
6. 并行编码不意味着并行桌面测试。同机运行器做最小互斥；第二个执行明确 BLOCKED，不能抢占第一个会话。原生构建也由集成人员串行完成。
7. 无论正常、timeout、SIGINT 或异常退出，都写独立可读的总报告。已完成试次逐次原子落盘；中止场景为 aborted/not_run，不从旧输出读出成功。日志和失败证据保留。
8. A 正常完成要求 completed、delivery=sent、delivery_sufficient、正确 completion_basis 与非越权播报；不得接纳 unknown/uncertain 作为该场景 PASS。C 明确要求两步均满足自身策略。
9. 有安全规范化时保留 raw arguments 和 effective plan，按真实用户意图及执行效果判断，不要求错误原始参数必须先被模型完全修好，也不能用 raw 字段替代有效计划约束。
10. 02 的全部实际进度语言矩阵及 04 的 U/R 应纳入明确场景清单；仅 continuity 的 status→cancel 不代表所有进度/恢复情形通过。串联 06R 时采用其独立 UI 证据，不伪造无人操作的“点过保存”。

## 独立验收标准

| 真实路径/故障 | 必须结果 |
| --- | --- |
| 旧二进制、错误身份或无 DEBUG 能力 | BLOCKED；零供应商调用、零桌面副作用；有报告 |
| App 进程缺所需权限/非 fixture 前台 | BLOCKED；不自动改权限；有确切缺项 |
| 已授权的新鲜构建 | A 实际点击一次；回执和播报符合双层事实；目标进程身份写入证据 |
| 两个运行器同时请求桌面 | 后一个拒绝且不干扰前一个；不能串用 state |
| 本次真实 run 被中断或 child 超时 | 总报告仍存在，状态非 PASS；本次所有 child/端口退出；用户 Her 不受影响 |
| 回执丢失 U | 真实动作发生一次，注入生效、unknown、同任务继续后仍只一次；缺 probe/权限为 BLOCKED |
| C 集成 01R | 同一原话 3 连过，加独立改述；保留每个失败/通过试次 |

运行器自测仅验证运行器自身，不替代上表签名 App 和真实桌面路径。通过与否由独立 evidence reader 复核 JSON，不读取被测产品自报的 passed 字段作为唯一依据。
