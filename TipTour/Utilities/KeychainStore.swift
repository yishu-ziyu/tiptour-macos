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
//  ever saved", "the item is stored but this process has not read it",
//  "macOS refused to read the key that is there" and "the stored key cannot be
//  decoded" are different problems with different remedies, and collapsing
//  them into one "please save your key" message is what sent users in circles
//  after they had already saved a key.
//

import Foundation
import LocalAuthentication
import Security

/// What the Keychain actually says about one stored provider key.
///
/// An item the user already saved must never be reported as "not saved", and a
/// key that was never saved must never be reported as a read failure. Both
/// mistakes are avoided by carrying the state instead of a `String?`.
///
/// Existence and readability are two separate facts, so they get two separate
/// cases: `saved` means an attributes-only query found the item without ever
/// handing its secret to this process, while `available` means this process
/// actually holds a non-empty, decodable value. Only `available` licenses
/// "usable", and `itemExists` is only ever a positive claim.
enum KeychainItemState: Equatable {
    /// A non-empty, decodable value was actually obtained in this process:
    /// either a read returned bytes that decode to a UTF-8 string, or the value
    /// is still in the in-process cache from an earlier successful read or
    /// write. This is the only state that proves the key is usable right now.
    case available
    /// The item is stored, but its secret was never read: an attributes-only
    /// presence query found it. That query asks for no data, decrypts nothing
    /// and opens no prompt, so existence is proven while readability is not.
    /// Reported as "saved", never as "usable".
    case saved
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

    /// True when a stored item is positively proven to exist, whether or not it
    /// can be read right now. A key the user already saved is a key the app
    /// cannot claim is missing.
    ///
    /// The proof has to come from the state itself: `.absent` and `.unavailable`
    /// are the two states that do not prove anything (nothing was ever stored,
    /// or the lookup did not settle), so a state that merely failed to disprove
    /// existence must never be reported as holding an item.
    var itemExists: Bool {
        switch self {
        case .available, .saved, .readDenied, .undecodable: return true
        case .absent, .unavailable: return false
        }
    }

    /// True only when this process can actually use the stored value.
    var isUsable: Bool {
        self == .available
    }

