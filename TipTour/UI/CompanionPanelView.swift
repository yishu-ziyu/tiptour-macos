//
//  CompanionPanelView.swift
//  TipTour
//
//  The menu bar panel. Layout and motion follow the prototype the user
//  approved on 2026-09-23 (docs/development/2026-09-23-first-run-and-interface.md):
//  a thin system material that grows out of a pill under the status item, a
//  two-step setup, and a ready state that says how to call her and what to say.
//

import SwiftUI

struct CompanionPanelView: View {
    @ObservedObject var companionManager: CompanionManager
    @State private var setupStep: PanelOnboardingView.SetupStep = .key
    /// Bumped every time the panel is shown, which replays the reveal.
    @State private var revealGeneration = 0

    /// Onboarded, and the key is either already read in this process or stored
    /// but not yet read. `.saved` is what every relaunch looks like (the key is
    /// read when a session starts), so it must offer the start control instead
    /// of sending the user back into setup; nothing here claims the key works,
    /// and a failed read at start is reported by the session. Refused,
    /// undecodable, unknown or missing keys get `keyNotUsableSection`.
    /// Supersedes the 2026-09-23 06R rule that `.saved` may not show the start
    /// control (docs/development/2026-09-23-first-run-and-interface.md).
    private var isReady: Bool {
        guard companionManager.hasCompletedOnboarding else { return false }
        switch companionManager.selectedModeKeyState {
        case .available, .saved: return true
        case .absent, .readDenied, .undecodable, .unavailable: return false
        }
    }

    var body: some View {
        PanelRevealContainer(revealGeneration: revealGeneration) {
            VStack(alignment: .leading, spacing: 0) {
                panelHeader
                    .panelRow(0)
                if isReady {
                    PanelReadyView(companionManager: companionManager)
                } else if companionManager.hasCompletedOnboarding {
                    keyNotUsableSection
                } else {
                    PanelOnboardingView(companionManager: companionManager, setupStep: $setupStep)
                }
                footerSection
                    .panelRow(9)
            }
            .padding(PanelStyle.contentPadding)
            .frame(width: PanelStyle.width, alignment: .leading)
            .background(PanelMaterialBackground())
            .clipShape(RoundedRectangle(cornerRadius: PanelStyle.cornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: PanelStyle.cornerRadius, style: .continuous)
                    .strokeBorder(PanelStyle.hairline, lineWidth: 0.5)
            )
        }
        .onAppear { companionManager.refreshProviderKeyStatus() }
        .onReceive(NotificationCenter.default.publisher(for: .tipTourPanelDidShow)) { _ in
            companionManager.refreshProviderKeyStatus()
            revealGeneration += 1
        }
    }

    // MARK: - Header

    private var panelHeader: some View {
        HStack(spacing: 9) {
            ThinkingOrbView(
                state: ThinkingOrbState(voiceState: companionManager.voiceState),
                size: 22,
                isOnDarkSurface: colorSchemeIsDark
            )
            Text(companionManager.companionName.isEmpty ? "Her" : companionManager.companionName)
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(PanelStyle.primaryText)
                .lineLimit(1)
            Spacer(minLength: 8)
            if !companionManager.hasCompletedOnboarding {
                PanelOnboardingView.stepIndicator(currentStep: setupStep)
            } else if let liveStatusText {
                PanelStatusChip(text: liveStatusText, isInProgress: companionManager.voiceState == .processing)
            }
        }
        .padding(.bottom, 12)
    }

    @Environment(\.colorScheme) private var colorScheme
    /// The panel follows the system appearance, so the orb's ink does too.
    private var colorSchemeIsDark: Bool { colorScheme == .dark }

    /// Only shown while something is happening; an idle panel stays quiet.
    private var liveStatusText: String? {
        switch companionManager.voiceState {
        case .idle: return nil
        case .processing: return "连接中"
        case .listening: return "在听"
        case .responding: return "在说"
        }
    }

    // MARK: - Onboarded, but the key cannot be used right now

    /// Setup was finished before; do not send the user back through it. Say
    /// what is wrong with the key and let them fix it in place.
    private var keyNotUsableSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("\(companionManager.selectedMode.title)密钥暂时用不了")
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(PanelStyle.primaryText)
                .panelRow(1)
            Text(companionManager.selectedModeKeyState.userMessage(subject: "\(companionManager.selectedMode.title)密钥"))
                .font(.system(size: 12))
                .foregroundColor(PanelStyle.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 4)
                .panelRow(2)
            PanelKeyField(mode: companionManager.selectedMode) {
                companionManager.refreshProviderKeyStatus()
            }
            .padding(.top, 12)
            .panelRow(3)
        }
    }

    // MARK: - Footer

    private var footerSection: some View {
        VStack(spacing: 0) {
            Rectangle().fill(PanelStyle.hairline).frame(height: 0.5)
                .padding(.top, 10)
            HStack(spacing: 2) {
                PanelTextButton(title: "设置") {
                    NotificationCenter.default.post(name: .tipTourOpenSettings, object: nil)
                    NotificationCenter.default.post(name: .tipTourDismissPanel, object: nil)
                }
                Spacer()
                PanelTextButton(title: "退出") { NSApp.terminate(nil) }
            }
            .padding(.top, 6)
        }
    }
}
