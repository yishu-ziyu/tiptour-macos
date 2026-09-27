# Today 与 Incredible：回忆、上下文与行动

2026-09-26 的研究记录。用户要求调研并实际使用两款 macOS 应用，理解其吸引力与设计理念，为 Her 的意义提供依据。本文记录观察与假设，不改变现有产品方向或路线图。

## 用户要找回什么

用户希望在浏览器以及 Claude Code、Codex、Cursor 的工作过程中，通过和 Her 沟通，找回之前的项目名字、过程、展示截图、运行过程，以及看过的好帖子、动效、网站、库和开源来源。

用户已确认：希望减少反复解释、安排任务、照看进度，同时有一个持续理解自己生活和工作的伙伴。

本次判断：需要检验的结果是从模糊线索回到可核对、可打开、可继续使用的材料。仅说出项目概况，或记住用户对动效感兴趣，还没有完成这个结果。

## 样本与方法

| 项目 | 本次事实 | 证据边界 |
| --- | --- | --- |
| Today | 从 1.19.5 / 2000120 更新为 1.20.3 / 2000139，正常重启；已有用户账户、项目记忆和数据连接 | 两条文字查询实际完成；未测试真人语音或电脑执行能力 |
| Incredible | 官方下载包 0.2.36，已安装到 `/Applications/Incredible.app`；签名和公证检查通过 | 用户完成引导后进入 Checkout 等待；本轮决定不订阅，实际任务尚未测试 |
| 操作方法 | 优先 ChatGPT 原生电脑控制，读取无障碍树并交叉查看截图 | 控制工具错误与产品回答分开记录 |
| 外部核对 | 官方网页、安装包静态检查；独立查询一个 GitHub PR | 没有逐条审计 Today 返回的全部项目事实 |

两款应用的账户数据条件不同，不能用目前结果排名：Today 已有用户记忆，Incredible 刚完成引导，尚未进入可执行任务的主界面。

## Today 的实际体验

### 信息与界面

- 左侧聊天保持可见，右侧可以打开今天、任务、记忆和角色页面。切换到记忆、项目目录、项目概览时，仍能在左边继续聊天。
- 记忆页包含关于用户的概览和 Projects、Work、Interests 等分类。
- Projects 的 `active-overview` 页面列出了多个真实项目，标注 GitHub、Notion、邮件等来源类别。该页的概览日期是 9 月 22 日，不能直接当成 9 月 26 日的最新进度。
- 该生成记忆页底部显示不可直接编辑；本次没有测试通过聊天纠正或删除它。官网声称记忆可管理，不能据此假设每个页面都能直接编辑。
- 早晚简报把项目变化、待办与外部信息放在一个时间线里。这里只确认这种组织方式存在，未核验其中所有新闻、提醒及紧迫性判断。

### 测试 T1：模糊描述找回项目

实际发送的查询如下。原生控制的中文输入和粘贴遇到问题，因此最终使用英文输入、要求中文回答；不能把它计为中文输入体验测试。

> Please answer in Chinese. Help me recall my project using multiple AI agents to fact-check information. Find its name, progress, site or repository links, and any screenshots or demo. Cite sources and dates. Read only; do not modify projects or memories.

结果：

