import SwiftUI

/// The openable second window of the controlled host.
///
/// Closing it — with the in-window button, the window's own close button, or
/// Cmd+W — fires the real `onDisappear` lifecycle callback and flips
/// `second_window_visible` back to false in the state service.
struct SecondWindowView: View {
    @StateObject private var store = HostStore.shared
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        VStack(spacing: 22) {
            Text("二级窗口")
                .font(.title.bold())
            Text("打开与关闭都通过真实的窗口生命周期回调写入 second_window_visible，不经过任何合成事件。")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Text("当前状态：\(store.view.secondWindowVisible ? "已打开" : "已关闭")")
                .font(.callout.monospaced())
                .accessibilityIdentifier("second-window-detail-status")

            Button("关闭") {
                dismissWindow(id: "second-window")
            }
            .accessibilityIdentifier("close-second-window")
            .controlSize(.large)
        }
        .padding(40)
        .frame(minWidth: 400, minHeight: 280)
        .onDisappear {
            store.secondWindowVisibilityChanged(false)
        }
    }
}
