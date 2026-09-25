import SwiftUI

// Ported from kairos (tag archive/2026-09-23-frozen, apps/kairos/Sources/ThinkingOrb).
// Based on https://github.com/Jakubantalik/thinking-orbs — MIT, see LICENSE-THINKING-ORBS.txt.

/// Nine hand-tuned animation states. Her currently uses four of them through
/// `init(voiceState:)`; the rest stay because the engine draws every mode.
enum ThinkingOrbState: String, CaseIterable, Sendable, Equatable {
    case working
    case searching
    case solving
    case listening
    case connecting
    case weaving
    case composing
    case breathing
    case shaping

    /// The system-layer presence (docs/PRODUCT.md): a slow breath when idle,
    /// a constellation wiring itself while the session connects, a rolling
    /// waveform while she listens, and an undulating sash while she speaks.
    init(voiceState: CompanionVoiceState) {
        switch voiceState {
        case .idle: self = .breathing
        case .processing: self = .connecting
        case .listening: self = .listening
        case .responding: self = .composing
        }
    }

    var accessibilityLabel: String {
        switch self {
        case .working: return "正在执行"
        case .searching: return "正在查找"
        case .solving: return "正在处理"
        case .listening: return "正在聆听"
        case .connecting: return "正在连接"
        case .weaving: return "正在整理"
        case .composing: return "正在回应"
        case .breathing: return "待命"
        case .shaping: return "正在调整"
        }
    }
}

/// Monochrome dotted orb drawn with Canvas. Sizes near 20 pt and 64 pt use the
/// engine's two baked density presets.
///
/// Ink follows the surface the orb sits on, not the system appearance: the
/// menu bar panel is always dark while the cursor pill is always light, and
/// following `colorScheme` would draw dark dots on the dark panel in Light Mode.
struct ThinkingOrbView: View {
    var state: ThinkingOrbState
    var size: CGFloat = 20
    var isOnDarkSurface: Bool
    /// The cursor overlay keeps its orbs in the view tree at zero opacity; they
    /// must pause there, or every screen redraws a hidden Canvas 30 times a second.
    var isPaused = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let side = max(8, size)
        let resolvedPreset = ThinkingOrbPresets.resolve(state: state, size: side)
        TimelineView(.animation(minimumInterval: reduceMotion ? 1.0 / 8.0 : 1.0 / 30.0, paused: isPaused)) { timeline in
            let wallClockSeconds = timeline.date.timeIntervalSinceReferenceDate
            // Reduce Motion freezes the orb on whole seconds instead of animating it.
            let animationClockSeconds = reduceMotion ? floor(wallClockSeconds) : wallClockSeconds
            let animationTime = CGFloat(animationClockSeconds) * resolvedPreset.speed
            Canvas { graphicsContext, canvasSize in
                ThinkingOrbModes.draw(
                    mode: resolvedPreset.mode,
                    context: graphicsContext,
                    size: min(canvasSize.width, canvasSize.height),
                    t: animationTime,
                    dark: isOnDarkSurface,
                    opts: resolvedPreset.opts
                )
            }
        }
        .frame(width: side, height: side)
        .accessibilityLabel(state.accessibilityLabel)
        .accessibilityAddTraits(.updatesFrequently)
    }
}
