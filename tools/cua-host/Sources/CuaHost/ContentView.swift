import SwiftUI

/// The controlled desktop surface.
///
/// Every control carries a stable accessibility identifier matching the
/// controlled page semantics in tools/voice-acceptance/fixture.py, so a real
/// CUA driver can resolve them by AX identifier / title and prove the effect
/// through `GET /state` afterwards.
struct ContentView: View {
    @StateObject private var store = HostStore.shared
    @Environment(\.openWindow) private var openWindow

    @State private var notes = ""
    @State private var displaySettingsOpen = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                deploymentSection
                settingSection
                displaySettingsSection
                notesSection
                secondWindowSection
                statusCard
            }
            .padding(30)
        }
        .frame(minWidth: 640, minHeight: 660)
        .navigationTitle("CuaHost 受控桌面")
        .onAppear {
            store.recordPageView()
        }
    }

    // MARK: - Sections

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("CuaHost 受控桌面")
                .font(.largeTitle.bold())
            Text("这里所有控件都是测试用的，点击不会修改真实数据。副作用由本进程内的状态服务证明：http://127.0.0.1:19476/state")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private var deploymentSection: some View {
        SectionCard("官网部署状态") {
            HStack(spacing: 16) {
                controlButton("检查官网部署状态（2）", id: "task-2", value: "task-2")
                controlButton("检查官网部署状态（3）", id: "task-3", value: "task-3")
            }
        }
    }

    private var settingSection: some View {
        SectionCard("同名设置按钮（左右各一个）") {
            HStack(spacing: 48) {
                controlButton("设置", id: "left-setting", value: "left-setting")
                Spacer(minLength: 24)
                controlButton("设置", id: "right-setting", value: "right-setting")
            }
        }
    }

    private var displaySettingsSection: some View {
        SectionCard("显示设置") {
            VStack(alignment: .leading, spacing: 14) {
                Button {
                    displaySettingsOpen = true
                    store.openDisplaySettings()
                } label: {
                    Text("打开显示设置").padding(.horizontal, 8)
                }
                .accessibilityIdentifier("open-display-settings")

                if displaySettingsOpen {
                    Button {
                        store.select("scale")
                    } label: {
                        Text("缩放选项").padding(.horizontal, 8)
                    }
                    .accessibilityIdentifier("scale")
                    .transition(.opacity)
                }
            }
        }
    }

    private var notesSection: some View {
        SectionCard("备注输入") {
            VStack(alignment: .leading, spacing: 8) {
                Text("备注").font(.subheadline)
                TextField("在这里输入备注，内容会写入 typed_text", text: $notes)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("notes-field")
                    .onChange(of: notes) { _, newValue in
                        store.updateTypedText(newValue)
                    }
                Text("当前记录：\(store.view.typedText.isEmpty ? "（空）" : store.view.typedText)")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("notes-echo")
            }
        }
    }

    private var secondWindowSection: some View {
        SectionCard("二级窗口") {
            HStack(spacing: 16) {
                Button {
                    openWindow(id: "second-window")
                    store.secondWindowVisibilityChanged(true)
                } label: {
                    Text("打开二级窗口").padding(.horizontal, 8)
                }
                .accessibilityIdentifier("open-second-window")

                Text("当前状态：\(store.view.secondWindowVisible ? "已打开" : "已关闭")")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("second-window-status")
            }
        }
    }

    private var statusCard: some View {
        SectionCard("状态（同时由 /state 提供机器可读读回）") {
            Text(store.view.summary)
                .font(.body.monospaced())
                .accessibilityIdentifier("status-text")
        }
    }

    // MARK: - Helpers

    private func controlButton(_ title: String, id: String, value: String) -> some View {
        Button {
            store.select(value)
        } label: {
            Text(title).padding(.horizontal, 8)
        }
        .accessibilityIdentifier(id)
        .controlSize(.large)
    }
}

private struct SectionCard<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.headline)
            content
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}
