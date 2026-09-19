# 设计参考（Notion + 本地 skill）

做界面设计时的权威参照来源。不要照搬页面内容，按需取用其中的规范与数值。

## Notion · Apple Design 库

入口：`Apple Design` → `iOS macOS 基础原子`（`20f886bc-60ff-81f3-8653-d4479742b2a7`）。

| 主题 | 页面 | 用途 |
| --- | --- | --- |
| 设计语言总览 | `Liquid Glass - Design language` | 视觉风格统一原则 |
| 结构 | `Liquid Glass - Structure` / `Continuity` | 浮动面板的层级与连续性 |
| 材质 | `Liquid Glass - Structure, Variants and Design Guidelines` | 半透明材质、模糊、阴影 |
| 可读性 | `Liquid Glass - Legibility, Tinting, Accessibility` | **浮层文字可读性首选参照** |
| 色彩 | `iOS 灰度色彩层级` / `iOS色板体系` / `颜色搭配` | 灰阶层级与强调色用法 |
| 字体 | `版式基础知识 UI typography` / `San Francisco font family` / `光学字体的由来` / `动态字体` | 字阶、字重、光学尺寸 |
| 品牌 | `UI Layer and Content Layer Separation` / `Content Layer as Brand Canvas` | UI 层与内容层分离；内容层即品牌画布 |

用 MCP 读取：`notion_notion-fetch`，参数 `id` 传上表 UUID 或 Notion URL；
`notion_notion-search` 按关键词检索。Notion Skills 当前为空。

### 对 TipTour 最相关的三条

1. **UI 层与内容层分离** —— 语音浮层、光标、检测框都是 UI 层，浮在用户内容之上。
   内容层是品牌画布，UI 层应当克制、可中断、不抢焦点。这直接约束 `OverlayWindow`、
   `NekoCursorView`、`DetectionOverlayView` 的视觉重量。
2. **可读性 / Tinting / 无障碍** —— 浮层文字压在任意桌面内容上，必须保证对比度，
   不能依赖固定的浅色背景假设。
3. **颜色克制** —— 强调色只用于交互状态提示，不做装饰。与既有 `DS.Colors` 的用法一致。

## 本地 skill

| skill | 用途 |
| --- | --- |
| `apple-design` | Apple 式流体交互：可中断性、弹簧、材质、反馈四分类。Web 向但原则通用 |
| `write-swift` | Swift / SwiftUI 写法 |
| `ui-skills-root` | UI 相关 skill 索引 |
| `animation-vocabulary` / `animate` / `animate-expo` | 动效词汇与实现 |
| `find-animation-opportunities` / `improve-animations` | 动效改进 |
| `emil-design-eng` / `deep-read-web-design` | 设计工程参考 |

`apple-design` 里三条对语音交互尤其重要：**可中断性是第一原则**（用户说话时必须能
立即反转当前状态，不能等动画播完）；**反馈分四类**（status / completion / warning /
error）；**响应要发生在按下瞬间，而不是抬起**。
