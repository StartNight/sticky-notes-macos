import Foundation
import AuthenticationServices
import CryptoKit
import SwiftUI

@MainActor
protocol SyncAuthProviding: AnyObject {
    var isAuthenticated: Bool { get }
    var accountID: String? { get }
    var sessionGeneration: UUID { get }
    func getValidAccessToken() async throws -> String
    func refreshTokens() async throws -> String
    func ensureAccountID() async throws -> String
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
    private(set) var sessionGeneration = UUID()
    private var refreshTask: Task<String, Error>?
    private var identityTask: Task<String, Error>?
    private let kAccountID = "ms_graph_account_id"
    static let usesEphemeralSession = true
    private var currentAuthSession: ASWebAuthenticationSession?

    // Keychain Keys
    private let kAccessToken = "ms_access_token"
    private let kRefreshToken = "ms_refresh_token"
    private let kTokenExpiry = "ms_token_expiry"
    private let kUserEmail = "ms_user_email"
    private let kUserName = "ms_user_name"

    init(keychain: KeychainHelper = .shared, defaults: UserDefaults = .standard,
         network: URLSession = .shared, loadStoredAuth: Bool = true) {
        self.keychain = keychain
        self.defaults = defaults
        self.network = network
        super.init()
        if loadStoredAuth { checkStoredAuth() }
    }

    func checkStoredAuth() {
        NSLog("AUTH_FLOW phase=restore")
        guard !defaults.bool(forKey: "ms_explicitly_signed_out") else { return }
        if let token = keychain.readString(key: kAccessToken), !token.isEmpty {
            isAuthenticated = true
            userEmail = keychain.readString(key: kUserEmail)
            userName = keychain.readString(key: kUserName)
            accountID = keychain.readString(key: kAccountID).flatMap { $0.isEmpty ? nil : $0 }
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
        sessionGeneration = UUID()
        let generation = sessionGeneration
        refreshTask?.cancel()
        refreshTask = nil
        identityTask?.cancel()
        identityTask = nil
        accountID = nil
        isAuthenticated = false
        isAuthenticating = true
        lastAuthError = nil
        defer { if sessionGeneration == generation { isAuthenticating = false; currentAuthSession = nil } }

        // 1. Generate PKCE parameters
        let codeVerifier = generateCodeVerifier()
        let codeChallenge = generateCodeChallenge(from: codeVerifier)
        let state = UUID().uuidString

        let authURL = try authorizationURL(state: state, challenge: codeChallenge)

        // 3. Launch ASWebAuthenticationSession
        let callbackURL: URL = try await withCheckedThrowingContinuation { continuation in
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

        // 5. Exchange code for access & refresh tokens
        try await exchangeAuthCode(authCode, codeVerifier: codeVerifier)
        try requireGeneration(generation)
        _ = try await ensureAccountID()
        try requireGeneration(generation)
        defaults.set(false, forKey: "ms_explicitly_signed_out")
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

        var values = [kAccessToken: accessToken, kRefreshToken: json["refresh_token"] as? String ?? "",
                      kAccountID: "", kUserEmail: "", kUserName: ""]
        let seconds = (json["expires_in"] as? Double) ?? 3600
        values[kTokenExpiry] = String(Date().addingTimeInterval(seconds).timeIntervalSince1970)
        guard keychain.replaceSession(strings: values) else {
            throw NSError(domain: "AuthManager", code: -13, userInfo: [NSLocalizedDescriptionKey: "无法保存登录会话，请检查钥匙串授权。"])
        }

        self.isAuthenticated = true
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
        let task = Task { try await self.performRefresh(generation: generation) }
        refreshTask = task
        defer { if generation == sessionGeneration { refreshTask = nil } }
        let token = try await task.value
        try requireGeneration(generation)
        return token
    }

    private func performRefresh(generation: UUID) async throws -> String {
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
        guard keychain.update(strings: values) else {
            throw NSError(domain: "AuthManager", code: -13, userInfo: [NSLocalizedDescriptionKey: "无法保存刷新会话，请检查钥匙串授权。"])
        }

        self.isAuthenticated = true
        return newAccessToken
    }

    // MARK: - User Profile

    func ensureAccountID() async throws -> String {
        if let accountID, !accountID.isEmpty { return accountID }
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

    private func resolveAccountID(generation: UUID) async throws -> String {
        try Task.checkCancellation()
        try requireGeneration(generation)
        let token = try await getValidAccessToken()
        try requireGeneration(generation)
        var request = URLRequest(url: URL(string: "https://graph.microsoft.com/v1.0/me?$select=id,displayName,mail,userPrincipalName")!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await network.data(for: request)
        try requireGeneration(generation)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = json["id"] as? String, !id.isEmpty else {
            throw NSError(domain: "AuthManager", code: -14, userInfo: [NSLocalizedDescriptionKey: "无法确认微软账号身份，已暂停同步。"])
        }
        let name = json["displayName"] as? String ?? ""
        let email = (json["mail"] as? String) ?? (json["userPrincipalName"] as? String) ?? ""
        guard keychain.update(strings: [kAccountID: id, kUserName: name, kUserEmail: email]) else {
            throw NSError(domain: "AuthManager", code: -13, userInfo: [NSLocalizedDescriptionKey: "无法保存账号身份，已暂停同步。"])
        }
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
        userEmail = nil
        userName = nil
    }

    func signOut() {
        NSLog("AUTH_FLOW phase=logout")
        invalidateSession()
        lastAuthError = keychain.clearAll() ? nil : "本地已退出，但钥匙串清理未完成；重开不会自动恢复登录。"
    }

    private static let formAllowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))

    // MARK: - PKCE Utilities

    private func generateCodeVerifier() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return base64URLEncode(Data(bytes))
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
