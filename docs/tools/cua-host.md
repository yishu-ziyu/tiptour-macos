# CuaHost — 受控桌面宿主 App（Her 真实 E2E 用）

Paths in backticks are relative to `tools/cua-host/` unless they start with a top-level directory. Moved from `tools/cua-host/README.md` on 2026-09-23; that file now only points here. Index: [docs/README.md](../README.md).

Her 的真实端到端验收需要一块**受控桌面**：一个 bundle ID 已知、带可命名控件、并且**自带独立状态读回服务**的测试宿主 App。
CuaHost 就是这块桌面。它由真实 CUA 驱动点击 / 输入 / 菜单，并由它自己进程内的
`GET /state` 证明副作用 —— 不截图、不猜像素。

控件语义与网页版受控页 `tools/voice-acceptance/fixture.py` 对齐（同名的「设置」
左右各一个、「打开显示设置」→「缩放选项」），并在其基础上原生增加了备注输入框、
一个真实的菜单命令和一个可打开的二级窗口。

> 本目录只交付骨架与打包脚本。**启动 App 是集成负责人的步骤**，本 scaffold 与
> `scripts/package-app.sh` 都刻意不启动、不激活、不聚焦任何 GUI 程序。

## 事实清单

| 项 | 值 |
| --- | --- |
| Bundle ID | `com.yishuziyu.her.cua-host` |
| 可执行文件 | `CuaHost`（`@main` SwiftUI，macOS 14.0+） |
| LSUIElement | `false`（普通 Dock App，有主菜单栏，菜单命令可通过 AX 菜单树访问） |
| 状态服务 | 进程内 HTTP，监听 **`127.0.0.1:19476`**（loopback only） |
| 状态服务端点 | `GET /state` → JSON；`POST /reset` → 复位后 JSON；其余 404 |
| 打包产物 | `tools/cua-host/.build/CuaHost.app`（`scripts/package-app.sh` 生成；`tools/*/.build/` 已被 .gitignore 忽略，不进版本库） |

## 控件清单（AX 标识符 = AXIdentifier）

主窗口 `CuaHost 受控桌面`：

| AX 标识符 | 标题 / 标签 | 真实副作用（写入 /state） |
| --- | --- | --- |
| `task-2` | 检查官网部署状态（2） | `selected="task-2"`, `clicks+1`, `events+=task-2` |
| `task-3` | 检查官网部署状态（3） | `selected="task-3"`, `clicks+1`, `events+=task-3` |
| `left-setting` | 设置（左） | `selected="left-setting"`, `clicks+1`, `events+=left-setting` |
| `right-setting` | 设置（右） | `selected="right-setting"`, `clicks+1`, `events+=right-setting` |
| `open-display-settings` | 打开显示设置 | `menu_open=true`, `events+=open-menu`（**不计 clicks**，与 fixture 一致） |
| `scale` | 缩放选项（仅在上一步之后存在，对应 fixture 的 `hidden` 区） | `selected="scale"`, `clicks+1`, `events+=scale` |
| `notes-field` | 备注（NSTextField） | 每次真实键入内容变化 → `typed_text` = 当前内容 |
| `open-second-window` | 打开二级窗口 | `second_window_visible=true`, `events+=second-window-open` |
| `status-text` | 状态行：`已选择：…，点击次数：…，步骤：…` | 只读镜像 |

菜单栏 `受控操作`（CommandMenu）：

| 菜单项标题 | 副作用 |
| --- | --- |
| 记录一次受控命令 | `selected="menu-command"`, `clicks+1`, `events+=menu-command` |

二级窗口 `二级窗口`（`openWindow(id: "second-window")`）：

| AX 标识符 | 标题 | 副作用 |
| --- | --- | --- |
| `close-second-window` | 关闭 | 触发真实 `onDisappear` → `second_window_visible=false`, `events+=second-window-close` |

窗口自带的红色关闭按钮 / Cmd+W 同样走真实 `onDisappear`。所有状态都由真实回调
累加（Button 的 action、text field 的 `onChange`、窗口生命周期），**没有任何合成事件**。

## `/state` 字段

```json
{
  "selected": null,          // 最近一次选择的控件值：task-2/task-3/left-setting/right-setting/scale/menu-command
  "clicks": 0,               // 选择类控件（含菜单命令）的真实点击次数；open-menu 不计入
  "events": [],              // 真实 UI 事件的有序序列，如 ["open-menu","scale"]
  "typed_text": "",          // notes-field 的当前真实内容
  "menu_open": false,        // 「缩放选项」隐藏区是否已打开
  "second_window_visible": false, // 二级窗口是否打开
  "page_views": 0            // 诊断字段：主窗口真实出现次数；刻意不被 /reset 复位（同 fixture.py）
}
```

`POST /reset` 复位测试语义（`selected/clicks/events/typed_text/menu_open/second_window_visible`），
保留 `page_views` 作为「进程是否真的（重新）出现过」的证据。

## 构建与打包

```bash
cd tools/cua-host
swift build                 # 开发构建，验证退出码 0
scripts/package-app.sh      # release 构建 + 组装 .build/CuaHost.app（不启动）
scripts/package-app.sh debug  # 如需 debug 配置
```

`package-app.sh` 只做文件组装：`swift build -c release` → 拷贝可执行文件与
`Info.plist` 到 `.build/CuaHost.app`（`plutil -lint` 校验）。
产物体积小是因为 CuaHost 是纯 SwiftPM 工程，不链接 app 目标、不需要签名即可本地运行。

## 如何由验收方启动（留给集成负责人，不由本 scaffold 执行）

1. 确保端口空闲：`lsof -nP -iTCP:19476 | grep LISTEN` 应为空。
2. 启动宿主（任选其一，均属集成方职责）：
   - `open tools/cua-host/.build/CuaHost.app`
   - 或用真实 CUA 驱动的 launch / bundle id 方式启动 `com.yishuziyu.her.cua-host`。
3. 等待主窗口出现且服务就绪（`bash -c 'until curl -sf http://127.0.0.1:19476/state >/dev/null; do sleep 0.2; done'`）。
4. 用真实 CUA 驱动操作：AX 标识符解析「左边的设置」与「右边的设置」两个同名按钮
   （靠位置左右消歧），驱动菜单栏 `受控操作 → 记录一次受控命令`，打开 / 关闭二级窗口。
5. 每次断言前后读回 `curl -s http://127.0.0.1:19476/state`，用
   `selected / clicks / events / typed_text / menu_open / second_window_visible` 证明副作用；
   `POST /reset` 复位测试语义。

## 目录结构与边界

```
tools/cua-host/
├── Package.swift                  # 独立 SwiftPM executable target（macOS 14+）
├── Info.plist                     # .app 骨架使用的 CFBundle 元数据
├── Sources/CuaHost/
│   ├── CuaHostApp.swift           # @main、WindowGroup + 二级 Window + 菜单命令
│   ├── ContentView.swift          # 主窗口全部控件（AX 标识符稳定）
│   ├── SecondWindow.swift         # 二级窗口（真实 onDisappear 回写状态）
│   ├── HostStore.swift            # 单一状态真源 + /state JSON 序列化
│   └── StateServer.swift          # 127.0.0.1:19476 loopback HTTP（NWListener）
├── scripts/package-app.sh         # 构建 + 组装 .app，绝不启动 App
└── README.md
```

刻意不做的事（避免污染验收环境）：不修改工具目录以外的任何文件；不启动 / 激活 /
聚焦 App；不写 Application Support；不请求摄像头 / 麦克风 / 录屏权限。
