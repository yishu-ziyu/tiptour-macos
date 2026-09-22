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
//  Every lookup reports *why* it failed, not just that it did: "no key was
//  ever saved", "macOS refused to read the key that is there" and "the stored
//  key cannot be decoded" are three different problems with three different
//  remedies, and collapsing them into one "please save your key" message is
//  what sent users in circles after they had already saved a key.
//

import Foundation
import LocalAuthentication
import Security

/// What the Keychain actually says about one stored provider key.
///
/// An item the user already saved must never be reported as "not saved", and a
/// key that was never saved must never be reported as a read failure. Both
/// mistakes are avoided by carrying the state instead of a `String?`.
enum KeychainItemState: Equatable {
    /// The value is usable by this process right now: either it is still in
    /// the in-process cache from an earlier successful read or write, or the
    /// presence probe found the item.
    case available
    /// Nothing was ever stored under that account — the user has not saved a
    /// key yet.
    case absent
    /// The item exists, but macOS refused to hand its bytes to this process:
    /// the item's ACL / trusted-application list does not cover this build,
    /// the user cancelled the authorization, or the keychain refused the
    /// interaction.
    case readDenied(OSStatus)
    /// The item exists and was returned, but its bytes are not a valid UTF-8
    /// string, so there is no usable key to hand over.
    case undecodable
    /// Any other OSStatus. Reported verbatim instead of being flattened into
    /// "no key" or into a read denial.
    case unavailable(OSStatus)

    /// True when a stored item exists, whether or not it can be read right
    /// now. A key the user already saved is a key the app cannot claim is
    /// missing.
    var itemExists: Bool {
        self != .absent
    }

    /// True only when this process can actually use the stored value.
    var isUsable: Bool {
        self == .available
    }

    /// The OSStatus behind a failed lookup, for logs and for the user-facing
    /// copy. Never anything taken from the item itself.
    var failureStatus: OSStatus {
        switch self {
        case .available: return errSecSuccess
        case .absent: return errSecItemNotFound
        case .undecodable: return errSecDecode
        case .readDenied(let status), .unavailable(let status): return status
        }
    }

    /// One-line log form. Contains no key material — only the state name and,
    /// where the OS supplies one, its status code.
    var logDescription: String {
        switch self {
        case .available: return "available"
        case .absent: return "absent"
        case .undecodable: return "undecodable (errSecDecode \(errSecDecode))"
        case .readDenied(let status): return "read denied (OSStatus \(status), \(Self.message(for: status)))"
        case .unavailable(let status): return "unavailable (OSStatus \(status), \(Self.message(for: status)))"
        }
    }

    /// The short badge the settings card shows instead of a two-state
    /// "saved / needs a key" pair.
    var summary: String {
        switch self {
        case .available: return "密钥已保存在 macOS 钥匙串"
        case .absent: return "尚未保存密钥"
        case .readDenied(let status): return "钥匙串读取失败（系统状态 \(status)）"
        case .undecodable: return "已保存的密钥无法解析"
        case .unavailable(let status): return "钥匙串状态未知（系统状态 \(status)）"
        }
    }

    /// The sentence the user reads for this state.
    ///
    /// `subject` names whose key it is ("阶跃密钥", "JEV 密钥"), so the settings
    /// card, the voice refusal and the panel all quote this one source and can
    /// never drift apart. The three failures never share a sentence:
    /// "nothing was saved" asks for a save, "macOS refused the read" says the
    /// key is already saved and points at the authorization, and "the stored
    /// bytes are not usable text" asks for a single re-save. The old single
    /// sentence — "未读到阶跃密钥：请在「设置 → 模型」保存密钥后重试" — was wrong
    /// for the middle case, which is exactly the user who had already saved a
    /// key and was told to save it again.
    func userMessage(subject: String) -> String {
        switch self {
        case .available: return "\(subject)已保存。"
        case .absent: return "未保存\(subject)：请在「设置 → 模型」保存密钥后重试。"
        case .readDenied(let status):
            return "钥匙串读取失败：macOS 拒绝读取\(subject)（系统状态 \(status)）。密钥已保存，请在系统提示里允许 Her 访问该钥匙串条目后重试，不需要重新保存。"
        case .undecodable:
            return "\(subject)无法解析：钥匙串里保存的内容不是有效的密钥文本，请在「设置 → 模型」重新保存一次。"
        case .unavailable(let status):
            return "钥匙串状态未知（系统状态 \(status)）：\(subject)暂时读取不了。请重启 Her 后重试，若持续出现请重新保存密钥。"
        }
    }

