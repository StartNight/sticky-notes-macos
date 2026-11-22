import Foundation
import AuthenticationServices
import CryptoKit
import SwiftUI

@MainActor
protocol SyncAuthProviding: AnyObject {
    var isAuthenticated: Bool { get }
    var isAuthenticating: Bool { get }
    var isRestoringSession: Bool { get }
    var accountID: String? { get }
    var sessionGeneration: UUID { get }
    func getValidAccessToken() async throws -> String
    func refreshTokens() async throws -> String
    func ensureAccountID() async throws -> String
    /// True only after `accountID` was confirmed against Graph `/me.id` in this launch/session. A cached id read
    /// from the keychain at startup is provisional (may be shown/edited locally) but never authorises cloud
    /// reads/writes, adoption or claims until this is true.
    var isIdentityVerified: Bool { get }
}

extension SyncAuthProviding {
    var isAuthenticating: Bool { false }
    var isRestoringSession: Bool { false }
    var isIdentityVerified: Bool { true }
    /// What local data may be shown/edited/synced right now. Derived only from verified identity.
    var activeScope: ActiveScope {
        ActiveScope.resolve(isAuthenticated: isAuthenticated, isAuthenticating: isAuthenticating || isRestoringSession, accountID: accountID)
    }
}

@MainActor
@Observable
final class AuthManager: NSObject, SyncAuthProviding {
    static let shared = AuthManager()

    // MARK: - Published State
    var isAuthenticated: Bool = false
    var userName: String? = nil
    var userEmail: String? = nil
    var isAuthenticating: Bool = false
    var lastAuthError: String? = nil

    /// Startup keychain restore. While it is `.loading`/`.needsConsent` the identity is unconfirmed, so the
    /// active scope is `.blocked` (no account data shown). It never blocks the main thread.
    enum RestoreState: Equatable {
        case idle, loading, needsConsent, done
        case denied(Int32)
        case failed(Int32)
    }
    private(set) var restoreState: RestoreState = .idle
    var isRestoringSession: Bool { restoreState == .loading || restoreState == .needsConsent }
    var needsKeychainExplanation: Bool { restoreState == .needsConsent }
    private(set) var restoreTask: Task<Void, Never>?
    private(set) var keychainWork: Task<Void, Never>?

    // MARK: - Configuration
    var clientId: String {
        get {
            UserDefaults.standard.string(forKey: "ms_client_id") ?? "913bf285-76cb-4cfa-be2c-790c382ea428"
        }
        set {
            UserDefaults.standard.set(newValue, forKey: "ms_client_id")
        }
    }

    var redirectUri: String {
        get {
            UserDefaults.standard.string(forKey: "ms_redirect_uri") ?? "msauth.com.shenanigans.sticky-notes://auth"
        }
        set {
            UserDefaults.standard.set(newValue, forKey: "ms_redirect_uri")
        }
    }

    var callbackScheme: String {
        let uri = redirectUri
        if let scheme = uri.components(separatedBy: "://").first, !scheme.isEmpty {
            return scheme
        }
        return "msauth.com.shenanigans.sticky-notes"
    }

    private let scopes = "Mail.ReadWrite ShortNotes.ReadWrite offline_access User.Read"
    private let keychain: KeychainHelper
    private let defaults: UserDefaults
    private let network: URLSession
    private(set) var accountID: String?
    /// True once `accountID` has been confirmed against Graph `/me.id` in this launch/session.
    private(set) var identityVerified = false
    var isIdentityVerified: Bool { identityVerified }
    /// The token's `/me.id` differs from the account id cached in the keychain: identity is NOT confirmed, the scope
    /// is blocked (no content shown) until the user signs out/in. Nothing is deleted or rewritten automatically.
    private(set) var identityMismatch = false
    private(set) var identityVerificationTask: Task<Void, Never>?
    private let verifyIdentityAfterRestore: Bool

