# Her 协调架构研究

2026-09-26。目的：为用户已确认的「统一协调、分开执行」找机制与反例，不增加执行运行时。当前实现以 [架构总览](../architecture/README.md) 为准。

## 结论与证据边界

Her 应让用户持续面对一个伙伴，由她保留项目、来源、授权、任务与待决定事项。执行器只收到完成当前任务所需的上下文。统一协调不等于共享一个无限增长的聊天记录，也不等于让所有工作经过同一个桌面执行器。

这是针对 Her 场景的判断，不是对竞品内部实现的断言。研究区分：官方说明、真实界面观察、固定版本源码、社区重建代码、我们的推论。未安装或运行以下三个代码仓库，也未验证其完整运行路径。

| 对象 | 本轮证据 | 不能据此声称 |
| --- | --- | --- |
| Grok Bot | 官方设计/使用文档；本机 0.58.0 只读界面、Bot 设置、例行任务入口及电脑预览 | 已验证真实任务执行、私有服务端队列或完整记忆机制 |
| Today | 官方说明；已有实测记录 | 官方全部记忆/电脑能力均已在本机验收 |
| Incredible | 官方使用文档；已有设置/付费入口观察 | 已越过订阅限制执行真实任务 |
| OpenMausBot / OpenMuse | 固定提交的关键调用路径静态阅读 | 已验证其运行可靠性、性能与部署安全 |
| Grok Bot 0.18 reconstructed | 作者声明、NOTICE、重建代码 | 官方开源、完整源码泄露、当前 0.58 架构 |

Today 与 Incredible 的真实体验边界见 [原研究记录](2026-09-26-today-incredible-experience.md)。本轮 Grok Bot 电脑预览最终显示了远端桌面，但没有发消息或操作远端电脑；只能证明预览可见，不能将旧连接故障标记为完整恢复。

## 三款产品：先学用户责任，再学机制

### Grok Bot