    /// Map an OSStatus onto a state. `SecCopyErrorMessageString` supplies the
    /// human-readable half of the log line and nothing else.
    static func state(for status: OSStatus) -> KeychainItemState {
        switch status {
        case errSecSuccess: return .available
        case errSecItemNotFound: return .absent
        case errSecUserCanceled, errSecInteractionNotAllowed, errSecAuthFailed:
            return .readDenied(status)
        case errSecDecode: return .undecodable
        default: return .unavailable(status)
        }
    }

    private static func message(for status: OSStatus) -> String {
        (SecCopyErrorMessageString(status, nil) as String?) ?? "unknown"
    }
}

enum KeychainStore {

    // Successful reads stay in this process only. Starting another voice turn
    // must not decrypt the same Keychain item (and ask for access) again.
    private static let unlockedValues = NSCache<NSString, NSString>()

    /// The service every item lives under: the app's own bundle identifier.
    /// A DEBUG build can substitute an isolated acceptance service so a
    /// diagnostic run can never read, overwrite or delete the user's real keys
    /// (see `configureAcceptanceService`).
    private static var serviceName: String {
        #if DEBUG
        // Debug acceptance runs are the only reason this is ever non-nil, and
        // they set it before touching any key.
        if let isolated = acceptanceServiceOverride { return isolated }
        #endif
        return Bundle.main.bundleIdentifier ?? "com.milindsoni.tiptour"
    }

#if DEBUG
    /// Service used instead of the app's own bundle identifier while a DEBUG
    /// acceptance run is in progress. Always a *separate* service, so a
    /// diagnostic run can neither read nor overwrite the user's real
    /// `stepfunAPIKey` / `jevAPIKey` items.
    nonisolated(unsafe) private static var acceptanceServiceOverride: String?

    /// While non-nil, every provider-key lookup reports this status instead of
    /// whatever macOS said, which is how the DEBUG acceptance path reaches the
    /// "macOS refused to read a key that is saved" state.
    ///
    /// The status itself is a real Security framework constant
    /// (`errSecInteractionNotAllowed`), so the product's state mapping and its
    /// user-facing copy run against a genuine value; what is simulated is the
    /// operating system refusing this process, not the status. Measured on this
    /// machine: a legacy ACL / trusted-application list and an ad-hoc code
    /// signature both fail to restrict a generic-password read, so no terminal
    /// command can produce this state without the signed app.
    nonisolated(unsafe) private static var acceptanceDeniedReadStatus: OSStatus?
#endif

