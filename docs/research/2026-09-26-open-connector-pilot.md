# OpenConnector 小范围只读实测

2026-09-26。用户要求主动试用，明确同意范围为 trycua/cua issue #4035、相关 PR，以及 Notion Will's S Design Note 中一个页面；另明确允许本轮临时复用现有 gh 登录凭证。本记录区分真正跑通的路径与仍需用户授权的路径，不把源码阅读或已有连接器的结果当成 OpenConnector 验收。

## 结论

GitHub 路径已通过：真实 OpenConnector 进程经 HTTP 和 MCP 读取目标 issue、PR、评论，结果与独立 GitHub API 回读一致；真实凭证下写请求仍被拒绝，删除临时连接后不能再读。

Notion 路径未通过：真实网关明确返回缺少 Notion 凭证。已有 Notion 插件能读到指定资料页，只证明目标存在且旧连接可用，不代表新网关获得授权。官方连接管理页已打开，但自动控制点击「新连接」未出现表单，已请用户接手这一必要步骤。

本轮不修改 Her 生产代码、全局 MCP 配置、系统代理/DNS、登录项或长期任务。

## 试验对象与边界

- 使用官方 [v1.6.5 发布包](https://github.com/oomol-lab/open-connector/releases/tag/v1.6.5)，对应提交 `c6f55b58f98bae95c14d0848eb612dfa09b80291`，不是上轮研究的 main 快照。
- Apple Silicon 二进制 SHA-256 为 `42df9a5d1bab2a92e9dbf3163364bb07c90eab59ae5adc3426bde613fb1067ee`，与官方 SHA256SUMS 相符；macOS 代码签名验证通过。该检查不等于完整安全审计。
- 临时服务仅监听 `127.0.0.1` 随机端口，使用独立目录、随机管理/运行令牌、随机加密密钥、明确的读动作白名单；provider proxy 全部禁用。
- 未继承模型密钥等应用环境变量。网络适配仅继承用户现有代理变量，并仅为三个已知公网 API 主机配置当前进程的 trusted-host 例外，以兼容本机 fake-IP DNS；未全局放开私网访问。
- 获得用户明确允许后，gh 凭证仅在内存中获取并交给本机临时网关；不输出令牌，不提交或上传到其他服务，不读取 Notion 插件的凭证。

## 实际结果

| 路径 | 观察结果 | 判断 |
| --- | --- | --- |
| 无令牌、错误令牌调用 HTTP | 401 unauthorized | 网关鉴权生效 |
| 运行令牌调用连接管理接口 | 401 unauthorized | 运行权限不能替代管理权限 |
| HTTP 创建 issue 动作 | 400 action_not_allowed | 被本地白名单拒绝；未调用真实写目标 |
| MCP 创建 issue 动作 | JSON-RPC 返回 isError / action_not_allowed | MCP 同样受动作策略限制 |
| provider proxy | 403 proxy_blocked | 未留下绕过动作白名单的 proxy 路径 |
| 无 GitHub/Notion 凭证时执行读动作 | 403 authorization_failed，明确提示 Configure ... credentials first | 不是连接成功或空结果 |
| 配置临时 GitHub 连接 | 实际凭证校验通过，识别已授权 GitHub 账号 | 真实连接成立 |
| HTTP 读 issue #4035、PR #4051、issue 评论 | 全部 200 | 经网关读到真实数据 |
| MCP execute_action 读 issue #4035 | structuredContent.ok=true，内容与 HTTP 相同 | MCP 执行路径成立，不只是目录发现 |
| 独立 GitHub 回读 | 标题、编号、URL、PR 状态/head、评论 ID 一致 | 来源与数据核对通过 |
| 有真实凭证时再尝试写 | 仍为 action_not_allowed | 授权账号未绕过读动作白名单 |
| 删除临时连接后再读 | 404 connection_not_found，无其他账号回退 | 删除生效 |
| 停止试验 | 子进程退出、临时凭证数据库移除 | 未留下后台服务或凭证副本 |

写入拒绝探针使用随机不存在的 owner/repository 作为第二道保护，没有向真实 issue 发评论或创建内容。白名单证明的是本轮配置下的行为，不证明上游每种动作或整个项目均安全。

本轮回读的 PR #4051 为 `draft=true`、`merged=false`，读取到 4 条 issue 评论。不是持续监控结果，后续状态需重新读取。

## 真实踩到的接入问题

1. 系统 DNS 将 `api.github.com` 等公网主机解析到 `198.18.*` 保留网段，默认 SSRF 检查会拒绝。仅配置准确的公网 trusted hosts 后，还需要为临时进程传入现有网络代理才能实际出网。没有改变系统网络设置，也没有关闭证书校验。
2. MCP 客户端只声明 `application/json` 会收到 406。加入 `text/event-stream` 后可用；此次返回的是 SSE 包裹的 JSON-RPC 消息。Swift 接入不能假定 HTTP 200 的正文一定是裸 JSON，也不能把 HTTP 200 当作 Action 成功。
3. 文档示例容易让人以为读公开 GitHub 无需账号；实际 provider/executor 要求凭证，即使上游公开 API 本身支持匿名读。公开信息查询可以直接使用官方 API，不必强行统一经过此网关。
4. `requiredScopes` 元数据不等于本次临时 token 在上游仅有读权限。本轮使用经用户批准的既有 gh 凭证，通过网关动作白名单限制调用；生产接入仍应使用来源方最小权限凭证。

## Notion 的明确剩余步骤

当前已核对的资料样本为「iOS macOS 基础原子」，页面 ID `20f886bc-60ff-81f3-8653-d4479742b2a7`，含动效与 SF Symbols 资料入口。这个核对来自现有 Notion 插件，**不是 OpenConnector**。

新网关需要独立的 Notion integration 或 OAuth 授权。应只开读取内容能力，并明确页面范围；如果选择父页面，要先确认子页面继承权限是否扩大了原定范围。不能直接复制当前插件的登录令牌，也不应借用用户现有较宽权限的 OAuth 应用来省事。

官方管理入口已在浏览器打开：`https://app.notion.com/developers/connections`。原生 AX 点击和页面按钮点击均未打开新连接表单；没有创建新连接、生成 Notion 密钥或扩大页面授权。已请用户手动打开表单，随后才继续收窄权限和实测。密钥不应发到聊天中。

## 证据与复验

- [实际请求及结果](../../out/connector-pilot/run-HLEo4X/evidence.json)
- [独立读回与保护检查](../../out/connector-pilot/run-HLEo4X/verification.json)
- [试验脚本](../../out/connector-pilot/probe.mjs)、[结果核验脚本](../../out/connector-pilot/verify.mjs)

这些文件在本机 `out/`，不入 Git。`--with-github` 会读取现有 gh 凭证，未来重新运行前仍需确认该次临时转交得到授权。默认不带该参数可复验无用户凭证的鉴权与拒写路径。

当前建议：OpenConnector 可作为多数据源授权与调用层候选，GitHub 的实测已支持这一判断；Notion 不标记为已接通。在凭证存储、生命周期与 macOS Keychain 边界没有确定前，不把整个运行时并入 Her。
