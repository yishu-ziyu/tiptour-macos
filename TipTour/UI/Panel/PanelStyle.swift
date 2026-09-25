import AppKit
import SwiftUI

/// Visual language of the menu bar panel, taken from the prototype the user
/// approved on 2026-09-23 (docs/development/2026-09-23-first-run-and-interface.md,
/// prototype at out/design/her-first-run/). Unlike the rest of the app, which
/// still draws with the always-dark `DS` palette, the panel follows the system
/// appearance: it is a thin material over whatever is behind it, so its text
/// uses the system label colors that adapt to that material.
enum PanelStyle {
    static let width: CGFloat = 320
    static let cornerRadius: CGFloat = 16
    static let contentPadding: CGFloat = 14

    /// Size of the menu bar pill the panel grows out of (bencho #liq-create).
    static let collapsedPillSize = CGSize(width: 44, height: 26)
    /// The pill first sinks to 94 % for 95 ms, then expands.
    static let sinkScale: CGFloat = 0.94
    static let sinkDuration: TimeInterval = 0.095
    /// cubic-bezier(.22, 1, .36, 1) over 480 ms, the specimen's expansion curve.
    static let expandAnimation = Animation.timingCurve(0.22, 1, 0.36, 1, duration: 0.48)
    /// Each row fades up 6 pt over 280 ms, 70 ms plus 38 ms per row after the expansion starts.
    static let rowRiseDistance: CGFloat = 6
    static let rowRevealDuration: TimeInterval = 0.28
    static func rowRevealDelay(rowIndex: Int) -> TimeInterval { 0.07 + Double(rowIndex) * 0.038 }

    static let accent = DS.Colors.accent
    static let primaryText = Color(nsColor: .labelColor)
    static let secondaryText = Color(nsColor: .secondaryLabelColor)
    static let tertiaryText = Color(nsColor: .tertiaryLabelColor)
    static let hoverFill = Color.primary.opacity(0.06)
    static let quietFill = Color.primary.opacity(0.05)
    static let hairline = Color.primary.opacity(0.10)
    static let successTint = Color(nsColor: .systemGreen)
    static let warningTint = Color(nsColor: .systemOrange)
}

/// The panel's thin material. `.popover` behind the window is the material
/// macOS uses for menu bar popovers, so light and dark both look native.
struct PanelMaterialBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let materialView = NSVisualEffectView()
        materialView.material = .popover
        materialView.blendingMode = .behindWindow
        materialView.state = .active
        return materialView
    }

    func updateNSView(_ materialView: NSVisualEffectView, context: Context) {}
}

// MARK: - Reveal: the menu bar pill becomes the panel

private struct PanelRowsRevealedKey: EnvironmentKey {
    static let defaultValue = true
}

extension EnvironmentValues {
    /// False while the panel is still a pill; rows fade in once it turns true.
    var panelRowsRevealed: Bool {
        get { self[PanelRowsRevealedKey.self] }
        set { self[PanelRowsRevealedKey.self] = newValue }
    }
}

/// Grows the panel out of a pill at its top center (the panel is centered
/// under the status item) every time `revealGeneration` changes, then lets rows fade in one by one.
///
/// The window is already full size; only a mask animates. Resizing the window
/// itself every frame would make the anchored panel jitter against the menu bar.
struct PanelRevealContainer<Content: View>: View {
    let revealGeneration: Int
    @ViewBuilder let content: () -> Content

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isExpanded = true
    @State private var isSunk = false
    @State private var areRowsRevealed = true

    var body: some View {
        content()
            .environment(\.panelRowsRevealed, areRowsRevealed)
            .mask(alignment: .top) {
                GeometryReader { geometry in
                    let maskWidth = isExpanded ? geometry.size.width : PanelStyle.collapsedPillSize.width
                    let maskHeight = isExpanded ? geometry.size.height : PanelStyle.collapsedPillSize.height
                    RoundedRectangle(
                        cornerRadius: isExpanded ? PanelStyle.cornerRadius : PanelStyle.collapsedPillSize.height / 2,
                        style: .continuous
                    )
                    .frame(width: maskWidth, height: maskHeight)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                }
            }
            .scaleEffect(isSunk ? PanelStyle.sinkScale : 1, anchor: .top)
            // Every show posts a new generation, including the first one.
            .onChange(of: revealGeneration) { _, _ in playReveal() }
    }

