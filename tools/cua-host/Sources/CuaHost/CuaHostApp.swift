import SwiftUI

@main
struct CuaHostApp: App {
    init() {
        // The state readback service lives inside the app process and starts
        // with it. It only binds a loopback socket — it never launches,
        // focuses or activates anything.
        StateServer.shared.startIfNeeded()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .commands {
            HostMenuCommands()
        }

        Window("二级窗口", id: "second-window") {
            SecondWindowView()
        }
    }
}

/// The one real menu command of the host. Its activation is recorded exactly
/// like a button activation, so an acceptance runner can prove menu dispatch
/// through `/state` instead of pixels.
struct HostMenuCommands: Commands {
    var body: some Commands {
        CommandMenu("受控操作") {
            Button("记录一次受控命令") {
                HostStore.shared.select("menu-command")
            }
        }
    }
}