    /// Cache keys carry the service they came from, so switching services can
    /// never hand back a value that belongs to a different item.
    private static func cacheKey(_ key: String) -> NSString {
        "\(serviceName)/\(key)" as NSString
    }

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
            remember(trimmed, forKey: key)
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
            remember(trimmed, forKey: key)
        }
        return addStatus == errSecSuccess
    }

    /// Read the stored UTF-8 string for the given key. Returns nil if
    /// nothing was ever stored, or if the item exists but isn't valid
    /// UTF-8 (shouldn't happen for keys written via `set`).
    static func get(forKey key: String, allowInteraction: Bool = true,
                    onFailure: ((OSStatus) -> Void)? = nil) -> String? {
        let outcome = readItem(forKey: key, allowInteraction: allowInteraction)
        if let value = outcome.value { return value }
        onFailure?(outcome.state.failureStatus)
        return nil
    }

    /// Full outcome of a read attempt: the value when it is usable, plus the
    /// state that says *why* it is not when it is not.
    ///
    /// This is the entry point a caller uses when the difference between "no
    /// key saved" and "the key is there but macOS will not give it to me"
    /// changes what the user is told to do.
    static func readItem(forKey key: String, allowInteraction: Bool = true) -> (value: String?, state: KeychainItemState) {
        #if DEBUG
        // DEBUG acceptance only: while a refusal is armed, no lookup may answer
        // from the in-process cache either — the simulated state is "this
        // process cannot obtain the value at all", and a remembered value would
        // quietly defeat it. See `acceptanceDeniedReadStatus`.
        if let denied = acceptanceDeniedReadStatus {
            return (nil, KeychainItemState.state(for: denied))
        }
        #endif
        if let cached = unlockedValues.object(forKey: cacheKey(key)) {
            return (cached as String, .available)
        }
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
        if status == errSecSuccess {
            guard let data = item as? Data, let string = String(data: data, encoding: .utf8) else {
                return (nil, .undecodable)
            }
            unlockedValues.setObject(string as NSString, forKey: cacheKey(key))
            return (string, .available)
        }
        return (nil, KeychainItemState.state(for: status))
    }

    /// Presence with the reason attached. No data is requested, nothing is
    /// decrypted and no prompt is opened — the setup indicator and the settings
    /// cards only need to know a key is there — but a non-success status is
    /// mapped instead of being dropped, so the caller can tell "nothing saved"
    /// from "the item is there but this process may not touch it".
    static func presence(forKey key: String) -> KeychainItemState {
        #if DEBUG
        if let denied = acceptanceDeniedReadStatus { return KeychainItemState.state(for: denied) }
        #endif
        if unlockedValues.object(forKey: cacheKey(key)) != nil { return .available }
        let context = LAContext()
        context.interactionNotAllowed = true
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: key,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecUseAuthenticationContext as String: context
        ]
        return KeychainItemState.state(for: SecItemCopyMatching(query as CFDictionary, nil))
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
            unlockedValues.removeObject(forKey: cacheKey(key))
            return true
        }
        return false
    }

    /// Cache a successfully written value, so starting the next voice turn does
    /// not decrypt the same item (or ask for access) again.
    ///
    /// Skipped while a DEBUG acceptance refusal is armed: the cache is what lets
    /// a later lookup succeed without a Keychain trip, and the simulated state
    /// is "this process cannot obtain the value at all" — a remembered value
    /// would quietly defeat it.
    private static func remember(_ value: String, forKey key: String) {
        #if DEBUG
        // Do not remember a value written while a refusal is armed: a later
        // lookup has to keep reporting it, not serve it from memory.
        guard acceptanceDeniedReadStatus == nil else { return }
        #endif
        unlockedValues.setObject(value as NSString, forKey: cacheKey(key))
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

// MARK: - DEBUG-only acceptance seam

#if DEBUG
extension KeychainStore {
    /// Point every provider-key access at an isolated service, and optionally
    /// make every lookup report a status as if macOS had refused it.
    ///
    /// Call once, before any key is touched: it also drops the in-process
    /// cache, because cached values belong to whichever configuration was
    /// active when they were read or written.
    static func configureAcceptanceService(_ service: String?, deniedReadStatus: OSStatus? = nil) {
        acceptanceServiceOverride = service
        acceptanceDeniedReadStatus = deniedReadStatus
        // Cached values belong to whichever configuration was active when they
        // were read or written.
        unlockedValues.removeAllObjects()
    }

    /// Read the DEBUG acceptance flags out of the launch arguments.
    ///
    /// `--keychain-acceptance` isolates every provider-key access under
    /// `<bundle id>.debug-acceptance`, so no acceptance step can read, write or
    /// delete the user's real `stepfunAPIKey` / `jevAPIKey`.
    /// `--keychain-acceptance-denied-read` implies it and makes every lookup
    /// report `errSecInteractionNotAllowed`, which is the state a user hits
    /// when macOS refuses to hand over a key that is saved.
    ///
    /// Run the denied-read flag only with a key already saved under the
    /// acceptance service: it refuses every lookup, including the presence
    /// probe, so starting it with nothing stored would report a refusal there
    /// is no item to refuse.
    ///
    /// Neither flag exists in a Release build.
    static func applyAcceptanceLaunchArguments(_ arguments: [String]) {
        let isolated = arguments.contains("--keychain-acceptance")
            || arguments.contains("--keychain-acceptance-denied-read")
        guard isolated else { return }
        let deniedRead: OSStatus? = arguments.contains("--keychain-acceptance-denied-read")
            ? errSecInteractionNotAllowed : nil
        let service = (Bundle.main.bundleIdentifier ?? "com.milindsoni.tiptour") + ".debug-acceptance"
        configureAcceptanceService(service, deniedReadStatus: deniedRead)
        print("🔑 DEBUG keychain acceptance: service=\(service) simulatedReadStatus=\(deniedRead.map { String($0) } ?? "none")")
    }
}
#endif
