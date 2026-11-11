import Foundation
import Security

/// Injectable SecItem boundary. Tests never use the application's credential service.
protocol KeychainBackend {
    func copy(account: String, dataProtection: Bool, interactive: Bool) -> (OSStatus, Data?)
    func write(account: String, data: Data, dataProtection: Bool) -> OSStatus
    func delete(account: String, dataProtection: Bool) -> OSStatus
}

private struct SystemKeychainBackend: KeychainBackend {
    let service: String
    private func query(_ account: String, _ dp: Bool) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
         kSecAttrAccount as String: account, kSecUseDataProtectionKeychain as String: dp]
    }
    func copy(account: String, dataProtection: Bool, interactive: Bool) -> (OSStatus, Data?) {
        var q = query(account, dataProtection)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        if !interactive { q[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUIFail }
        var result: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &result)
        return (status, result as? Data)
    }
    func write(account: String, data: Data, dataProtection: Bool) -> OSStatus {
        let q = query(account, dataProtection)
        let status = SecItemUpdate(q as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        NSLog("AUTH_KEYCHAIN sec=update backend=%@ status=%d", dataProtection ? "dataProtection" : "login", status)
        guard status == errSecItemNotFound else { return status }
        var item = q
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let addStatus = SecItemAdd(item as CFDictionary, nil)
        NSLog("AUTH_KEYCHAIN sec=add backend=%@ status=%d", dataProtection ? "dataProtection" : "login", addStatus)
        return addStatus
    }
    func delete(account: String, dataProtection: Bool) -> OSStatus {
        SecItemDelete(query(account, dataProtection) as CFDictionary)
    }
}

/// One cached session, one canonical backend. Never retries a denied read through another store.
final class KeychainHelper: @unchecked Sendable {
    static let shared = KeychainHelper()
    static let sessionAccount = "ms_auth_session"
    static let legacyAccounts = ["ms_access_token", "ms_refresh_token", "ms_token_expiry", "ms_user_email", "ms_user_name"]
    private let backend: KeychainBackend?
    private let lock = NSLock()
    private var cache: [String: Data] = [:]
    private var hydrated = false
    private var writable = true
    private var canonicalDP = false
    private(set) var copyMatchingCallCount = 0
    private(set) var writeCallCount = 0
    private(set) var deleteCallCount = 0

    init(service: String = "com.shenanigans.sticky-notes", inMemoryOnly: Bool = false,
         backend: KeychainBackend? = nil) {
        self.backend = inMemoryOnly ? nil : (backend ?? SystemKeychainBackend(service: service))
        hydrated = inMemoryOnly
    }

    /// Safe diagnostics: operation/backend/status/cumulative counts ONLY, never values or identity.
    private func record(_ operation: String, dp: Bool, status: OSStatus) {
        NSLog("AUTH_KEYCHAIN op=%@ backend=%@ status=%d reads=%d writes=%d deletes=%d",
              operation, dp ? "dataProtection" : "login", status,
              copyMatchingCallCount, writeCallCount, deleteCallCount)
    }
    private func copy(_ account: String, dp: Bool, interactive: Bool = true) -> (OSStatus, Data?) {
        copyMatchingCallCount += 1
        let result = backend!.copy(account: account, dataProtection: dp, interactive: interactive)
        record(account == Self.sessionAccount ? "sessionRead" : "legacyRead", dp: dp, status: result.0)
        return result
    }
    private func missing(_ status: OSStatus) -> Bool {
        status == errSecItemNotFound || status == errSecMissingEntitlement
    }
    private func hydrateLocked(includeLegacy: Bool = true) {
        guard !hydrated else { return }
        hydrated = true // includes denial: concurrent/repeated reads must not reprompt
        guard backend != nil else { return }
        for dp in [true, false] {
            canonicalDP = dp
            let (status, data) = copy(Self.sessionAccount, dp: dp)
            if status == errSecSuccess {
                guard let data, let decoded = try? JSONDecoder().decode([String: Data].self, from: data) else {
                    writable = false; return // don't overwrite an unreadable session
                }
                canonicalDP = dp
                cache = decoded
                return // no migration write on every launch
            }
            guard missing(status) else { writable = false; return }
        }
        guard includeLegacy else { return }
        // Old per-field entries: bounded known accounts, noninteractive, no service-wide secret dump.
        var legacy: [String: Data] = [:]
        for account in Self.legacyAccounts {
            for dp in [true, false] {
                let (status, data) = copy(account, dp: dp, interactive: false)
                if status == errSecSuccess, let data { legacy[account] = data; break }
                guard missing(status) else { writable = false; return }
            }
        }
        cache = legacy
        if !cache.isEmpty { _ = persistLocked() }
        // Retain legacy entries; no automatic credential deletion or ACL changes.
    }
    @discardableResult
    func update(strings: [String: String]) -> Bool {
        lock.lock(); defer { lock.unlock() }
        hydrateLocked()
        guard writable else { return false }
        let previous = cache
        for (key, value) in strings { cache[key] = Data(value.utf8) }
        if persistLocked() { return true }
        cache = previous
        return false
    }
    /// New interactive login replaces the whole session in one write, without importing
    /// old per-field tokens. This is never used for startup or silent token refresh.
    @discardableResult
    func replaceSession(strings: [String: String]) -> Bool {
        lock.lock(); defer { lock.unlock() }
        hydrateLocked(includeLegacy: false)
        let previous = cache
        cache = strings.mapValues { Data($0.utf8) }
        writable = true
        if persistLocked() { return true }
        cache = previous
        return false
    }
    @discardableResult
    func save(key: String, data: Data) -> Bool {
        lock.lock(); defer { lock.unlock() }
        hydrateLocked()
        guard writable else { return false }
        cache[key] = data
        return persistLocked()
    }
    @discardableResult
    func save(key: String, string: String) -> Bool { save(key: key, data: Data(string.utf8)) }
    func read(key: String) -> Data? {
        lock.lock(); defer { lock.unlock() }
        hydrateLocked(); return cache[key]
    }
    func readString(key: String) -> String? { read(key: key).flatMap { String(data: $0, encoding: .utf8) } }
    @discardableResult
    func delete(key: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        hydrateLocked()
        guard writable else { return false }
        cache.removeValue(forKey: key)
        return persistLocked()
    }
    /// Called only on explicit sign-out. No hydration, no intermediate token rewrites.
    @discardableResult
    func clearAll() -> Bool {
        lock.lock(); defer { lock.unlock() }
        cache.removeAll(); hydrated = true; writable = true
        guard let backend else { return true }
        var success = true
        for account in [Self.sessionAccount] + Self.legacyAccounts {
            for dp in [true, false] {
                deleteCallCount += 1
                let status = backend.delete(account: account, dataProtection: dp)
                record("delete", dp: dp, status: status)
                if status != errSecSuccess && !missing(status) { success = false }
            }
        }
        return success
    }
    private func persistLocked() -> Bool {
        guard let backend else { return true }
        guard writable, let blob = try? JSONEncoder().encode(cache) else { return false }
        writeCallCount += 1
        let status = backend.write(account: Self.sessionAccount, data: blob, dataProtection: canonicalDP)
        record("write", dp: canonicalDP, status: status)
        return status == errSecSuccess
    }
}