- Today 找回「红鲱鱼与枪 / red-herring-and-gun」，给出仓库与线上地址、定位和开发进度。
- 界面显示了检索活动摘要，并返回中文回答。
- 独立查询 GitHub，确认其提到的 [PR #89](https://github.com/yishu-ziyu/red-herring-and-gun/pull/89) 确实在 2026-09-17 合并，标题为修复 ReportComposer 卡住时的调查收束。此核对只支持这一项进度事实。
- 未交付截图或 demo。它说发现了该仓库的设计文档目录，但没有继续读取里面的内容。
- 回答中的仓库与网站地址显示为普通文本，本次没有获得一组可直接点击的来源卡片，也没有验证打开线上项目的后续路径。

判定：项目身份与部分进度找回成功；从回忆到视觉材料、原始来源及继续工作的路径只完成了一部分。

### 测试 T2：找回看过的动效和设计来源

实际查询：

> Continue in Chinese: find animation or UI design posts and open-source libraries I previously saved or discussed. Give actual titles, original URLs and evidence of my prior encounter. No new recommendations. Say if not found. Read only.

结果：

- Today 明确回答没有找到具体帖子或库。
- 它称已查记忆文件和过去 30 天对话，只有一条“关注动效/动画”的概括性记忆，没有标题、URL 或库名。
- 它随后要求用户提供 Notion 页面、书签或邮件等更具体位置；本轮没有自动延伸到那些来源。

独立检查发现，用户的 `Will's S Design Note` 中确有 [SF Symbols 与其他动效条目](https://app.notion.com/p/20f886bc60ff81f38653d4479742b2a7)，本机 `/Users/mahaoxuan/Documents/design-notes/living/INDEX.md` 也列有 GSAP、侧栏动效等实际样本。这证明材料存在，但不能据此推断 Today 已获得同样的本机访问权限或索引范围。

判定：本次查询未完成来源找回。Today 如实表达了缺失，没有以新推荐替代历史记录；缺口可能涉及数据覆盖、搜索范围或继续检索策略，尚未逐层定位。

### 理念与观察的对应

Today 官方强调持续上下文、可检查的记忆、克制的主动提示和连接应用后的行动。实测中，已有的项目概览和同一对话里的后续追问体现了部分连续性；截图、历史设计原文和一键回到来源仍是本次证据的空白。[官方产品说明](https://today.ai/articles/blog/what-is-today)

## Incredible 的研究

### 官方理念与行为承诺

- Vibe Computing 把表达结果、判断结果质量留给用户，把具体操作交给软件。其“导演”比喻是产品主张，并不是能力验收结论。[原文](https://www.incredible.one/vibe-computing)
- Knowledge 的条目包含名称、用途描述与内容，可以口述或在应用中维护，并按任务选择相关条目。文档不等于自动保存所有浏览经历的承诺。[Knowledge](https://www.incredible.one/learn?section=knowledge)
- 任务历史按日期和状态组织，可以查看对话、结果、活动记录并继续追问。[Tasks](https://www.incredible.one/learn?section=tasks)
- 浏览器扩展使用标记过的代理标签页，在用户自己的登录环境工作。[Browser](https://www.incredible.one/learn?section=browser)

这些需要登录后实测。尤其要区分“知道当前屏幕”和“记得以前见过的屏幕”。

### 本机安装与启动

- 安装包是用户下载的 `Incredible Installer.dmg`，来源元数据指向 `releases.incredible.one` 和 `www.incredible.one`。
- 包内 App 的 bundle ID 为 `one.incredible.new`，版本 0.2.36，支持 arm64 与 x86_64；签名者为 Norditech AB，Gatekeeper 返回已公证且接受。
- 发现已有实例从 macOS App Translocation 临时路径运行。应用提示该位置无法自更新，需要移入 Applications。
- 应用随后记录移入 `/Applications/Incredible.app` 并自行重启；新进程路径和 `can_self_update=true` 已核对。
- 实际看到欢迎与邮箱登录页。继续操作涉及首次账户与服务条款，已请用户在应用内完成；未代为接受条款。用户随后提供了权限引导截图，说明流程已推进到设置阶段。
- 登录前日志显示辅助功能尚未授权。没有因此替用户开启屏幕、麦克风或辅助功能权限。

### 试用入口与本轮停止点

- 用户完成设置后，界面显示 Setup progress 100% 和 Ready when you are，随后转到 Finish in your browser，要求等待 Checkout 完成。浏览器中确有 Norditech AB 的 Stripe 结账标签页。
- 用户明确选择本轮不订阅、保留研究。没有代为提交订阅、填写卡号或付款。
- 随后核对 [官方定价页](https://www.incredible.one/pricing)：其 FAQ 明确承诺 14 天完整 Pro 试用，无需预先提供支付卡，结束后不自动转付费。页面的 Free 标为 14 天，并非永久免费档。
- 官方承诺与本机这次进入 Checkout 的现象尚未对上。结账标签页后来已关闭，未读到表单必填项，不能据此声称绑定银行卡必需，也不能宣称免卡试用在这个账户已跑通。
- 原因可能涉及入口或账户流程，但本次没有证据定位原因；不以猜测填写结论。Incredible 的实际任务测试停在这里。

### 用户认可的权限引导

用户明确指出这个设置面板值得 Her 学习。原始截图保存在 [本机研究证据](../../out/research/2026-09-26-incredible-permission-onboarding.png)（`out/` 不入库）。

- 以能力解释权限：听见用户和使用应用、替用户点击输入、看见屏幕。
- 三步可见，当前步骤展开，其余步骤保持简短；等待状态与帮助入口就在当前步骤内。
- 右侧展示系统弹窗示意和下一步动作，减少在应用与系统设置间切换时的理解负担。
- 截图同时显示一个具体偏差：真正弹出的是 Finder 控制授权，示意图却仍是麦克风授权。Her 借鉴时应让引导与当前权限类型对应。
- 认可的是逐步引导方式；界面底部的本机存储或认证声明，需要按 Her 的实际数据路径另行核实，不能连同样式照搬。

### 静态证据的边界

0.2.36 包含 `accessibility-helper`、`incredible-screenrec`、Python runtime，以及本地唤醒相关模型。这些只能证明组件存在。

主程序中仍能找到以下字符串及编译路径痕迹，不能当成已运行的结果：

| 范围 | 0.2.36 的静态线索 | 未验证的部分 |
| --- | --- | --- |
| Knowledge | KNOWLEDGE.md、读写接口、文件存储、同步、排序和监听组件名称 | 本次账号的实际内容、存储位置和同步效果 |
| Demonstrate | 教学录制开始、停止与事件汇集接口；事件、口述、字幕和视频产物名称 | 录制是否完整，页面变化后回放是否可靠 |
| 浏览器与反馈 | WebSocket 桥接、原生认证、任务卡更新、状态浮层与光标轨迹接口 | 实际操作成功率、是否打扰用户、完整的任务恢复 |

本次没有发现独立打包的旧版浏览器扩展脚本，不能直接延用旧扩展的事件过滤与标签页归属细节。旧样本的机制研究见 [Incredible 架构重建](incredible-reconstruction.md)。

## 可以学习的设计原则

以下是研究推断，尚未成为 Her 的新决策：

| 观察 | 对 Her 有价值的检验 |
| --- | --- |
| Today 把聊天与可展开资料放在同一窗口 | 用户查来源时，能否保留对话与当前任务上下文 |
| Today 的项目记忆有用，但动效来源未找回 | 每条相关记忆是否能追溯原帖、文件、截图和发生时间 |
| Incredible 围绕结果组织请求和任务后续 | 用户只记得一个场景时，能否带回原材料并继续工作 |
| 两家都提供持续上下文的表达 | 记忆更新、过期与不确定性是否可见，用户能否纠正 |

用户设计库中的 [UI 层与内容层分离](https://app.notion.com/p/380886bc60ff8059a855d1b1fef07582) 提供一个合适约束：导航和操作保持熟悉，表达与定制集中在核心内容。对 Her 来说，找回的项目、网页和截图应当成为主要内容，常驻状态界面帮助定位，不盖过资料。

## Factory 案例核对

用户提到的研究可对应 Factory 2026-08-27 的 [What it Takes for Coding Agents to Complete Large Software Tasks](https://factory.com/news/what-it-takes-for-coding-agents-to-complete-large-software-tasks)。它让模型运行参考程序、观察行为，从头重建功能；禁止读取、反编译或追踪参考程序，也不能访问测试或互联网。

报告中 GDAL 的行为一致度由单代理 36% 提升到独立验收角色参与后的 90%。每个条件只运行一次，计算投入也未配平。因此它支持学习“先建立独立的可观察完成标准”，不能作为 UI 还原度或普遍成功率的证明。

## 电脑控制对照

- 原生控制完成了 Today 更新、记忆页导航、两条查询和结果读取，也识别了 Incredible 首次登录页。
- 期间出现过截图错误、隐藏窗口、输入回读延迟和剪贴板问题。输入后必须核对实际内容，不能按调用成功就认定已发送。
- `axstream` 宏库为空；其 MCP 读取报会话已结束，CLI doctor 则正常。它没有完成同条件的点击与输入试验。
- `cua-driver` 的独立窗口读取有助于核对原生观察，但没有开展配平的时间或准确率测试。

结论仅限当前任务：继续按用户要求优先原生控制，保留工具回退；没有证据宣布其中一套普遍更准确。

## 尚待完成

1. 本轮按用户决定不订阅。以后若免卡试用入口得到确认并成功启用，再核对 Incredible 的 Knowledge 与任务入口，运行对应查询。
2. 对两家分别验证“打开找到的来源”和“取回截图/演示”，不能把文字地址当完成。
3. 在明确授权的受控素材上比较一次当前网页读取与任务后续，记录已连接的数据范围，不以不同账户条件作排名。
4. 真人语音、跨日记忆可靠性、持续屏幕历史、浏览器执行与失败恢复尚未验证。
