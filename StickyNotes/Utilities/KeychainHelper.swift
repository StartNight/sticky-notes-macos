import Foundation
import Security

/// Injectable SecItem boundary. Tests never use the application's credential service.
/// `dataProtection` is kept for source compatibility; production always passes `false`
/// (the data-protection keychain needs an entitlement this build cannot have).
protocol KeychainBackend: Sendable {
    func copy(account: String, dataProtection: Bool, interactive: Bool) -> (OSStatus, Data?)
    func write(account: String, data: Data, dataProtection: Bool) -> OSStatus
    func delete(account: String, dataProtection: Bool) -> OSStatus
}

/// Outcome of a keychain read attempt. Distinguishes "needs a system prompt" from every other failure.
enum KeychainProbe: Equatable {
    case success
    case notFound
    /// errSecInteractionNotAllowed (-25308) / errSecInteractionRequired (-25315): the system WOULD prompt.
    case needsInteraction
    /// User cancelled (-128) or authorization failed (-25293). Not retried in the same launch.
    case denied(OSStatus)
    case failed(OSStatus)

    static func classify(_ status: OSStatus) -> KeychainProbe {
        switch status {
        case errSecSuccess: return .success
        case errSecItemNotFound: return .notFound
        case errSecInteractionNotAllowed, errSecInteractionRequired: return .needsInteraction
        case errSecUserCanceled, errSecAuthFailed: return .denied(status)
        default: return .failed(status)
        }
    }
}

enum KeychainLoadState: Equatable {
    case idle, ready, needsConsent
    case denied(OSStatus)
    case failed(OSStatus)
}

private struct SystemKeychainBackend: KeychainBackend {
    let service: String
    private func query(_ account: String) -> [String: Any] {
        // Login (file-based) keychain only. No data-protection probe, no kSecAttrAccessible.
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }
    func copy(account: String, dataProtection: Bool, interactive: Bool) -> (OSStatus, Data?) {
        var q = query(account)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        if !interactive { q[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUIFail }
        var result: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &result)
        return (status, result as? Data)
    }
    func write(account: String, data: Data, dataProtection: Bool) -> OSStatus {
        let q = query(account)
        let status = SecItemUpdate(q as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        NSLog("AUTH_KEYCHAIN sec=update status=%d", status)
        guard status == errSecItemNotFound else { return status }
        var item = q
        item[kSecValueData as String] = data
        let addStatus = SecItemAdd(item as CFDictionary, nil)
        NSLog("AUTH_KEYCHAIN sec=add status=%d", addStatus)
        if addStatus == errSecDuplicateItem {
            let retryStatus = SecItemUpdate(q as CFDictionary, [kSecValueData as String: data] as CFDictionary)
            NSLog("AUTH_KEYCHAIN sec=update-retry status=%d", retryStatus)
            return retryStatus
        }
        return addStatus
    }
    func delete(account: String, dataProtection: Bool) -> OSStatus {
        SecItemDelete(query(account) as CFDictionary)
    }
}

/// One cached session, one canonical (login) backend.
///
/// Threading contract: nothing the UI/main thread calls ever waits on the keychain.
///  - `read`/`readString`/`isHydrated`/`loadState` only take a short state lock and never touch SecItem.
///  - Every SecItem call runs under `ioLock`, via the `*Async` entry points on a background queue.
///  - A denied/cancelled read is final for this launch: no retry, no automatic delete/recreate.
final class KeychainHelper: @unchecked Sendable {
    static let shared = KeychainHelper()
    static let sessionAccount = "ms_auth_session"
    static let legacyAccounts = ["ms_access_token", "ms_refresh_token", "ms_token_expiry", "ms_user_email", "ms_user_name"]
    private let backend: KeychainBackend?
    private let stateLock = NSLock()   // protects the fields below; held only briefly, never across SecItem calls
    private let ioLock = NSLock()      // serializes SecItem calls
    private let ioQueue = DispatchQueue(label: "com.shenanigans.sticky-notes.keychain", qos: .userInitiated)
    private var cache: [String: Data] = [:]
    private var hydrated = false
    private var writable = true
    private var state: KeychainLoadState = .idle
    private var interactiveAttempted = false
    private var epoch = 0
    private var _copyCount = 0, _writeCount = 0, _deleteCount = 0
    var copyMatchingCallCount: Int { stateLock.lock(); defer { stateLock.unlock() }; return _copyCount }
    var writeCallCount: Int { stateLock.lock(); defer { stateLock.unlock() }; return _writeCount }
    var deleteCallCount: Int { stateLock.lock(); defer { stateLock.unlock() }; return _deleteCount }

