import Foundation

/// Pure predicates over independent after-state. A driver return, model score,
/// or generic screen hash difference is deliberately not a completion signal.
enum DesktopActionVerifier {
    static func matchingControls(_ target: DesktopTaskTarget, in controls: [DesktopAccessibleControl]) -> [DesktopAccessibleControl] {
        guard target.box.count == 4 else { return [] }
        let centerX = (target.box[0] + target.box[2]) / 2
        let centerY = (target.box[1] + target.box[3]) / 2
        return controls.filter { control in
            control.box.count == 4 && DesktopActionStep.normalized(control.label) == DesktopActionStep.normalized(target.label)
                && centerX >= control.box[0] - 4 && centerX <= control.box[2] + 4
                && centerY >= control.box[1] - 4 && centerY <= control.box[3] + 4
        }
    }

    static func verify(step: DesktopActionStep, target: DesktopTaskTarget?,
                       before: [DesktopAccessibleControl], after: [DesktopAccessibleControl],
                       beforeTargets: [DesktopTaskTarget], afterTargets: [DesktopTaskTarget]) -> Bool {
        if step.action != .type, step.action != .openApp, let expectedLabel = step.expectedLabel {
            let normalized = DesktopActionStep.normalized(expectedLabel)
            let wasVisible = beforeTargets.contains { DesktopActionStep.normalized($0.label) == normalized }
            let isVisible = afterTargets.contains { DesktopActionStep.normalized($0.label) == normalized }
            // A label that was already present cannot prove this action worked.
            if !wasVisible && isVisible { return true }
        }
        guard let target else { return false }
        let previous = matchingControls(target, in: before)
        let current = matchingControls(target, in: after)
        switch step.action {
        case .click, .doubleClick:
            if current.contains(where: { $0.selected == true }), !previous.contains(where: { $0.selected == true }) { return true }
            // Focusing a text field is the result of a click-to-focus step, not
            // proof that an arbitrary button's intended workflow completed.
            return current.contains { $0.isTextField && $0.focused == true }
                && !previous.contains { $0.isTextField && $0.focused == true }
        case .type:
            guard let text = step.text else { return false }
            let beforeFields = previous.filter { $0.isTextField && $0.focused == true }
            let afterFields = current.filter { $0.isTextField && $0.focused == true }
            guard beforeFields.count == 1, afterFields.count == 1,
                  let oldValue = beforeFields[0].value, let newValue = afterFields[0].value, oldValue != newValue else { return false }
            if let start = beforeFields[0].selectionStart, let length = beforeFields[0].selectionLength,
               start >= 0, length >= 0, start <= (oldValue as NSString).length,
               length <= (oldValue as NSString).length - start {
                return (oldValue as NSString).replacingCharacters(in: NSRange(location: start, length: length), with: text) == newValue
            }
            return newValue == oldValue + text
        default: return false
        }
    }
}
