import Foundation
import Security

/// Helper class for managing secure storage in macOS Keychain.
/// Tokens live in a single session item so the system authorization dialog
/// appears at most once; values are cached in-process after the first read.
final class KeychainHelper: @unchecked Sendable {
    static let shared = KeychainHelper()
    static let sessionAccount = "ms_auth_session"

    private let service: String
    private let inMemoryOnly: Bool
    private let lock = NSLock()
    private var cache: [String: Data] = [:]
    private var hydrated = false

    /// Observed by tests; production code does not rely on these counters.
    private(set) var copyMatchingCallCount = 0
    private(set) var writeCallCount = 0

    init(service: String = "com.shenanigans.sticky-notes", inMemoryOnly: Bool = false) {
        self.service = service
        self.inMemoryOnly = inMemoryOnly
        if inMemoryOnly {
            hydrated = true
        }
    }

    // MARK: - Data Operations

    @discardableResult
    func save(key: String, data: Data) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        hydrateLocked()
        cache[key] = data
        return persistSessionLocked()
    }

    func read(key: String) -> Data? {
        lock.lock()
        defer { lock.unlock() }
        hydrateLocked()
        return cache[key]
    }

    @discardableResult
    func delete(key: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        hydrateLocked()
        cache.removeValue(forKey: key)
        // Remove the legacy per-key item if it still exists. The unified
        // session item is rewritten below and is not deleted here.
        if !inMemoryOnly {
            _ = secDelete(account: key, dataProtection: true)
            _ = secDelete(account: key, dataProtection: false)
        }
        return persistSessionLocked()
    }

    // MARK: - String Convenience

    @discardableResult
    func save(key: String, string: String) -> Bool {
        guard let data = string.data(using: .utf8) else { return false }
        return save(key: key, data: data)
    }

    func readString(key: String) -> String? {
        guard let data = read(key: key) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    // MARK: - Clean Up

    /// Clears this app's session cache and unified item.
    /// Legacy per-key items are left untouched unless `delete(key:)` removed them
    /// (used by sign-out). Does not perform a service-wide wipe.
    @discardableResult
    func clearAll() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        cache.removeAll()
        hydrated = true
        if inMemoryOnly { return true }
        let dp = secDelete(account: Self.sessionAccount, dataProtection: true)
        let file = secDelete(account: Self.sessionAccount, dataProtection: false)
        return dp && file
    }

    // MARK: - Session hydrate / persist

    private func hydrateLocked() {
        if hydrated { return }
        if inMemoryOnly {
            hydrated = true
            return
        }

        copyMatchingCallCount += 1
        if let data = secCopy(account: Self.sessionAccount, dataProtection: true),
           let decoded = decodeSession(data) {
            cache = decoded
            hydrated = true
            return
        }

        copyMatchingCallCount += 1
        if let data = secCopy(account: Self.sessionAccount, dataProtection: false),
           let decoded = decodeSession(data) {
            cache = decoded
            hydrated = true
            if let blob = encodeSession(decoded) {
                _ = secWriteUnified(blob, dataProtection: true)
            }
            return
        }

        copyMatchingCallCount += 1
        if let items = secCopyAll(dataProtection: false) {
            for item in items {
                guard let account = item[kSecAttrAccount as String] as? String,
                      let data = item[kSecValueData as String] as? Data else { continue }
                if account == Self.sessionAccount, let decoded = decodeSession(data) {
                    for (key, value) in decoded where cache[key] == nil {
                        cache[key] = value
                    }
                } else if cache[account] == nil {
                    cache[account] = data
                }
            }
        }

        hydrated = true
        if !cache.isEmpty {
            _ = persistSessionLocked()
        }
    }

    @discardableResult
    private func persistSessionLocked() -> Bool {
        if inMemoryOnly { return true }
        if cache.isEmpty {
            let dp = secDelete(account: Self.sessionAccount, dataProtection: true)
            let file = secDelete(account: Self.sessionAccount, dataProtection: false)
            return dp && file
        }
        guard let blob = encodeSession(cache) else { return false }
        let dp = secWriteUnified(blob, dataProtection: true)
        let file = secWriteUnified(blob, dataProtection: false)
        return dp || file
    }

    private func encodeSession(_ values: [String: Data]) -> Data? {
        var payload: [String: String] = [:]
        for (key, value) in values {
            payload[key] = value.base64EncodedString()
        }
        return try? JSONSerialization.data(withJSONObject: payload)
    }

    private func decodeSession(_ data: Data) -> [String: Data]? {
        guard let payload = try? JSONSerialization.jsonObject(with: data) as? [String: String] else {
            return nil
        }
        var values: [String: Data] = [:]
        for (key, encoded) in payload {
            if let decoded = Data(base64Encoded: encoded) {
                values[key] = decoded
            }
        }
        return values
    }

    // MARK: - SecItem

    private func baseQuery(account: String?, dataProtection: Bool) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecUseDataProtectionKeychain as String: dataProtection
        ]
        if let account {
            query[kSecAttrAccount as String] = account
        }
        return query
    }

    private func secCopy(account: String, dataProtection: Bool) -> Data? {
        var query = baseQuery(account: account, dataProtection: dataProtection)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess else { return nil }
        return item as? Data
    }

    private func secCopyAll(dataProtection: Bool) -> [[String: Any]]? {
        var query = baseQuery(account: nil, dataProtection: dataProtection)
        query[kSecReturnData as String] = true
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitAll
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess else { return nil }
        return item as? [[String: Any]]
    }

    @discardableResult
    private func secWriteUnified(_ data: Data, dataProtection: Bool) -> Bool {
        writeCallCount += 1
        let query = baseQuery(account: Self.sessionAccount, dataProtection: dataProtection)
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
        ]
        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess {
            return true
        }
        if updateStatus == errSecItemNotFound {
            var newItem = query
            newItem[kSecValueData as String] = data
            newItem[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            return SecItemAdd(newItem as CFDictionary, nil) == errSecSuccess
        }
        return false
    }

    @discardableResult
    private func secDelete(account: String, dataProtection: Bool) -> Bool {
        let query = baseQuery(account: account, dataProtection: dataProtection)
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }
}