    init(service: String = "com.shenanigans.sticky-notes", inMemoryOnly: Bool = false,
         backend: KeychainBackend? = nil) {
        self.backend = inMemoryOnly ? nil : (backend ?? SystemKeychainBackend(service: service))
        hydrated = inMemoryOnly
        if inMemoryOnly { state = .ready }
    }

    // MARK: Non-blocking state

    var isHydrated: Bool { stateLock.lock(); defer { stateLock.unlock() }; return hydrated }
    var loadState: KeychainLoadState { stateLock.lock(); defer { stateLock.unlock() }; return state }
    /// Apply a probe result only if no sign-out (`discardCache`) happened while the read was in flight.
    private func commit(_ startEpoch: Int, _ body: () -> Void) {
        stateLock.lock(); defer { stateLock.unlock() }
        if epoch == startEpoch { body() }
    }
    private func withState<T>(_ body: () -> T) -> T { stateLock.lock(); defer { stateLock.unlock() }; return body() }
    /// Bumped by `discardCache()`; async writes queued before a sign-out refuse to run afterwards.
    var currentEpoch: Int { withState { epoch } }

    /// Safe diagnostics: operation/status/cumulative counts ONLY, never values or identity.
    private func record(_ operation: String, status: OSStatus) {
        let (reads, writes, deletes) = withState { (_copyCount, _writeCount, _deleteCount) }
        NSLog("AUTH_KEYCHAIN op=%@ status=%d result=%@ reads=%d writes=%d deletes=%d",
              operation, status, String(describing: KeychainProbe.classify(status)), reads, writes, deletes)
    }
    private func copy(_ account: String, interactive: Bool) -> (OSStatus, Data?) {
        withState { _copyCount += 1 }
        let result = backend!.copy(account: account, dataProtection: false, interactive: interactive)
        record((account == Self.sessionAccount ? "sessionRead" : "legacyRead") + (interactive ? "Interactive" : "NonInteractive"), status: result.0)
        return result
    }

    // MARK: Reads (background only)

    /// Startup step 1: never shows UI. Safe to call from any thread except main (it blocks on SecItem).
    func probeNonInteractive() -> KeychainProbe {
        ioLock.lock(); defer { ioLock.unlock() }
        return probeLocked(interactive: false)
    }

    /// Startup step 2, only after the in-app explanation and only once per launch.
    func readInteractive() -> KeychainProbe {
        ioLock.lock(); defer { ioLock.unlock() }
        let allowed = withState { () -> Bool in
            guard state == .needsConsent, !interactiveAttempted else { return false }
            interactiveAttempted = true
            return true
        }
        guard allowed else { return currentProbeResult() }
        return probeLocked(interactive: true)
    }

    /// The user chose not to authorize this launch.
    func declineInteractiveRead() {
        withState {
            interactiveAttempted = true
            hydrated = true; writable = false
            state = .denied(errSecUserCanceled)
        }
        NSLog("AUTH_KEYCHAIN op=consentDeclined status=%d", errSecUserCanceled)
    }

    private func currentProbeResult() -> KeychainProbe {
        withState {
            switch state {
            case .ready: return .success
            case .idle: return .failed(errSecNotAvailable)
            case .needsConsent: return .needsInteraction
            case .denied(let s): return .denied(s)
            case .failed(let s): return .failed(s)
            }
        }
    }

    private func probeLocked(interactive: Bool) -> KeychainProbe {
        guard backend != nil else { return .success }
        let startEpoch = withState { epoch }
        if withState({ hydrated }) { return currentProbeResult() }
        let (status, data) = copy(Self.sessionAccount, interactive: interactive)
        switch KeychainProbe.classify(status) {
        case .success:
            guard let data, let decoded = try? JSONDecoder().decode([String: Data].self, from: data) else {
                commit(startEpoch) { hydrated = true; writable = false; state = .failed(errSecDecode) } // never overwrite an unreadable session
                return .failed(errSecDecode)
            }
            commit(startEpoch) { cache = decoded; hydrated = true; state = .ready }
            return .success
        case .notFound:
            return discoverLegacyLocked(interactive: interactive, startEpoch: startEpoch)
        case .needsInteraction:
            if interactive { // still refused after the user agreed: treat as denied, never loop
                commit(startEpoch) { hydrated = true; writable = false; state = .denied(status) }
                return .denied(status)
            }
            commit(startEpoch) { state = .needsConsent }
            return .needsInteraction
        case .denied(let s):
            commit(startEpoch) { hydrated = true; writable = false; state = .denied(s) }
            return .denied(s)
        case .failed(let s):
            commit(startEpoch) { hydrated = true; writable = false; state = .failed(s) }
            return .failed(s)
        }
    }

