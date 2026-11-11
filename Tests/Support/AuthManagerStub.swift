import Foundation

/// Injected SyncEngine identity/token provider. Production AuthManager is tested separately
/// with an in-memory credential store and mocked HTTP; neither test path reads real secrets.
@MainActor
@Observable
final class SyncAuthStub: SyncAuthProviding {
    static let shared = SyncAuthStub()

    var accountID: String? = "test-account"
    var sessionGeneration = UUID()
    func ensureAccountID() async throws -> String { accountID ?? "test-account" }

    var isAuthenticated: Bool = true
    var isAuthenticating: Bool = false
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
        accountID = "test-account"
        sessionGeneration = UUID()
        isAuthenticated = true
        isAuthenticating = false
        accessToken = "test-token"
        refreshCallCount = 0
        maxRefreshesBeforeThrow = 10
        refreshShouldFail = false
    }
}
