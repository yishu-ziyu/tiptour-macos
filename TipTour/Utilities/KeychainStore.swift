//
//  KeychainStore.swift
//  TipTour
//
//  Minimal Keychain helper for storing sensitive strings (like API keys)
//  that shouldn't live in UserDefaults. Uses kSecClassGenericPassword —
//  the standard macOS pattern for service-scoped secrets.
//
//  Scoped to TipTour's bundle identifier so the entries are isolated
//  from other services. No iCloud sync — these are device-local keys only.
//

import Foundation
import LocalAuthentication
import Security

enum KeychainStore {

    // Successful reads stay in this process only. Starting another voice turn
    // must not decrypt the same Keychain item (and ask for access) again.
    private static let unlockedValues = NSCache<NSString, NSString>()

    private static let serviceName: String = Bundle.main.bundleIdentifier ?? "com.milindsoni.tiptour"

    /// Write (or overwrite) a UTF-8 string for the given key. Returns
    /// true on success. Empty / whitespace-only input is treated as a
    /// delete so callers can implement "clear the key" as just writing
    /// an empty string.
    @discardableResult
    static func set(_ value: String, forKey key: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return delete(forKey: key)
        }
        guard let data = trimmed.data(using: .utf8) else { return false }

        // Baseline query: find the existing item (if any).
        let query: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: key
        ]

        let updateAttributes: [String: Any] = [
            kSecValueData as String: data
        ]

        // Try update first; if the item doesn't exist, fall through to add.
        let updateStatus = SecItemUpdate(query as CFDictionary, updateAttributes as CFDictionary)
        if updateStatus == errSecSuccess {
            unlockedValues.setObject(trimmed as NSString, forKey: key as NSString)
            return true
        }
        guard updateStatus == errSecItemNotFound else { return false }

        // Either no existing item or update failed — try to add fresh.
        var addQuery = query
        addQuery[kSecValueData as String] = data
        // Only accessible after the device has been unlocked (standard
        // behavior for a Mac app — keys shouldn't leak to background
        // processes on a locked machine).
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        if addStatus == errSecSuccess {
            unlockedValues.setObject(trimmed as NSString, forKey: key as NSString)
        }
        return addStatus == errSecSuccess
    }

    /// Read the stored UTF-8 string for the given key. Returns nil if
    /// nothing was ever stored, or if the item exists but isn't valid
    /// UTF-8 (shouldn't happen for keys written via `set`).
    static func get(forKey key: String, allowInteraction: Bool = true,
                    onFailure: ((OSStatus) -> Void)? = nil) -> String? {
        if let cached = unlockedValues.object(forKey: key as NSString) { return cached as String }
        var query: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: key,
            kSecReturnData as String:  true,
            kSecMatchLimit as String:  kSecMatchLimitOne
        ]
        if !allowInteraction {
            let context = LAContext()
            context.interactionNotAllowed = true
            query[kSecUseAuthenticationContext as String] = context
        }

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess,
              let data = item as? Data,
              let string = String(data: data, encoding: .utf8) else {
            onFailure?(status == errSecSuccess ? errSecDecode : status)
            return nil
        }
        unlockedValues.setObject(string as NSString, forKey: key as NSString)
        return string
    }

    /// Presence is enough for the setup indicator. Decrypting a key here can
    /// block app startup on an authorization dialog before any model is used.
    static func contains(forKey key: String) -> Bool {
        if unlockedValues.object(forKey: key as NSString) != nil { return true }
        let context = LAContext()
        context.interactionNotAllowed = true
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: key,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecUseAuthenticationContext as String: context
        ]
        return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
    }

    /// Delete the item for the given key. Returns true if deleted OR
    /// if there was nothing to delete (either is "success" from the
    /// caller's perspective — the key is gone).
    @discardableResult
    static func delete(forKey key: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: key
        ]
        let status = SecItemDelete(query as CFDictionary)
        if status == errSecSuccess || status == errSecItemNotFound {
            unlockedValues.removeObject(forKey: key as NSString)
            return true
        }
        return false
    }

    // MARK: - TipTour-specific keys

    /// Gemini API key the user has pasted directly into the app.
    static var geminiAPIKey: String? {
        get { get(forKey: "geminiAPIKey") }
        set { set(newValue ?? "", forKey: "geminiAPIKey") }
    }

    /// TypeSafe API key for JEV text commands.
    static var jevAPIKey: String? {
        get { get(forKey: "jevAPIKey") }
        set { set(newValue ?? "", forKey: "jevAPIKey") }
    }

    /// StepFun API key for the realtime voice session. One key covers both the
    /// realtime model and the vision model used for grounding.
    static var stepfunAPIKey: String? {
        get { get(forKey: "stepfunAPIKey") }
        set { set(newValue ?? "", forKey: "stepfunAPIKey") }
    }

}