    // Refresh throttling (follow-up #6). `refreshTask` already merges CONCURRENT calls; these merge SEQUENTIAL ones.
    private let now: () -> Date
    /// A 401/403 right after a successful refresh is not token expiry; reuse the fresh token instead of refreshing again.
    let refreshCooldown: TimeInterval
    private var lastRefreshSuccess: Date?
    private var refreshFailureCount = 0
    private var refreshBackoffUntil: Date?
    static let refreshBackoffBase: TimeInterval = 30
    static let refreshBackoffCap: TimeInterval = 900
    private(set) var refreshNetworkCallCount = 0
    private(set) var sessionGeneration = UUID()
    private var refreshTask: Task<String, Error>?
    private var identityTask: Task<String, Error>?
    private let kAccountID = "ms_graph_account_id"
    static let usesEphemeralSession = true
    private var currentAuthSession: ASWebAuthenticationSession?
    /// Test seam: replaces the system web-auth sheet. Receives (authorization URL, callback scheme) and returns the
    /// callback URL, or throws (e.g. the user cancelled). Production leaves it nil.
    var authSessionRunner: (@MainActor (URL, String) async throws -> URL)?

    /// What the UI/sync layer saw before a sign-in attempt began. Used to put things back if the attempt is cancelled
    /// or fails BEFORE any new session was stored, so "cancel" never leaves the UI signed out while the stored session
    /// (still valid in the keychain) would silently sign the user back in on next launch.
    private struct SessionSnapshot {
        let isAuthenticated: Bool
        let userName: String?
        let userEmail: String?
        let accountID: String?
        let identityVerified: Bool
    }

    // Keychain Keys
    private let kAccessToken = "ms_access_token"
    private let kRefreshToken = "ms_refresh_token"
    private let kTokenExpiry = "ms_token_expiry"
    private let kUserEmail = "ms_user_email"
    private let kUserName = "ms_user_name"

    init(keychain: KeychainHelper = .shared, defaults: UserDefaults = .standard,
         network: URLSession = .shared, loadStoredAuth: Bool = true, verifyIdentityAfterRestore: Bool = true,
         refreshCooldown: TimeInterval = 60, now: @escaping () -> Date = Date.init) {
        self.verifyIdentityAfterRestore = verifyIdentityAfterRestore
        self.refreshCooldown = refreshCooldown
        self.now = now
        self.keychain = keychain
        self.defaults = defaults
        self.network = network
        super.init()
        if loadStoredAuth { beginRestore() }
    }

    // MARK: - Startup restore (background keychain read)

    func beginRestore() {
        NSLog("AUTH_FLOW phase=restore")
        guard !defaults.bool(forKey: "ms_explicitly_signed_out") else { restoreState = .done; return }
        if keychain.isHydrated { applyStoredAuth(); restoreState = .done; startIdentityVerification(); return } // memory only, no I/O
        restoreState = .loading
        let generation = sessionGeneration
        restoreTask = Task { [weak self] in
            guard let self else { return }
            let result = await self.keychain.probeNonInteractiveAsync()
            self.finishRestore(result, generation: generation)
        }
    }

    /// The in-app explanation was acknowledged: the one allowed interactive read for this launch.
    func confirmKeychainAccess() async {
        guard restoreState == .needsConsent else { return }
        restoreState = .loading
        let generation = sessionGeneration
        let result = await keychain.readInteractiveAsync()
        finishRestore(result, generation: generation)
    }

    /// The user declined: no read this launch, nothing deleted or recreated.
    func declineKeychainAccess() {
        guard restoreState == .needsConsent else { return }
        keychain.declineInteractiveRead()
        restoreState = .denied(Int32(errSecUserCanceled))
        lastAuthError = "已取消钥匙串授权；本次启动不再重试，未改动任何钥匙串项或便笺。可重新登录，或重启 App 后授权。"
    }

    func waitForRestore() async { await restoreTask?.value }
    func waitForIdentityVerification() async { await identityVerificationTask?.value }

    /// Startup: the cached account id is only a hint. Re-check it against `/me.id` in the background; sync, adoption
    /// and claims wait for the result (see `isIdentityVerified`). Failures to reach Graph leave it provisional.
    private func startIdentityVerification() {
        guard verifyIdentityAfterRestore, isAuthenticated, let cached = accountID, !cached.isEmpty,
              !identityVerified, !identityMismatch, identityVerificationTask == nil else { return }
        identityVerificationTask = Task { [weak self] in
            guard let self else { return }
            _ = try? await self.ensureAccountID()
            self.identityVerificationTask = nil
        }
    }
    func waitForKeychainWork() async { await keychainWork?.value }