    private func playReveal() {
        // Reduce Motion: appear in place, no growth and no staggered rows.
        guard !reduceMotion else {
            isExpanded = true
            isSunk = false
            areRowsRevealed = true
            return
        }
        var instantTransaction = Transaction()
        instantTransaction.disablesAnimations = true
        withTransaction(instantTransaction) {
            isExpanded = false
            areRowsRevealed = false
        }
        withAnimation(.easeOut(duration: PanelStyle.sinkDuration)) { isSunk = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + PanelStyle.sinkDuration) {
            withAnimation(PanelStyle.expandAnimation) {
                isSunk = false
                isExpanded = true
            }
            areRowsRevealed = true
        }
    }
}

/// One row of panel content that fades up in order during the reveal.
private struct PanelRowRevealModifier: ViewModifier {
    let rowIndex: Int
    @Environment(\.panelRowsRevealed) private var areRowsRevealed

    func body(content: Content) -> some View {
        content
            .opacity(areRowsRevealed ? 1 : 0)
            .offset(y: areRowsRevealed ? 0 : PanelStyle.rowRiseDistance)
            .animation(
                areRowsRevealed
                    ? .easeOut(duration: PanelStyle.rowRevealDuration).delay(PanelStyle.rowRevealDelay(rowIndex: rowIndex))
                    : nil,
                value: areRowsRevealed
            )
    }
}

extension View {
    func panelRow(_ rowIndex: Int) -> some View {
        modifier(PanelRowRevealModifier(rowIndex: rowIndex))
    }
}

// MARK: - Small shared pieces

/// A physical-looking key, used to show ⌃⌥ and ⌃K.
struct PanelKeycap: View {
    let symbol: String

    var body: some View {
        Text(symbol)
            .font(.system(size: 15, weight: .regular))
            .foregroundColor(PanelStyle.primaryText)
            .frame(minWidth: 30, minHeight: 30)
            .padding(.horizontal, 2)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor).opacity(0.85))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(PanelStyle.hairline, lineWidth: 0.5)
            )
            .shadow(color: Color.black.opacity(0.12), radius: 0, x: 0, y: 1)
    }
}

/// A status label that breathes while something is in progress (triage #toolbar:
/// opacity 1 → 0.45 → 1 over 1.8 s). Reduce Motion keeps it still.
struct PanelStatusChip: View {
    let text: String
    var isInProgress = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isDimmed = false

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .medium))
            .foregroundColor(PanelStyle.secondaryText)
            .lineLimit(1)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Capsule().fill(PanelStyle.quietFill))
            .opacity(isDimmed ? 0.45 : 1)
            .onAppear { updateBreathing() }
            .onChange(of: isInProgress) { _, _ in updateBreathing() }
    }

    private func updateBreathing() {
        guard isInProgress, !reduceMotion else {
            withAnimation(.easeOut(duration: 0.18)) { isDimmed = false }
            return
        }
        withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { isDimmed = true }
    }
}

/// Plain text button with the panel's hover fill.
struct PanelTextButton: View {
    let title: String
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12))
                .foregroundColor(isHovered ? PanelStyle.primaryText : PanelStyle.secondaryText)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(RoundedRectangle(cornerRadius: 6).fill(isHovered ? PanelStyle.hoverFill : Color.clear))
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .pointerCursor()
    }
}

/// The panel's one filled button style.
struct PanelPrimaryButton: View {
    let title: String
    var isEnabled = true
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundColor(.white)
                .padding(.horizontal, 13)
                .frame(height: 28)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(isHovered && isEnabled ? DS.Colors.accentHover : PanelStyle.accent)
                )
                .opacity(isEnabled ? 1 : 0.35)
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .onHover { isHovered = $0 }
        .pointerCursor(isEnabled: isEnabled)
    }
}