    /// The OSStatus behind a failed lookup, for logs and for the user-facing
    /// copy. Never anything taken from the item itself.
    var failureStatus: OSStatus {
        switch self {
        case .available, .saved: return errSecSuccess
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
        case .saved: return "saved (item exists, secret not read)"
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
        case .saved: return "密钥已保存在 macOS 钥匙串（尚未读取验证）"
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
    /// never drift apart. The failures never share a sentence: "nothing was
    /// saved" asks for a save, "the item is saved but unread" keeps the save
    /// fact while saying the value is not in hand yet, "macOS refused the read"
    /// says the key is already saved and points at the authorization, and "the
    /// stored bytes are not usable text" asks for a single re-save. The old
    /// single sentence — "未读到阶跃密钥：请在「设置 → 模型」保存密钥后重试" — was
    /// wrong for the middle cases, which are exactly the users who had already
    /// saved a key and were told to save it again.
    func userMessage(subject: String) -> String {
        switch self {
        case .available: return "\(subject)已保存。"
        case .saved:
            return "\(subject)已保存在 macOS 钥匙串（尚未读取验证）：条目确实存在，是否可用要等这次实际读取到密钥才能确认。"
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
    ///
    /// `errSecSuccess` here means an actual *read* succeeded and the value is
    /// in hand. A presence query, which proves existence without decrypting
    /// anything, maps through `presenceState(for:)` instead.
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

    /// Map the OSStatus of an attributes-only presence query onto a state.
    ///
    /// That query asks for no `kSecReturnData`, so nothing is decrypted and no
    /// prompt is opened: a success proves the item is stored and says nothing
    /// about whether this process may read it. Success therefore maps to
    /// `.saved`, never to `.available`. Every other status means the same thing
    /// it means for a read — including `.readDenied`, which proves an item is
    /// there precisely because macOS refused to hand it over.
    static func presenceState(for status: OSStatus) -> KeychainItemState {
        switch status {
        case errSecSuccess: return .saved
        default: return state(for: status)
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
    /// (see the DEBUG-only acceptance seam at the end of this file).
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

    /// Accounts whose NEXT actual read is owed a simulated
    /// `errSecInteractionNotAllowed` (-25308). Empty unless a DEBUG acceptance
    /// run armed one, and an account leaves the set the moment its refusal
    /// fires — one injection per arming, never a sticky state, so the read
    /// after it is a real one that can succeed and prove the recovery path.
    ///
    /// The status itself is a real Security framework constant
    /// (`errSecInteractionNotAllowed`), so the product's state mapping and its
    /// user-facing copy run against a genuine value; what is simulated is the
    /// operating system refusing this process, not the status. Measured on this
    /// machine: a legacy ACL / trusted-application list and an ad-hoc code
    /// signature both fail to restrict a generic-password read, so no terminal
    /// command can produce this state without the signed app.
    ///
    /// Only `readItem` ever consults this set. An attributes/presence query
    /// requests no `kSecReturnData`, decrypts nothing and opens no prompt, so
    /// it is not a read and must keep succeeding — that is what lets the
    /// settings cards keep proving "saved" while the read is refused.
    nonisolated(unsafe) private static var armedReadDenials: Set<String> = []
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
        // DEBUG acceptance only: an armed account's NEXT actual read fails as
        // if macOS had refused this process, and the arm is consumed by firing
        // it — one injection per arming, so the read after it is a real one
        // that may succeed and prove the recovery path.
        //
        // The check sits above the in-process cache on purpose: the simulated
        // state is "this process cannot obtain the value at all", and a
        // remembered value would quietly defeat it. See `armedReadDenials`.
        if armedReadDenials.remove(key) != nil {
            return (nil, .readDenied(errSecInteractionNotAllowed))
        }
        #endif
        // A remembered value is one this process already obtained, so it still
        // counts as an actual read: the bytes were decoded here and are usable
        // here.
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
            // `.available` promises a value this process can actually use, so
            // the bytes must decode *and* be non-empty: stored data that
            // decodes to nothing is an unreadable item, not a usable key.
            guard let data = item as? Data,
                  let string = String(data: data, encoding: .utf8),
                  !string.isEmpty
            else {
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
    ///
    /// Success here proves existence only, so it answers `.saved`: this process
    /// has not read the secret and must not be told the key is usable. The one
    /// exception is the in-process cache, whose value was read (or written)
    /// here, so a cached item really is `.available`.
    ///
    /// A DEBUG read-denial arm is deliberately *not* consulted here (unlike
    /// `readItem`): this query is an attributes-only probe, not a read, so an
    /// armed refusal must not change its answer. That is what keeps the
    /// acceptance loop honest — while the next read is refused, opening the
    /// settings cards still proves the item is saved without ever claiming it
    /// is readable.
    static func presence(forKey key: String) -> KeychainItemState {
        // The process already holds this value, so presence can honestly claim
        // readability here — no Keychain trip, no prompt, no second decrypt.
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
        return KeychainItemState.presenceState(for: SecItemCopyMatching(query as CFDictionary, nil))
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
    /// Skipped while a DEBUG acceptance refusal is armed for that key: the cache
    /// is what lets a later lookup succeed without a Keychain trip, and the
    /// simulated state is "this process cannot obtain the value at all" — a
    /// remembered value would quietly defeat it, and a presence probe served
    /// from memory would answer `.available` while the read is refused.
    private static func remember(_ value: String, forKey key: String) {
        #if DEBUG
        // Do not remember a value written while a refusal is armed: a later
        // lookup has to keep reporting it, not serve it from memory.
        guard !armedReadDenials.contains(key) else { return }
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
    /// The launch argument that arms a one-shot read denial. Kept as a constant
    /// so the flag and its `=<account>` form can never drift apart.
    private static let denialFlag = "--keychain-acceptance-deny-next-read"

    /// The accounts every provider key lives under, taken from the one place
    /// that names them (`TipTourMode.keyName`), so arming can never cover a
    /// different set of items than the app actually reads.
    static var acceptanceKeyNames: [String] { TipTourMode.allCases.map(\.keyName) }

    /// Point every provider-key access at an isolated service.
    ///
    /// Call once, before any key is touched: it also drops the in-process
    /// cache, because cached values belong to whichever configuration was
    /// active when they were read or written.
    static func configureAcceptanceService(_ service: String?) {
        acceptanceServiceOverride = service
        // Cached values belong to whichever configuration was active when they
        // were read or written.
        unlockedValues.removeAllObjects()
    }

    /// Arm the NEXT actual read of `key` to fail with
    /// `errSecInteractionNotAllowed` (-25308) — the real Security constant for
    /// "macOS refused this interaction", so the product's state mapping and its
    /// user-facing copy run against a genuine value.
    ///
    /// One-shot by design: `readItem` consumes the arm as it fires, so the very
    /// next read is a real one that can succeed and prove the recovery path.
    /// Attributes-only presence queries are never affected, so "the item is
    /// saved" stays provable while the read is refused, and nothing here can
    /// fire in a build compiled without `DEBUG`.
    static func armNextReadDenial(forKey key: String) {
        armedReadDenials.insert(key)
        // Drop a value this process already remembers for that account: the
        // simulated state is "this process cannot obtain the value at all", so
        // a cached value would quietly defeat it, and a presence probe answered
        // from memory would claim `.available` while the read is refused.
        // Clearing it here also makes the arm order-independent — arming before
        // the save (the launch-argument flow) or after it behaves the same.
        unlockedValues.removeObject(forKey: cacheKey(key))
    }

    /// Whether an armed refusal is still owed for `key`.
    static func isReadDenialArmed(forKey key: String) -> Bool {
        armedReadDenials.contains(key)
    }

    /// One line naming the seam this process is running with: the service every
    /// lookup goes to, whether it is the isolated acceptance service, and the
    /// accounts still owed a refusal. The acceptance log needs the injection
    /// source printed next to the real OSStatus the UI shows; nothing here can
    /// name a stored value.
    static var acceptanceSeamSummary: String {
        let armed = armedReadDenials.sorted().joined(separator: ",")
        return "service=\(serviceName) isolated=\(acceptanceServiceOverride != nil) denialArmedFor=\(armed.isEmpty ? "none" : armed)"
    }

    /// Read the DEBUG acceptance flags out of the launch arguments.
    ///
    /// `--keychain-acceptance` isolates every provider-key access under
    /// `<bundle id>.debug-acceptance`, so no acceptance step can read, write or
    /// delete the user's real `stepfunAPIKey` / `jevAPIKey`.
    /// `--keychain-acceptance-deny-next-read` implies it and arms the one-shot
    /// read denial for every provider account; append `=<account>` (for example
    /// `--keychain-acceptance-deny-next-read=jevAPIKey`) to refuse exactly one
    /// provider's next read and leave the others readable.
    ///
    /// The denial is armed, not permanent: it fires on the NEXT actual read of
    /// an armed account, consumes itself, and never touches an attributes or
    /// presence query — the settings cards must keep proving the item is saved
    /// while that read is refused.
    ///
    /// Run the denial flag only with a key already saved under the acceptance
    /// service: a refusal proves an item is there precisely because macOS
    /// refuses to hand it over, so arming it with nothing stored would report a
    /// refusal there is no item to refuse.
    ///
    /// Neither flag exists in a Release build.
    static func applyAcceptanceLaunchArguments(_ arguments: [String]) {
        let isolated = arguments.contains("--keychain-acceptance")
            || arguments.contains { $0 == denialFlag || $0.hasPrefix(denialFlag + "=") }
        guard isolated else { return }
        configureAcceptanceService((Bundle.main.bundleIdentifier ?? "com.milindsoni.tiptour") + ".debug-acceptance")

        var armed: [String] = []
        if let requested = arguments.first(where: { $0.hasPrefix(denialFlag + "=") }) {
            // `=account` refuses one provider's read; a bare `=` falls back to
            // every account rather than silently arming nothing.
            let account = String(requested.dropFirst(denialFlag.count + 1))
            armed = account.isEmpty ? acceptanceKeyNames : [account]
        } else if arguments.contains(denialFlag) {
            armed = acceptanceKeyNames
        }
        armed.forEach(armNextReadDenial)

        print("🔑 DEBUG keychain acceptance: \(acceptanceSeamSummary) simulatedReadStatus=\(armed.isEmpty ? "none" : String(errSecInteractionNotAllowed))")
    }
}
#endif
