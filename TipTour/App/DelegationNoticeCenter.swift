//
//  DelegationNoticeCenter.swift
//  TipTour
//
//  Shows hand-off notices as ordinary macOS notifications. A click opens the
//  Ctrl+K conversation; the 「这类不再提醒」 button silences that kind and says
//  where to undo it. Permission is asked the first time a hand-off starts.
//

import AppKit
import UserNotifications

@MainActor
final class DelegationNoticeCenter: NSObject, DelegationNoticePoster, UNUserNotificationCenterDelegate {
    private static let categoryIdentifier = "her.delegation.notice"
    private static let silenceActionIdentifier = "her.delegation.silence"

    private let center = UNUserNotificationCenter.current()
    private let onOpen: @MainActor (UUID?) -> Void
    private let onSilence: @MainActor (DelegationNoticeCategory, UUID?) -> Void

    init(onOpen: @escaping @MainActor (UUID?) -> Void,
         onSilence: @escaping @MainActor (DelegationNoticeCategory, UUID?) -> Void) {
        self.onOpen = onOpen
        self.onSilence = onSilence
        super.init()
        center.delegate = self
        let silence = UNNotificationAction(identifier: Self.silenceActionIdentifier, title: "这类不再提醒", options: [])
        center.setNotificationCategories([
            UNNotificationCategory(identifier: Self.categoryIdentifier, actions: [silence], intentIdentifiers: []),
        ])
    }

    /// Never waits for the user to answer the system prompt, so a hand-off
    /// starts at once; a refusal is reported at the next hand-off.
    func prepare() async -> Bool {
        switch await center.notificationSettings().authorizationStatus {
        case .denied:
            return false
        case .notDetermined:
            Task { _ = try? await center.requestAuthorization(options: [.alert, .sound]) }
            return true
        default:
            return true
        }
    }

    func post(_ notice: DelegationNotice) {
        let content = UNMutableNotificationContent()
        content.title = notice.title
        content.body = notice.body
        content.sound = .default
        content.categoryIdentifier = Self.categoryIdentifier
        content.userInfo = notice.userInfo
        add(identifier: notice.recordID?.uuidString ?? UUID().uuidString, content: content)
    }

    func withdraw(_ recordID: UUID) {
        center.removeDeliveredNotifications(withIdentifiers: [recordID.uuidString])
    }

    /// The receipt for 「这类不再提醒」, naming where the rule can be undone.
    func confirmSilenced(_ category: DelegationNoticeCategory) {
        let content = UNMutableNotificationContent()
        content.title = "好，这类不再提醒"
        content.body = "以后「\(category.displayName)」的任务结束时不弹通知。要恢复，在 设置 → 隐私 → 已关掉的提醒 里点「恢复」。"
        add(identifier: "silenced-\(category.rawValue)", content: content)
    }

    private func add(identifier: String, content: UNNotificationContent) {
        center.add(UNNotificationRequest(identifier: identifier, content: content, trigger: nil)) { error in
            if let error { print("DelegationNoticeCenter: could not post \(identifier): \(error.localizedDescription)") }
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            didReceive response: UNNotificationResponse) async {
        guard let notice = DelegationNotice.decode(userInfo: response.notification.request.content.userInfo) else { return }
        let action = response.actionIdentifier
        await MainActor.run {
            if action == Self.silenceActionIdentifier {
                onSilence(notice.category, notice.recordID)
            } else if action == UNNotificationDefaultActionIdentifier {
                onOpen(notice.recordID)
            }
        }
    }
}