    private func finishRestore(_ result: KeychainProbe, generation: UUID) {
        guard sessionGeneration == generation else { return } // signed out / signed in meanwhile
        switch result {
        case .success, .notFound:
            applyStoredAuth()
            restoreState = .done
            startIdentityVerification()
            if isAuthenticated { NotificationCenter.default.post(name: .requestModelContextSync, object: nil) }
        case .needsInteraction:
            restoreState = .needsConsent
        case .denied(let status):
            restoreState = .denied(status)
            lastAuthError = "钥匙串授权被拒绝或取消（状态 \(status)）；本次启动不再重试，未改动任何钥匙串项或便笺。"
        case .failed(let status):
            restoreState = .failed(status)
            lastAuthError = "无法读取钥匙串（状态 \(status)）；本次启动不再重试，未改动任何钥匙串项或便笺。"
        }
    }

    private func applyStoredAuth() {
        if let token = keychain.readString(key: kAccessToken), !token.isEmpty {
            isAuthenticated = true
            userEmail = keychain.readString(key: kUserEmail)
            userName = keychain.readString(key: kUserName)
            accountID = keychain.readString(key: kAccountID).flatMap { $0.isEmpty ? nil : $0 }
            identityVerified = false   // cached id = provisional until /me confirms it
            identityMismatch = false
        }
        // No automatic developer-token-file import: sign-out must survive relaunch.
    }