    /// Old per-field entries: bounded known accounts, no service-wide dump, never deleted here.
    private func discoverLegacyLocked(interactive: Bool, startEpoch: Int) -> KeychainProbe {
        var legacy: [String: Data] = [:]
        for account in Self.legacyAccounts {
            let (status, data) = copy(account, interactive: interactive)
            switch KeychainProbe.classify(status) {
            case .success: if let data { legacy[account] = data }
            case .notFound: continue
            case .needsInteraction:
                if interactive {
                    commit(startEpoch) { hydrated = true; writable = false; state = .denied(status) }
                    return .denied(status)
                }
                commit(startEpoch) { state = .needsConsent }
                return .needsInteraction
            case .denied(let s):
                commit(startEpoch) { hydrated = true; writable = false; state = .denied(s) }
                return .denied(s)
            case .failed(let s):
                commit(startEpoch) { hydrated = true; writable = false; state = .failed(s) }
                return .failed(s)
            }
        }
        let blob: Data? = legacy.isEmpty ? nil : (try? JSONEncoder().encode(legacy))
        if let blob, withState({ epoch == startEpoch && writable }) {
            _ = writeBlobLocked(blob)
        }
        commit(startEpoch) { cache = legacy; hydrated = true; state = .ready }
        return legacy.isEmpty ? .notFound : .success
    }

    /// Explicit blocking hydrate (background threads / tests). Equivalent to the non-interactive probe.
    @discardableResult
    func hydrateBlocking() -> KeychainProbe { probeNonInteractive() }

    func probeNonInteractiveAsync() async -> KeychainProbe { await onIOQueue { self.probeNonInteractive() } }
    func readInteractiveAsync() async -> KeychainProbe { await onIOQueue { self.readInteractive() } }
    private func onIOQueue<T>(_ work: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { continuation in
            ioQueue.async { continuation.resume(returning: work()) }
        }
    }

    // MARK: Cached reads (never block)

    func read(key: String) -> Data? { withState { cache[key] } }
    func readString(key: String) -> String? { read(key: key).flatMap { String(data: $0, encoding: .utf8) } }

    // MARK: Writes (Prepare -> Write -> Commit under ioLock)

    @discardableResult
    func update(strings: [String: String], requiredEpoch: Int? = nil) -> Bool {
        ioLock.lock(); defer { ioLock.unlock() }
        enum Plan { case abort, noop, write([String: Data], Data, Int) }
        let plan: Plan = withState {
            guard hydrated, writable, requiredEpoch == nil || requiredEpoch == epoch else { return .abort }
            var next = cache
            var didChange = false
            for (key, value) in strings {
                let data = Data(value.utf8)
                if next[key] != data {
                    next[key] = data
                    didChange = true
                }
            }
            if !didChange { return .noop }
            guard let blob = try? JSONEncoder().encode(next) else { return .abort }
            return .write(next, blob, epoch)
        }
        switch plan {
        case .abort: return false
        case .noop: return true
        case .write(let next, let blob, let startEpoch):
            guard writeBlobLocked(blob) else { return false }
            return withState {
                guard hydrated, writable, epoch == startEpoch, requiredEpoch == nil || requiredEpoch == epoch else {
                    return false
                }
                cache = next
                return true
            }
        }
    }
    /// New interactive login replaces the whole session in one write. It does not read the old item
    /// (nothing to merge, no old-token import) and never uses the startup/silent-refresh path.
    @discardableResult
    func replaceSession(strings: [String: String], requiredEpoch: Int? = nil) -> Bool {
        ioLock.lock(); defer { ioLock.unlock() }
        let prepared: ([String: Data], Data, Int)? = withState {
            guard requiredEpoch == nil || requiredEpoch == epoch else { return nil }
            let next = strings.mapValues { Data($0.utf8) }
            guard let blob = try? JSONEncoder().encode(next) else { return nil }
            return (next, blob, epoch)
        }
        guard let (next, blob, startEpoch) = prepared else { return false }
        guard writeBlobLocked(blob) else { return false }
        return withState {
            guard epoch == startEpoch, requiredEpoch == nil || requiredEpoch == epoch else { return false }
            cache = next
            hydrated = true
            writable = true
            state = .ready
            return true
        }
    }
    @discardableResult
    func save(key: String, data: Data) -> Bool {
        ioLock.lock(); defer { ioLock.unlock() }
        let prepared: ([String: Data], Data, Int)? = withState {
            guard hydrated, writable else { return nil }
            var next = cache
            next[key] = data
            guard let blob = try? JSONEncoder().encode(next) else { return nil }
            return (next, blob, epoch)
        }
        guard let (next, blob, startEpoch) = prepared else { return false }
        guard writeBlobLocked(blob) else { return false }
        return withState {
            guard hydrated, writable, epoch == startEpoch else { return false }
            cache = next
            return true
        }
    }
    @discardableResult
    func save(key: String, string: String) -> Bool { save(key: key, data: Data(string.utf8)) }
    @discardableResult
    func delete(key: String) -> Bool {
        ioLock.lock(); defer { ioLock.unlock() }
        let prepared: ([String: Data], Data, Int)? = withState {
            guard hydrated, writable else { return nil }
            var next = cache
            next.removeValue(forKey: key)
            guard let blob = try? JSONEncoder().encode(next) else { return nil }
            return (next, blob, epoch)
        }
        guard let (next, blob, startEpoch) = prepared else { return false }
        guard writeBlobLocked(blob) else { return false }
        return withState {
            guard hydrated, writable, epoch == startEpoch else { return false }
            cache = next
            return true
        }
    }