长期存在的 Bot 承载记忆与例行任务，聊天只是交互入口；协调者可以分派专业工作，用户不必逐个管理执行者。工具/技能按账户共享，记忆/例行任务按 Bot 组织，群组可共享项目上下文。这支持 Her 的单一伙伴方向，不要求照搬多个可见人格。[设计说明](https://x.ai/news/designing-grok-bot)、[协作说明](https://docs.x.ai/grok-bot/chat-and-collaboration)

必须修正一个容易误读的点：较早设计文章将电脑描述为 Bot 自己的电脑，但具体使用文档说明账户共享云电脑，各 Bot 有自己的屏幕，文件、cookies 与 CLI 凭据仍共享，屏幕不是安全隔离边界。Her 操作的是用户正在用的 Mac，更不能拿云端独立屏幕替代本地输入协调。[电脑与应用](https://docs.x.ai/grok-bot/computer-and-apps)

学习：长期身份、任务内的产物/进展、渐进展开的执行可见性。保留边界：停止不等于撤销，消息到达不等于授权扩张。官方材料没有公开完整服务端调度与恢复算法。[概览](https://docs.x.ai/grok-bot/overview)、[协作说明](https://docs.x.ai/grok-bot/chat-and-collaboration)

### Today

官方将长期任务、记忆检索、队列与同步一起讨论；主动性围绕用户仍能采取行动的时机，而非尽可能多地播报。我们应学「这件事与你有什么关系、现在是否需要决定」的筛选，不仅学晨报外观。[What is Today](https://today.ai/articles/blog/what-is-today)、[Meet Today](https://today.ai/articles/blog/meet-today)

记忆总结不应取代原始来源；过去的选择也不应永久冒充当前决定。把这个关系用于项目进度、收藏与素材即可，不引入录音管线。[Recording 设计说明](https://today.ai/articles/blog/introducing-today-recording)

### Incredible

官方区分日常偏好记忆与显式 Knowledge：后者按名称/描述匹配，再读取内容。Task 汇集对话、操作、产物和活动，并区分 Working、Needs you、Upcoming、Done；离开交互后转为较安静的反馈方式。[Knowledge](https://www.incredible.one/learn?section=knowledge)、[Tasks](https://www.incredible.one/learn?section=tasks)、[使用说明](https://www.incredible.one/learn?section=using-incredible)

Autopilot 以 Whenever/Then 表达条件动作，文档描述定期检查连接的应用，并提供 Run now、Issues 与停用入口。不能把它推断成全屏持续监控或恰好执行一次的事件系统。[Autopilot](https://www.incredible.one/learn?section=autopilot)

学习：把任务及待用户决定的事项做成可返回的对象；把主动触发条件表达清楚。未知：完成谓词、取消与副作用处理、并发桌面输入协调。用户已决定本轮不订阅，不再尝试结账。

## OpenMausBot：委派不只是调用另一个模型

固定版本：`6cffdd7b3afa82b3d08f584039536762e73fb94a`。[仓库](https://github.com/milind-soni/OpenMausBot)

- Bot 长期存在，Task 保存线程与恢复游标。经典 `delegate_bot` 队列与 `RoomHandoffs` 父子任务树是两套机制，不应笼统称作统一状态机。[任务存储](https://github.com/milind-soni/OpenMausBot/blob/6cffdd7b3afa82b3d08f584039536762e73fb94a/server/store.ts#L2328)、[委派](https://github.com/milind-soni/OpenMausBot/blob/6cffdd7b3afa82b3d08f584039536762e73fb94a/server/delegations.ts#L25)、[父子任务](https://github.com/milind-soni/OpenMausBot/blob/6cffdd7b3afa82b3d08f584039536762e73fb94a/server/room-handoffs.ts#L6)
- 请求键、祖先关系、预算和重做边界限制互相转派；消息保留来源，不能把其他 Bot 的话当成新的用户授权。[交接](https://github.com/milind-soni/OpenMausBot/blob/6cffdd7b3afa82b3d08f584039536762e73fb94a/server/room-handoffs.ts#L167)、[来源](https://github.com/milind-soni/OpenMausBot/blob/6cffdd7b3afa82b3d08f584039536762e73fb94a/server/peer-provenance.ts#L34)
- 恢复区分请求是否已被接收：接收前可重试，接收后状态未知时不能盲目重放。这比「报错就再跑一次」更适合会改变用户环境的工具。[恢复判断](https://github.com/milind-soni/OpenMausBot/blob/6cffdd7b3afa82b3d08f584039536762e73fb94a/server/resume-recovery.ts#L19)

批判：

1. 完成状态仍可来自 `turn.completed.event.ok` / `runner.ok`，不等于独立检查用户目标已经达成。[事件处理](https://github.com/milind-soni/OpenMausBot/blob/6cffdd7b3afa82b3d08f584039536762e73fb94a/server/index.ts#L6523)、[子任务完成](https://github.com/milind-soni/OpenMausBot/blob/6cffdd7b3afa82b3d08f584039536762e73fb94a/server/room-handoffs.ts#L356)
2. `stopAwaitingDirect` 取消排队的子任务，但允许已运行的队友继续并保留结果，不再唤醒已停止的父任务。它表达「不再等待」，不能直接映射成 Her 的「停止所有相关执行」。[停止语义](https://github.com/milind-soni/OpenMausBot/blob/6cffdd7b3afa82b3d08f584039536762e73fb94a/server/room-handoffs.ts#L287)
3. 重启时 Room 中非终态节点会失败，经典队列持久化也不等于所有运行中交接均可恢复。Auto 回退本机也不能替代用户对执行位置的授权。[重启](https://github.com/milind-soni/OpenMausBot/blob/6cffdd7b3afa82b3d08f584039536762e73fb94a/server/room-handoffs.ts#L52)、[本地路由](https://github.com/milind-soni/OpenMausBot/blob/6cffdd7b3afa82b3d08f584039536762e73fb94a/server/local-routing.ts#L5)

## OpenMuse：任务、尝试与批准分别存续

固定版本：`205cc386b75aae1a862f3fdd43104b570c8d0911`。[仓库](https://github.com/CopilotKit/openmuse)

- 聊天运行与已委派任务分开：关闭聊天流可以中止本次对话，后台任务由 worker 持续执行。UI 不是任务生存的唯一位置。[对话生命周期](https://github.com/CopilotKit/openmuse/blob/205cc386b75aae1a862f3fdd43104b570c8d0911/apps/server/src/engine/conversation.ts#L169)
- 数据库条件更新、租约及尝试编号控制领取与回写。取消清除租约后，旧 worker 不能回来把任务改成成功。[worker](https://github.com/CopilotKit/openmuse/blob/205cc386b75aae1a862f3fdd43104b570c8d0911/apps/server/src/engine/worker.ts#L116)、[checkpoint](https://github.com/CopilotKit/openmuse/blob/205cc386b75aae1a862f3fdd43104b570c8d0911/apps/server/src/engine/service.ts#L826)
- 批准绑定具体动作、账户、目标和连接版本，执行前校验并原子领取。崩溃恢复时，原先正在执行的动作标成 `outcome_unknown`，不自动重发可能已经成功的外部动作。[批准](https://github.com/CopilotKit/openmuse/blob/205cc386b75aae1a862f3fdd43104b570c8d0911/apps/server/src/actions.ts#L66)、[恢复](https://github.com/CopilotKit/openmuse/blob/205cc386b75aae1a862f3fdd43104b570c8d0911/apps/server/src/db.ts#L91)

批判：

1. 通用 `finish_task` 仍允许模型提交总结；`finish()` 在所有权检查后将任务及计划步骤标记成功，没有独立验证具体用户目标。这种终态不能照搬。[模型工具](https://github.com/CopilotKit/openmuse/blob/205cc386b75aae1a862f3fdd43104b570c8d0911/apps/server/src/engine/model.ts#L255)、[finish](https://github.com/CopilotKit/openmuse/blob/205cc386b75aae1a862f3fdd43104b570c8d0911/apps/server/src/engine/service.ts#L817)
2. 拼入原始请求、最新回答、全部记忆和先前状态，不等于相关记忆检索，也不等于完整对话连续性。[任务提示](https://github.com/CopilotKit/openmuse/blob/205cc386b75aae1a862f3fdd43104b570c8d0911/apps/server/src/engine/model.ts#L276)
3. 无网络容器的执行边界不等于用户 Mac 的权限与焦点边界；取消也不能撤销已经批准并发生的外部副作用。[computer](https://github.com/CopilotKit/openmuse/blob/205cc386b75aae1a862f3fdd43104b570c8d0911/apps/server/src/computer.ts#L465)、[项目限制](https://github.com/CopilotKit/openmuse/blob/205cc386b75aae1a862f3fdd43104b570c8d0911/README.md#L132)

## 用户指定的 Grok Bot 重建仓库

准确对象：[b-nnett/grok-bot-0.18-reconstructed](https://github.com/b-nnett/grok-bot-0.18-reconstructed)，固定版本 `a9f633e09d49a85829b8236331b9e21f7e612634`。页面显示 2026-08-28 已归档。

这不是已证实的「官方完整源码泄露」。作者将其定义为基于发布二进制的非官方重建与扩展；模块命名和边界可能是推断。它保留发行版压缩 renderer 作为构建输入，`frontend/` 只是部分重建，不是原始 React 源码。Provider Router、本地用量、Docker 与 Router 设置属于作者增加的实验，不能反推官方 0.18 的原有能力。[README](https://github.com/b-nnett/grok-bot-0.18-reconstructed/blob/a9f633e09d49a85829b8236331b9e21f7e612634/README.md)

NOTICE 明确没有授予上游源码许可。我们只研究机制，不将其实现复制进 Her。PROVENANCE 的来源/hash 为作者声明，本轮未重新下载发行包校验；它也没有证明完整云端队列、记忆与资源调度实现公开。[NOTICE](https://github.com/b-nnett/grok-bot-0.18-reconstructed/blob/a9f633e09d49a85829b8236331b9e21f7e612634/NOTICE.md)、[PROVENANCE](https://github.com/b-nnett/grok-bot-0.18-reconstructed/blob/a9f633e09d49a85829b8236331b9e21f7e612634/PROVENANCE.md)

实际值得读的两处：

- control/data/mainData 通道及 gateway 事件分流，将连接状态、对话流、Agent 活动和客户端工具分开处理。可借鉴职责划分，不能把它当作完整服务端协调系统。[carrier](https://github.com/b-nnett/grok-bot-0.18-reconstructed/blob/a9f633e09d49a85829b8236331b9e21f7e612634/source/node-agent-coordinator/carrier.ts#L93)、[coordinator](https://github.com/b-nnett/grok-bot-0.18-reconstructed/blob/a9f633e09d49a85829b8236331b9e21f7e612634/source/node-agent-coordinator/main.ts#L102)
- `healthEpoch` 让旧连接的迟到结果失效，防止旧连接覆盖新连接。其证据范围是连接生命周期，不是所有任务取消、工具副作用去重都正确。[host-supervisor](https://github.com/b-nnett/grok-bot-0.18-reconstructed/blob/a9f633e09d49a85829b8236331b9e21f7e612634/source/node-agent-coordinator/gateway/host-supervisor.ts#L93)

## 对 Her 的具体判断

以下是建议，除统一协调边界外尚未作为实现决策落地：

| 要保留的事实 | 用户可感知的结果 | 不接受的替代方案 |
| --- | --- | --- |
| 项目、来源、当前目标与长期偏好分开 | 她知道「那个项目」指什么，并能带回原出处 | 每个执行器塞入同一份全部历史 |
| 同一任务下区分每次执行尝试 | 收起再回来仍是同一件事，失败可解释、可恢复 | 新一轮模型调用就当作新任务 |
| 批准绑定目标、动作和版本 | 你批准 A，不会因为切到 B 就执行 B | 对旧草稿的确认被重新解释 |
| 操作结果、验证证据和待用户决定分别保存 | 她能说明做了什么、证实了什么、还等什么 | 模型说 done 或出现 diff 就宣布完成 |
| 来源变化、关联目标、通知时机分别判断 | 既跟进旧事，也带来相关发现，而且不抢注意力 | 每次检测到变化都弹窗或朗读 |
| 语音、等待、执行、撤销分别控制 | 「先别说话」不会误杀任务；「停止操作」有真实回执 | 一个 stop 布尔值承担所有语义 |

Her 当前语音与文字上下文分离；任务归属分散；文字会话能跨面板收起保留，但不能跨 App 重启；素材回忆和主动更新仍主要是交互原型。桌面步骤验证和 git 回执是基础，不代表所有入口已统一验证：例如 JEV 的模型 done 路径仍需在跨入口整合时审查。

因此下一步不是重写整个 runtime，而是选一个真实任务，让项目绑定、授权、执行身份、证据和待决定状态贯穿原生入口。先让这一个任务在收起、追问、失败、返回时不丢失，再把共同事实接到其他入口。记忆检索与主动发现并行设计，但不伪装成已实现功能。

## 本轮落地与验证

- 已修复草稿绑定：形成草稿时的项目不会因最近项目变化而漂移；无项目草稿不偷偷采用后来的项目。
- 已保护待决定改动：未合并/丢弃之前不接受另一份草稿覆盖入口；追问、模型失败、屏幕任务和新对话仍保留原改动的决定。
- 实现局限：仅现有文字委派会话内保护，不是全局任务协调或持久化；项目发现仍是最近 Claude 项目，不是完整项目选择器。
- 执行器完整隔离套件在项目绑定修改后通过；后续状态保护修改完成后重新通过 `scripts/test-delegation.sh --filter DelegationSessionTests`。真实临时 Git 仓库回读，模型和 Claude 进程替身；不是模型自评。
- 未在 Xcode 构建/启动新版本，未使用真实 provider 或执行真实 Claude 任务，原生用户路径尚未验收。测试增长用于覆盖项目切换、缺失绑定、合并/丢弃及失败恢复结果，没有引入新执行器或通用框架。
