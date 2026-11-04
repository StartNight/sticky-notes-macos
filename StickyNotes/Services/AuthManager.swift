import Foundation
import AuthenticationServices
import CryptoKit
import SwiftUI

@MainActor
@Observable
final class AuthManager: NSObject {
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

    private let scopes = "Mail.ReadWrite offline_access User.Read"
    private let keychain = KeychainHelper.shared
    private var currentAuthSession: ASWebAuthenticationSession?

    // Keychain Keys
    private let kAccessToken = "ms_access_token"
    private let kRefreshToken = "ms_refresh_token"
    private let kTokenExpiry = "ms_token_expiry"
    private let kUserEmail = "ms_user_email"
    private let kUserName = "ms_user_name"

    override init() {
        super.init()
        checkStoredAuth()
    }

    // MARK: - Auth State Check

    func checkStoredAuth() {
        if let token = keychain.readString(key: kAccessToken), !token.isEmpty {
            self.isAuthenticated = true
            self.userEmail = keychain.readString(key: kUserEmail)
            self.userName = keychain.readString(key: kUserName)
        } else {
            // Check if there is an existing hermes dev token file to seed
            seedFromHermesTokenFileIfNeeded()
        }
    }

    private func seedFromHermesTokenFileIfNeeded() {
        let hermesTokenPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".hermes/microsoft-notes/token.json")
        guard FileManager.default.fileExists(atPath: hermesTokenPath.path),
              let data = try? Data(contentsOf: hermesTokenPath),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let accessToken = json["access_token"] as? String else {
            return
        }

        keychain.save(key: kAccessToken, string: accessToken)
        if let refreshToken = json["refresh_token"] as? String {
            keychain.save(key: kRefreshToken, string: refreshToken)
        }
        if let expiresIn = json["expires_in"] as? Double {
            let expiryDate = Date().addingTimeInterval(expiresIn)
            keychain.save(key: kTokenExpiry, string: String(expiryDate.timeIntervalSince1970))
        }

        self.isAuthenticated = true
        Task {
            await fetchUserProfile()
        }
    }

    // MARK: - OAuth PKCE Sign In

    func signIn() async throws {
        isAuthenticating = true
        lastAuthError = nil
        defer { isAuthenticating = false }

        // 1. Generate PKCE parameters
        let codeVerifier = generateCodeVerifier()
        let codeChallenge = generateCodeChallenge(from: codeVerifier)
        let state = UUID().uuidString

        // 2. Build authorization URL
        var components = URLComponents(string: "https://login.microsoftonline.com/common/oauth2/v2.0/authorize")!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: clientId),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "redirect_uri", value: redirectUri),
            URLQueryItem(name: "response_mode", value: "query"),
            URLQueryItem(name: "scope", value: scopes),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "code_challenge", value: codeChallenge),
            URLQueryItem(name: "code_challenge_method", value: "S256")
        ]

        guard let authURL = components.url else {
            throw NSError(domain: "AuthManager", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to create authorization URL"])
        }

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
            session.prefersEphemeralWebBrowserSession = false
            self.currentAuthSession = session
            session.start()
        }

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
        await fetchUserProfile()
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
            .map { "\($0.key.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? $0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? $0.value)" }
            .joined(separator: "&")
            .data(using: .utf8)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, (200...299).contains(httpResponse.statusCode) else {
            let errorText = String(data: data, encoding: .utf8) ?? "HTTP error"
            throw NSError(domain: "AuthManager", code: -8, userInfo: [NSLocalizedDescriptionKey: "Token exchange failed: \(errorText)"])
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let accessToken = json["access_token"] as? String else {
            throw NSError(domain: "AuthManager", code: -9, userInfo: [NSLocalizedDescriptionKey: "Invalid token response format"])
        }

        keychain.save(key: kAccessToken, string: accessToken)

        if let refreshToken = json["refresh_token"] as? String {
            keychain.save(key: kRefreshToken, string: refreshToken)
        }

        if let expiresIn = json["expires_in"] as? Double {
            let expiryDate = Date().addingTimeInterval(expiresIn)
            keychain.save(key: kTokenExpiry, string: String(expiryDate.timeIntervalSince1970))
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
            .map { "\($0.key.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? $0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? $0.value)" }
            .joined(separator: "&")
            .data(using: .utf8)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, (200...299).contains(httpResponse.statusCode) else {
            let errorText = String(data: data, encoding: .utf8) ?? "HTTP error"
            // If refresh token is revoked or expired
            if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 400 || httpResponse.statusCode == 401 {
                signOut()
            }
            throw NSError(domain: "AuthManager", code: -11, userInfo: [NSLocalizedDescriptionKey: "Token refresh failed: \(errorText)"])
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let newAccessToken = json["access_token"] as? String else {
            throw NSError(domain: "AuthManager", code: -12, userInfo: [NSLocalizedDescriptionKey: "Invalid refresh response format"])
        }

        keychain.save(key: kAccessToken, string: newAccessToken)

        if let newRefreshToken = json["refresh_token"] as? String {
            keychain.save(key: kRefreshToken, string: newRefreshToken)
        }

        if let expiresIn = json["expires_in"] as? Double {
            let expiryDate = Date().addingTimeInterval(expiresIn)
            keychain.save(key: kTokenExpiry, string: String(expiryDate.timeIntervalSince1970))
        }

        self.isAuthenticated = true
        return newAccessToken
    }

    // MARK: - User Profile

    func fetchUserProfile() async {
        do {
            let token = try await getValidAccessToken()
            guard let url = URL(string: "https://graph.microsoft.com/v1.0/me") else { return }

            var request = URLRequest(url: url)
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse, (200...299).contains(httpResponse.statusCode),
                  let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return
            }

            let name = json["displayName"] as? String
            let email = (json["mail"] as? String) ?? (json["userPrincipalName"] as? String)

            self.userName = name
            self.userEmail = email

            if let name { keychain.save(key: kUserName, string: name) }
            if let email { keychain.save(key: kUserEmail, string: email) }
        } catch {
            print("Failed to fetch user profile: \(error)")
        }
    }

    // MARK: - Sign Out

    func signOut() {
        keychain.delete(key: kAccessToken)
        keychain.delete(key: kRefreshToken)
        keychain.delete(key: kTokenExpiry)
        keychain.delete(key: kUserEmail)
        keychain.delete(key: kUserName)

        self.isAuthenticated = false
        self.userEmail = nil
        self.userName = nil
        self.lastAuthError = nil
    }

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