    func updateAsync(strings: [String: String]) async -> Bool {
        let epoch = currentEpoch
        return await onIOQueue { self.update(strings: strings, requiredEpoch: epoch) }
    }
    func replaceSessionAsync(strings: [String: String]) async -> Bool {
        let epoch = currentEpoch
        return await onIOQueue { self.replaceSession(strings: strings, requiredEpoch: epoch) }
    }

    // MARK: Sign-out / cleanup

    /// Synchronous, memory only: forget the session and invalidate queued writes. No SecItem call.
    /// Returns the new epoch so an asynchronous delete can guard against racing a newer sign-in.
    @discardableResult
    func discardCache() -> Int {
        withState {
            cache.removeAll()
            hydrated = true
            writable = true
            state = .ready
            epoch += 1
            return epoch
        }
    }

    /// Sign-out: removes ONLY the current session item (`ms_auth_session`). Legacy per-field items and
    /// anything else in the keychain are left alone (they are cleaned from Settings after a double confirmation).
    @discardableResult
    func clearAll(requiredEpoch: Int? = nil) -> Bool {
        let targetEpoch: Int
        if let requiredEpoch {
            targetEpoch = requiredEpoch
        } else {
            targetEpoch = discardCache()
        }
        ioLock.lock(); defer { ioLock.unlock() }
        guard withState({ epoch == targetEpoch }) else { return true }
        guard let backend else { return true }
        withState { _deleteCount += 1 }
        let status = backend.delete(account: Self.sessionAccount, dataProtection: false)
        record("sessionDelete", status: status)
        return status == errSecSuccess || status == errSecItemNotFound
    }
    func clearAllAsync(requiredEpoch: Int? = nil) async -> Bool {
        await onIOQueue { self.clearAll(requiredEpoch: requiredEpoch) }
    }

    /// Explicit Settings action (after a two-step confirmation): remove old per-field items from earlier versions.
    @discardableResult
    func clearLegacyItems() -> Bool {
        ioLock.lock(); defer { ioLock.unlock() }
        guard let backend else { return true }
        var success = true
        for account in Self.legacyAccounts {
            withState { _deleteCount += 1 }
            let status = backend.delete(account: account, dataProtection: false)
            record("legacyDelete", status: status)
            if status != errSecSuccess && status != errSecItemNotFound { success = false }
        }
        return success
    }
    func clearLegacyItemsAsync() async -> Bool { await onIOQueue { self.clearLegacyItems() } }

    private func writeBlobLocked(_ blob: Data) -> Bool {
        guard let backend else { return true }
        withState { _writeCount += 1 }
        let status = backend.write(account: Self.sessionAccount, data: blob, dataProtection: false)
        record("write", status: status)
        return status == errSecSuccess
    }
}
