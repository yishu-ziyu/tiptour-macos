import AppKit
import ApplicationServices

/// Read-only AX evidence. No AX object survives the observation; execution
/// still goes through the shared action engine with freshly checked geometry.
struct DesktopAccessibleControl: Equatable, Sendable {
    let label: String
    let role: String
    let box: [Double]
    var selected: Bool? = nil
    var focused: Bool? = nil
    var value: String? = nil
    var selectionStart: Int? = nil
    var selectionLength: Int? = nil

    var isTextField: Bool { ["AXTextField", "AXTextArea", "AXComboBox"].contains(role) }
}

enum DesktopAccessibilityReader {
    /// Bounded, batched IPC. Secure text fields and their descendants are never
    /// turned into candidates or sent to any model.
    nonisolated static func read(processIdentifier: pid_t, primaryDisplayTop: Double) -> [DesktopAccessibleControl] {
        guard AXIsProcessTrusted() else { return [] }
        let app = AXUIElementCreateApplication(processIdentifier)
        AXUIElementSetMessagingTimeout(app, 0.15)
        let deadline = Date().addingTimeInterval(0.35)
        let attributes = [kAXRoleAttribute, kAXSubroleAttribute, kAXTitleAttribute, kAXDescriptionAttribute,
            kAXValueAttribute, kAXPositionAttribute, kAXSizeAttribute, kAXEnabledAttribute,
            kAXSelectedAttribute, kAXFocusedAttribute, kAXChildrenAttribute, kAXSelectedTextRangeAttribute] as CFArray
        var controls: [DesktopAccessibleControl] = []
        var visited = 0

        func walk(_ node: AXUIElement, depth: Int) {
            guard depth <= 18, visited < 1500, controls.count < 240, Date() < deadline else { return }
            visited += 1
            var values: CFArray?
            guard AXUIElementCopyMultipleAttributeValues(node, attributes, [], &values) == .success,
                  let values = values as? [Any], values.count == 12 else { return }
            let role = values[0] as? String ?? ""
            let subrole = values[1] as? String ?? ""
            guard subrole != "AXSecureTextField", role != "AXSecureTextField" else { return }
            let title = values[2] as? String ?? ""
            let description = values[3] as? String ?? ""
            let fieldValue = values[4] as? String
            let rawLabel = !title.isEmpty ? title : (!description.isEmpty ? description : (role == "AXStaticText" ? fieldValue ?? "" : ""))
            let label = rawLabel.trimmingCharacters(in: .whitespacesAndNewlines)
            let relevantRoles = ["AXButton", "AXMenuButton", "AXMenuBarItem", "AXMenuItem", "AXTab", "AXCheckBox",
                "AXRadioButton", "AXTextField", "AXTextArea", "AXComboBox", "AXLink", "AXPopUpButton", "AXCell", "AXRow", "AXStaticText"]
            if relevantRoles.contains(role), !label.isEmpty, label.count <= 160, (values[7] as? Bool) != false {
                var position = CGPoint.zero
                var size = CGSize.zero
                if CFGetTypeID(values[5] as CFTypeRef) == AXValueGetTypeID(),
                   CFGetTypeID(values[6] as CFTypeRef) == AXValueGetTypeID(),
                   AXValueGetValue(values[5] as! AXValue, .cgPoint, &position),
                   AXValueGetValue(values[6] as! AXValue, .cgSize, &size), size.width > 4, size.height > 4 {
                    let lowerY = primaryDisplayTop - position.y - size.height
                    var control = DesktopAccessibleControl(label: label, role: role,
                        box: [position.x, lowerY, position.x + size.width, lowerY + size.height],
                        selected: values[8] as? Bool, focused: values[9] as? Bool)
                    if control.isTextField {
                        // Values are used only by the local verifier, never as labels.
                        control.value = fieldValue.flatMap { $0.count <= 30_000 ? $0 : nil }
                        if CFGetTypeID(values[11] as CFTypeRef) == AXValueGetTypeID() {
                            var range = CFRange()
                            if AXValueGetValue(values[11] as! AXValue, .cfRange, &range) {
                                control.selectionStart = range.location
                                control.selectionLength = range.length
                            }
                        }
                    }
                    let duplicate = controls.contains { previous in
                        previous.label == control.label && previous.box == control.box
                    }
                    if !duplicate { controls.append(control) }
                }
            }
            for child in values[10] as? [AXUIElement] ?? [] { walk(child, depth: depth + 1) }
        }

        var window: CFTypeRef?
        if AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &window) == .success,
           let window, CFGetTypeID(window) == AXUIElementGetTypeID() {
            walk(window as! AXUIElement, depth: 0)
        } else { walk(app, depth: 0) }
        var menu: CFTypeRef?
        if AXUIElementCopyAttributeValue(app, kAXMenuBarAttribute as CFString, &menu) == .success,
           let menu, CFGetTypeID(menu) == AXUIElementGetTypeID() {
            walk(menu as! AXUIElement, depth: 0)
        }
        return controls
    }

    static func detectionElements(_ controls: [DesktopAccessibleControl], display: CGRect, imageSize: CGSize) -> [[String: Any]] {
        guard display.width > 0, display.height > 0 else { return [] }
        return controls.compactMap { control in
            guard control.box.count == 4 else { return nil }
            let frame = CGRect(x: control.box[0], y: control.box[1], width: control.box[2] - control.box[0], height: control.box[3] - control.box[1])
            guard display.contains(CGPoint(x: frame.midX, y: frame.midY)) else { return nil }
            let scaleX = imageSize.width / display.width
            let scaleY = imageSize.height / display.height
            return ["label": control.label, "source": "ax", "conf": 1.0,
                "bbox": [Int((frame.minX - display.minX) * scaleX), Int((display.maxY - frame.maxY) * scaleY),
                         Int((frame.maxX - display.minX) * scaleX), Int((display.maxY - frame.minY) * scaleY)]]
        }
    }
}
