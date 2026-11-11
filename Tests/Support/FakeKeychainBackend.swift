import Foundation
import Security

/// Pure memory SecItem model. No operating-system keychain calls.
final class FakeKeychainBackend: KeychainBackend, @unchecked Sendable {
    private let lock = NSLock()
    private var _items: [String: Data] = [:]
    private var _reads: [(String, Bool, Bool)] = []
    private var _writes: [(String, Bool)] = []
    private var _deletes: [(String, Bool)] = []
    var items: [String: Data] { get { lock.lock(); defer { lock.unlock() }; return _items } set { lock.lock(); _items = newValue; lock.unlock() } }
    var reads: [(String, Bool, Bool)] { lock.lock(); defer { lock.unlock() }; return _reads }
    var writes: [(String, Bool)] { lock.lock(); defer { lock.unlock() }; return _writes }
    var deletes: [(String, Bool)] { lock.lock(); defer { lock.unlock() }; return _deletes }
    /// Applies to every read.
    var readStatus: OSStatus?
    /// Applies only to non-interactive reads (e.g. -25308 "would prompt").
    var nonInteractiveStatus: OSStatus?
    /// Applies only to interactive reads (e.g. -128 user cancelled).
    var interactiveStatus: OSStatus?
    var writeStatus: OSStatus = errSecSuccess
    var deleteStatus: OSStatus = errSecSuccess
    /// When set, `copy` signals `entered` and then blocks until `gate` is signalled (simulates a hung prompt).
    var gate: DispatchSemaphore?
    var entered: DispatchSemaphore?
    private func key(_ account: String, _ dp: Bool = false) -> String { "\(dp):\(account)" }
    func seed(_ strings: [String: String], dp: Bool = false) {
        lock.lock(); defer { lock.unlock() }
        _items[key(KeychainHelper.sessionAccount, dp)] = try! JSONEncoder().encode(strings.mapValues { Data($0.utf8) })
    }
    func seedRaw(account: String, _ value: String) {
        lock.lock(); defer { lock.unlock() }
        _items[key(account)] = Data(value.utf8)
    }
    func hasItem(_ account: String) -> Bool { lock.lock(); defer { lock.unlock() }; return _items[key(account)] != nil }
    func copy(account: String, dataProtection: Bool, interactive: Bool) -> (OSStatus, Data?) {
        lock.lock(); _reads.append((account, dataProtection, interactive)); lock.unlock()
        entered?.signal()
        gate?.wait()
        if let readStatus { return (readStatus, nil) }
        if interactive, let interactiveStatus { return (interactiveStatus, nil) }
        if !interactive, let nonInteractiveStatus { return (nonInteractiveStatus, nil) }
        lock.lock(); defer { lock.unlock() }
        let data = _items[key(account, dataProtection)]
        return (data == nil ? errSecItemNotFound : errSecSuccess, data)
    }
    func write(account: String, data: Data, dataProtection: Bool) -> OSStatus {
        lock.lock(); defer { lock.unlock() }
        _writes.append((account, dataProtection))
        if writeStatus == errSecSuccess { _items[key(account, dataProtection)] = data }
        return writeStatus
    }
    func delete(account: String, dataProtection: Bool) -> OSStatus {
        lock.lock(); defer { lock.unlock() }
        _deletes.append((account, dataProtection))
        if deleteStatus == errSecSuccess { _items.removeValue(forKey: key(account, dataProtection)) }
        return deleteStatus
    }
}