    func authorizationURL(state: String, challenge: String) throws -> URL {
        var components = URLComponents(string: "https://login.microsoftonline.com/common/oauth2/v2.0/authorize")!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: clientId),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "redirect_uri", value: redirectUri),
            URLQueryItem(name: "response_mode", value: "query"),
            URLQueryItem(name: "scope", value: scopes),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "prompt", value: "select_account")
        ]
        guard let url = components.url else { throw CancellationError() }
        return url
    }

    private func requireGeneration(_ generation: UUID) throws {
        guard sessionGeneration == generation else { throw CancellationError() }
    }

    // MARK: - OAuth PKCE Sign In

    func signIn() async throws {
        NSLog("AUTH_FLOW phase=login")
        guard !isAuthenticating else { throw CancellationError() }
        let previous = SessionSnapshot(isAuthenticated: isAuthenticated, userName: userName, userEmail: userEmail,
                                       accountID: accountID, identityVerified: identityVerified)
        sessionGeneration = UUID()
        let generation = sessionGeneration
        refreshTask?.cancel()
        refreshTask = nil
        identityTask?.cancel()
        identityTask = nil
        accountID = nil
        identityVerified = false
        identityMismatch = false
        resetRefreshThrottle()
        isAuthenticated = false
        isAuthenticating = true
        lastAuthError = nil
        defer { if sessionGeneration == generation { isAuthenticating = false; currentAuthSession = nil } }

        do {
        // 1. Generate PKCE parameters
        let codeVerifier = try generateCodeVerifier()
        let codeChallenge = generateCodeChallenge(from: codeVerifier)
        let state = try generateOAuthState()

        let authURL = try authorizationURL(state: state, challenge: codeChallenge)

        // 3. Launch ASWebAuthenticationSession
        let callbackURL: URL
        if let runner = authSessionRunner {
            callbackURL = try await runner(authURL, callbackScheme)
        } else {
            callbackURL = try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(
                url: authURL,
                callbackURLScheme: callbackScheme
            ) { callbackURL, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let callbackURL {
                    continuation.resume(returning: callbackURL)
                } else {
                    continuation.resume(throwing: NSError(domain: "AuthManager", code: -2, userInfo: [NSLocalizedDescriptionKey: "Unknown authentication error"]))
                }
            }

            session.presentationContextProvider = self
            session.prefersEphemeralWebBrowserSession = Self.usesEphemeralSession
            self.currentAuthSession = session
            if !session.start() {
                continuation.resume(throwing: NSError(domain: "AuthManager", code: -2,
                    userInfo: [NSLocalizedDescriptionKey: "无法启动微软登录窗口"]))
            }
            }
        }

        try requireGeneration(generation)

        // 4. Parse Callback & Exchange Code
        guard let urlComponents = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false) else {
            throw NSError(domain: "AuthManager", code: -3, userInfo: [NSLocalizedDescriptionKey: "Invalid callback URL"])
        }

        if let error = urlComponents.queryItems?.first(where: { $0.name == "error" })?.value {
            let errorDesc = urlComponents.queryItems?.first(where: { $0.name == "error_description" })?.value ?? error
            throw NSError(domain: "AuthManager", code: -4, userInfo: [NSLocalizedDescriptionKey: errorDesc])
        }

        guard let returnedState = urlComponents.queryItems?.first(where: { $0.name == "state" })?.value,
              returnedState == state else {
            throw NSError(domain: "AuthManager", code: -5, userInfo: [NSLocalizedDescriptionKey: "State mismatch (CSRF warning)"])
        }

        guard let authCode = urlComponents.queryItems?.first(where: { $0.name == "code" })?.value else {
            throw NSError(domain: "AuthManager", code: -6, userInfo: [NSLocalizedDescriptionKey: "No authorization code returned"])
        }

        // 5. Exchange code for access & refresh tokens and verify identity before writing to keychain once
        try await exchangeAuthCode(authCode, codeVerifier: codeVerifier)
        try requireGeneration(generation)
        defaults.set(false, forKey: "ms_explicitly_signed_out")
        } catch {
            restorePreviousSession(previous, afterFailureIn: generation, error: error)
            throw error
        }
    }

    /// Cancel / failure before a new session was stored: show exactly what was there before (the stored session was
    /// never touched, so this is also what the next launch will restore). Never restores over a sign-out or a newer
    /// sign-in that happened meanwhile, and never after the new session replaced the old one.
    private func restorePreviousSession(_ previous: SessionSnapshot, afterFailureIn generation: UUID, error: Error) {
        guard sessionGeneration == generation, !isAuthenticated, previous.isAuthenticated else { return }
        isAuthenticated = true
        userName = previous.userName
        userEmail = previous.userEmail
        accountID = previous.accountID
        identityVerified = previous.identityVerified
        NSLog("AUTH_FLOW phase=login-cancelled-restored")
        NotificationCenter.default.post(name: .requestModelContextSync, object: nil)
    }

    // MARK: - Token Exchange

    private func exchangeAuthCode(_ code: String, codeVerifier: String) async throws {
        guard let tokenURL = URL(string: "https://login.microsoftonline.com/common/oauth2/v2.0/token") else {
            throw NSError(domain: "AuthManager", code: -7, userInfo: [NSLocalizedDescriptionKey: "Invalid token endpoint"])
        }

        var request = URLRequest(url: tokenURL)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        let params: [String: String] = [
            "client_id": clientId,
            "grant_type": "authorization_code",
            "code": code,
            "redirect_uri": redirectUri,
            "code_verifier": codeVerifier,
            "scope": scopes
        ]

        request.httpBody = params
            .map { "\($0.key.addingPercentEncoding(withAllowedCharacters: Self.formAllowed) ?? $0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: Self.formAllowed) ?? $0.value)" }
            .joined(separator: "&")
            .data(using: .utf8)

        let generation = sessionGeneration
        let (data, response) = try await network.data(for: request)
        try requireGeneration(generation)
        guard let httpResponse = response as? HTTPURLResponse, (200...299).contains(httpResponse.statusCode) else {
            let errorText = "HTTP \((response as? HTTPURLResponse)?.statusCode ?? -1)"
            throw NSError(domain: "AuthManager", code: -8, userInfo: [NSLocalizedDescriptionKey: "Token exchange failed: \(errorText)"])
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let accessToken = json["access_token"] as? String else {
            throw NSError(domain: "AuthManager", code: -9, userInfo: [NSLocalizedDescriptionKey: "Invalid token response format"])
        }

        let (meData, meResponse) = try await fetchMeProfile(token: accessToken)
        try requireGeneration(generation)
        guard (meResponse as? HTTPURLResponse)?.statusCode == 200,
              let meJSON = try JSONSerialization.jsonObject(with: meData) as? [String: Any],
              let id = meJSON["id"] as? String, !id.isEmpty else {
            throw NSError(domain: "AuthManager", code: -14, userInfo: [NSLocalizedDescriptionKey: "无法确认微软账号身份，已暂停同步。"])
        }
        let name = meJSON["displayName"] as? String ?? ""
        let email = (meJSON["mail"] as? String) ?? (meJSON["userPrincipalName"] as? String) ?? ""

        var values = [kAccessToken: accessToken, kRefreshToken: json["refresh_token"] as? String ?? "",
                      kAccountID: id, kUserEmail: email, kUserName: name]
        let seconds = (json["expires_in"] as? Double) ?? 3600
        values[kTokenExpiry] = String(Date().addingTimeInterval(seconds).timeIntervalSince1970)
        let saved = await keychain.replaceSessionAsync(strings: values)
        try requireGeneration(generation)
        guard saved else {
            throw NSError(domain: "AuthManager", code: -13, userInfo: [NSLocalizedDescriptionKey: "无法保存登录会话，请检查钥匙串授权。"])
        }

        self.isAuthenticated = true
        self.identityVerified = true
        self.identityMismatch = false
        self.accountID = id
        self.userName = name
        self.userEmail = email
    }

    // MARK: - Token Refresh & Acquisition

    func getValidAccessToken() async throws -> String {
        guard let token = keychain.readString(key: kAccessToken) else {
            self.isAuthenticated = false
            throw NSError(domain: "AuthManager", code: 401, userInfo: [NSLocalizedDescriptionKey: "Not authenticated"])
        }

        let isExpired: Bool
        if let expiryStr = keychain.readString(key: kTokenExpiry),
           let expiryTimestamp = Double(expiryStr) {
            let expiryDate = Date(timeIntervalSince1970: expiryTimestamp)
            // Refresh if within 5 minutes of expiration
            isExpired = Date().addingTimeInterval(300) >= expiryDate
        } else {
            isExpired = false
        }

        if isExpired {
            return try await refreshTokens()
        }

        return token
    }

    func refreshTokens() async throws -> String {
        let generation = sessionGeneration
        if let refreshTask {
            let token = try await refreshTask.value
            try requireGeneration(generation)
            return token
        }
        // Sequential callers (e.g. one 403 per note in a single sync pass) share the refresh that just succeeded.
        if let last = lastRefreshSuccess, now().timeIntervalSince(last) < refreshCooldown,
           let token = keychain.readString(key: kAccessToken), !token.isEmpty {
            NSLog("AUTH_FLOW phase=refresh-coalesced")
            return token
        }
        // After a failed refresh (offline, 5xx, keychain write failure) wait out an exponential backoff.
        if let until = refreshBackoffUntil, now() < until {
            NSLog("AUTH_FLOW phase=refresh-backoff")
            throw NSError(domain: "AuthManager", code: -16, userInfo: [NSLocalizedDescriptionKey: "令牌刷新刚失败过，稍后自动重试（退避中）。"])
        }
        let task = Task { try await self.performRefresh(generation: generation) }
        refreshTask = task
        defer { if generation == sessionGeneration { refreshTask = nil } }
        let token = try await task.value
        try requireGeneration(generation)
        return token
    }

    private func performRefresh(generation: UUID) async throws -> String {
        refreshNetworkCallCount += 1
        do {
            let token = try await performRefreshRequest(generation: generation)
            if sessionGeneration == generation {
                lastRefreshSuccess = now()
                refreshFailureCount = 0
                refreshBackoffUntil = nil
            }
            return token
        } catch {
            // Cancellation (sign-out/sign-in) is not a failure; a rejected token already invalidated the session.
            if sessionGeneration == generation, isAuthenticated, !(error is CancellationError) {
                refreshFailureCount += 1
                let delay = min(Self.refreshBackoffBase * pow(2, Double(refreshFailureCount - 1)), Self.refreshBackoffCap)
                refreshBackoffUntil = now().addingTimeInterval(delay)
            }
            throw error
        }
    }

    private func resetRefreshThrottle() {
        lastRefreshSuccess = nil
        refreshFailureCount = 0
        refreshBackoffUntil = nil
    }

    private func performRefreshRequest(generation: UUID) async throws -> String {
        NSLog("AUTH_FLOW phase=refresh")
        try Task.checkCancellation()
        try requireGeneration(generation)
        guard let refreshToken = keychain.readString(key: kRefreshToken) else {
            self.isAuthenticated = false
            throw NSError(domain: "AuthManager", code: 401, userInfo: [NSLocalizedDescriptionKey: "No refresh token available. Please sign in again."])
        }

        guard let tokenURL = URL(string: "https://login.microsoftonline.com/common/oauth2/v2.0/token") else {
            throw NSError(domain: "AuthManager", code: -10, userInfo: [NSLocalizedDescriptionKey: "Invalid token endpoint"])
        }

        var request = URLRequest(url: tokenURL)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        let params: [String: String] = [
            "client_id": clientId,
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "scope": scopes
        ]

        request.httpBody = params
            .map { "\($0.key.addingPercentEncoding(withAllowedCharacters: Self.formAllowed) ?? $0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: Self.formAllowed) ?? $0.value)" }
            .joined(separator: "&")
            .data(using: .utf8)

        let (data, response) = try await network.data(for: request)
        try requireGeneration(generation)
        guard let httpResponse = response as? HTTPURLResponse, (200...299).contains(httpResponse.statusCode) else {
            let errorText = "HTTP \((response as? HTTPURLResponse)?.statusCode ?? -1)"
            // If refresh token is revoked or expired
            if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 400 || httpResponse.statusCode == 401 {
                invalidateSession()
            }
            throw NSError(domain: "AuthManager", code: -11, userInfo: [NSLocalizedDescriptionKey: "Token refresh failed: \(errorText)"])
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let newAccessToken = json["access_token"] as? String else {
            throw NSError(domain: "AuthManager", code: -12, userInfo: [NSLocalizedDescriptionKey: "Invalid refresh response format"])
        }

        var values = [kAccessToken: newAccessToken]
        if let refresh = json["refresh_token"] as? String { values[kRefreshToken] = refresh }
        let seconds = (json["expires_in"] as? Double) ?? 3600
        values[kTokenExpiry] = String(Date().addingTimeInterval(seconds).timeIntervalSince1970)
        let saved = await keychain.updateAsync(strings: values)
        try requireGeneration(generation)
        guard saved else {
            throw NSError(domain: "AuthManager", code: -13, userInfo: [NSLocalizedDescriptionKey: "无法保存刷新会话，请检查钥匙串授权。"])
        }

        self.isAuthenticated = true
        return newAccessToken
    }

    // MARK: - User Profile

    func ensureAccountID() async throws -> String {
        if identityMismatch { throw Self.identityMismatchError }
        if let accountID, !accountID.isEmpty, identityVerified { return accountID }
        let generation = sessionGeneration
        if let identityTask {
            let id = try await identityTask.value
            try requireGeneration(generation)
            return id
        }
        let task = Task { try await self.resolveAccountID(generation: generation) }
        identityTask = task
        defer { if generation == sessionGeneration { identityTask = nil } }
        let id = try await task.value
        try requireGeneration(generation)
        return id
    }

    private static let identityMismatchError = NSError(domain: "AuthManager", code: -15, userInfo: [NSLocalizedDescriptionKey: "令牌所属的微软账号与本机记录的账号不一致，已暂停显示与同步；请退出后重新登录。未删除任何数据。"])

    private func fetchMeProfile(token: String) async throws -> (Data, URLResponse) {
        var request = URLRequest(url: URL(string: "https://graph.microsoft.com/v1.0/me?$select=id,displayName,mail,userPrincipalName")!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return try await network.data(for: request)
    }

    private func resolveAccountID(generation: UUID) async throws -> String {
        try Task.checkCancellation()
        try requireGeneration(generation)
        var token = try await getValidAccessToken()
        try requireGeneration(generation)
        var (data, response) = try await fetchMeProfile(token: token)
        try requireGeneration(generation)
        if (response as? HTTPURLResponse)?.statusCode == 401 {
            token = try await refreshTokens()
            try requireGeneration(generation)
            (data, response) = try await fetchMeProfile(token: token)
            try requireGeneration(generation)
        }
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = json["id"] as? String, !id.isEmpty else {
            throw NSError(domain: "AuthManager", code: -14, userInfo: [NSLocalizedDescriptionKey: "无法确认微软账号身份，已暂停同步。"])
        }
        let name = json["displayName"] as? String ?? ""
        let email = (json["mail"] as? String) ?? (json["userPrincipalName"] as? String) ?? ""
        if let cached = accountID, !cached.isEmpty, cached != id {
            // The keychain/session claims account A but the token belongs to B. Do not adopt B silently and do not
            // touch the keychain: treat the identity as unconfirmed (blocked scope, nothing shown or synced).
            identityMismatch = true
            identityVerified = false
            accountID = nil
            userName = nil
            userEmail = nil
            lastAuthError = Self.identityMismatchError.localizedDescription
            NSLog("AUTH_FLOW phase=identity-mismatch")
            throw Self.identityMismatchError
        }
        let fresh = [kAccountID: id, kUserName: name, kUserEmail: email]
        // Already-confirmed values need no keychain write (a write can raise a prompt on a rebuilt app).
        if fresh.contains(where: { keychain.readString(key: $0.key) != $0.value }) {
            let saved = await keychain.updateAsync(strings: fresh)
            try requireGeneration(generation)
            guard saved else {
                throw NSError(domain: "AuthManager", code: -13, userInfo: [NSLocalizedDescriptionKey: "无法保存账号身份，已暂停同步。"])
            }
        }
        identityVerified = true
        accountID = id
        userName = name
        userEmail = email
        return id
    }

    // MARK: - Sign Out

    private func invalidateSession() {
        // Invalidate every outstanding OAuth/refresh/sync continuation before storage changes.
        sessionGeneration = UUID()
        defaults.set(true, forKey: "ms_explicitly_signed_out")
        currentAuthSession?.cancel()
        currentAuthSession = nil
        refreshTask?.cancel()
        refreshTask = nil
        identityTask?.cancel()
        identityTask = nil
        isAuthenticating = false
        isAuthenticated = false
        accountID = nil
        identityVerified = false
        identityMismatch = false
        resetRefreshThrottle()
        userEmail = nil
        userName = nil
    }

    func signOut() {
        NSLog("AUTH_FLOW phase=logout")
        invalidateSession()
        // Memory first (instant, no SecItem): the session is gone and queued refresh writes are voided.
        keychain.discardCache()
        restoreTask?.cancel()
        restoreState = .done
        lastAuthError = nil
        // Then remove ONLY the current session item, in the background. Other items are not touched.
        keychainWork = Task { [weak self] in
            guard let self else { return }
            let ok = await self.keychain.clearAllAsync()
            if !ok { self.lastAuthError = "本地已退出，但钥匙串清理未完成；重开不会自动恢复登录。" }
        }
    }

    private static let formAllowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))

    // MARK: - PKCE Utilities

    private func generateRandomBase64URL(byteCount: Int) throws -> String {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard status == errSecSuccess else {
            throw NSError(
                domain: "AuthManager",
                code: -15,
                userInfo: [NSLocalizedDescriptionKey: "Unable to generate cryptographically secure random bytes (OSStatus \(status))"]
            )
        }
        return base64URLEncode(Data(bytes))
    }

    private func generateCodeVerifier() throws -> String {
        try generateRandomBase64URL(byteCount: 32)
    }

    private func generateOAuthState() throws -> String {
        try generateRandomBase64URL(byteCount: 32)
    }

    private func generateCodeChallenge(from verifier: String) -> String {
        let hash = SHA256.hash(data: Data(verifier.utf8))
        return base64URLEncode(Data(hash))
    }

    private func base64URLEncode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .trimmingCharacters(in: CharacterSet(charactersIn: "="))
    }
}

// MARK: - ASWebAuthenticationPresentationContextProviding

extension AuthManager: ASWebAuthenticationPresentationContextProviding {
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        NSApplication.shared.windows.first { $0.isVisible } ?? NSApplication.shared.windows.first ?? NSWindow()
    }
}
