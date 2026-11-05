import Foundation

/// Test double replacing the production `AuthManager` (StickyNotes/Services/AuthManager.swift is
/// intentionally NOT compiled into the test bundle). It exposes exactly the surface `SyncEngine`
/// uses, so tests never touch the real keychain, the ~/.hermes token file, or Microsoft login.
@MainActor
@Observable
final class AuthManager {
    static let shared = AuthManager()

    var isAuthenticated: Bool = true
    var accessToken: String = "test-token"
    var refreshCallCount = 0
    /// Safety valve so a production code path that retries forever cannot hang the test run.
    var maxRefreshesBeforeThrow = 10
    var refreshShouldFail = false

    func getValidAccessToken() async throws -> String { accessToken }

    func refreshTokens() async throws -> String {
        refreshCallCount += 1
        if refreshShouldFail || refreshCallCount > maxRefreshesBeforeThrow {
            throw NSError(domain: "AuthManagerStub", code: 99,
                          userInfo: [NSLocalizedDescriptionKey: "stub refresh limit reached"])
        }
        return "refreshed-token-\(refreshCallCount)"
    }

    func reset() {
        isAuthenticated = true
        accessToken = "test-token"
        refreshCallCount = 0
        maxRefreshesBeforeThrow = 10
        refreshShouldFail = false
    }
}
