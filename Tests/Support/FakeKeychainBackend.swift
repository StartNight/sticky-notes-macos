import Foundation
import Security

/// Pure memory SecItem model. No operating-system keychain calls.
final class FakeKeychainBackend: KeychainBackend {
    var items: [String: Data] = [:]
    var readStatus: OSStatus?
    var writeStatus: OSStatus = errSecSuccess
    var deleteStatus: OSStatus = errSecSuccess
    var reads: [(String, Bool, Bool)] = []
    var writes: [(String, Bool)] = []
    var deletes: [(String, Bool)] = []
    private func key(_ account: String, _ dp: Bool) -> String { "\(dp):\(account)" }
    func seed(_ strings: [String: String], dp: Bool = false) {
        items[key(KeychainHelper.sessionAccount, dp)] = try! JSONEncoder().encode(strings.mapValues { Data($0.utf8) })
    }
    func copy(account: String, dataProtection: Bool, interactive: Bool) -> (OSStatus, Data?) {
        reads.append((account, dataProtection, interactive))
        if let readStatus { return (readStatus, nil) }
        let data = items[key(account, dataProtection)]
        return (data == nil ? errSecItemNotFound : errSecSuccess, data)
    }
    func write(account: String, data: Data, dataProtection: Bool) -> OSStatus {
        writes.append((account, dataProtection))
        if writeStatus == errSecSuccess { items[key(account, dataProtection)] = data }
        return writeStatus
    }
    func delete(account: String, dataProtection: Bool) -> OSStatus {
        deletes.append((account, dataProtection))
        if deleteStatus == errSecSuccess { items.removeValue(forKey: key(account, dataProtection)) }
        return deleteStatus
    }
}
