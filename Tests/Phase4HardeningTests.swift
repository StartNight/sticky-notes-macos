import XCTest
import SwiftData
import AppKit

/// Phase 4 hardening & coverage tests: OAuth CSRF/callback/config/clock-rollback,
/// Graph @odata.nextLink pagination/loop/host validation, path-traversal ID rejection,
/// ColorEditLedger LRU, DateFormatting/DurationFormatting, WindowManager, and LocalExporter.
@MainActor
final class Phase4HardeningTests: XCTestCase {

    private var suiteNames: [String] = []
    private var container: ModelContainer!
    private var engines: [SyncEngine] = []

    override func setUp() async throws {
        MockURLProtocol.reset()
        URLProtocol.registerClass(MockURLProtocol.self)
        SyncAuthStub.shared.reset()
        let schema = Schema([StickyNote.self])
        container = try ModelContainer(
            for: schema,
            configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)]
        )
        engines = []
    }

    override func tearDown() async throws {
        for engine in engines { engine.cancelPendingWork() }
        engines = []
        XCTAssertEqual(MockURLProtocol.heldCount, 0)
        MockURLProtocol.reset()
        URLProtocol.unregisterClass(MockURLProtocol.self)
        for name in suiteNames {
            UserDefaults(suiteName: name)?.removePersistentDomain(forName: name)
        }
        suiteNames = []
        container = nil
    }

    private func makeDefaults() -> UserDefaults {
        let name = "phase4-tests-" + UUID().uuidString
        suiteNames.append(name)
        return UserDefaults(suiteName: name)!
    }

    private func makeMockSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        return URLSession(configuration: config)
    }

    private func makeSyncEngine(defaults: UserDefaults? = nil) -> SyncEngine {
        let d = defaults ?? makeDefaults()
        let engine = SyncEngine(
            authManager: SyncAuthStub.shared,
            debounceNanoseconds: 1_000_000,
            colorLedger: ColorEditLedger(defaults: d),
            defaults: d,
            startPeriodicSync: false
        )
        engines.append(engine)
        return engine
    }

    // MARK: - OAuth CSRF, Callback & Configuration (M-02, M-12, H-18)

    func testOAuthStateMismatchRejectsCSRF() async {
        let defaults = makeDefaults()
        let auth = AuthManager(
            keychain: KeychainHelper(inMemoryOnly: true),
            defaults: defaults,
            network: makeMockSession(),
            loadStoredAuth: false
        )
        auth.authSessionRunner = { _, _ in
            URL(string: "msauth.com.shenanigans.sticky-notes://auth?code=valid-code&state=wrong-state")!
        }

        do {
            try await auth.signIn()
            XCTFail("Expected CSRF state mismatch error")
        } catch {
            XCTAssertEqual((error as NSError).code, -5)
        }
        XCTAssertFalse(auth.isAuthenticated)
        XCTAssertTrue(MockURLProtocol.requests.isEmpty, "Must never exchange auth code on CSRF mismatch")
    }

    func testOAuthCallbackErrorParamRejectsSignIn() async {
        let defaults = makeDefaults()
        let auth = AuthManager(
            keychain: KeychainHelper(inMemoryOnly: true),
            defaults: defaults,
            network: makeMockSession(),
            loadStoredAuth: false
        )
        auth.authSessionRunner = { _, _ in
            URL(string: "msauth.com.shenanigans.sticky-notes://auth?error=access_denied&error_description=User%20denied")!
        }

        do {
            try await auth.signIn()
            XCTFail("Expected callback error")
        } catch {
            XCTAssertEqual((error as NSError).code, -4)
        }
        XCTAssertFalse(auth.isAuthenticated)
    }

    func testOAuthCallbackMissingCodeRejectsSignIn() async {
        let defaults = makeDefaults()
        let auth = AuthManager(
            keychain: KeychainHelper(inMemoryOnly: true),
            defaults: defaults,
            network: makeMockSession(),
            loadStoredAuth: false
        )
        auth.authSessionRunner = { authURL, _ in
            let state = URLComponents(url: authURL, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "state" })?.value ?? ""
            return URL(string: "msauth.com.shenanigans.sticky-notes://auth?state=\(state)")!
        }

        do {
            try await auth.signIn()
            XCTFail("Expected missing code error")
        } catch {
            XCTAssertEqual((error as NSError).code, -6)
        }
        XCTAssertFalse(auth.isAuthenticated)
    }

    func testOAuthCallbackMismatchedHostRejectsSignIn() async {
        let defaults = makeDefaults()
        let auth = AuthManager(
            keychain: KeychainHelper(inMemoryOnly: true),
            defaults: defaults,
            network: makeMockSession(),
            loadStoredAuth: false
        )
        auth.authSessionRunner = { authURL, _ in
            let state = URLComponents(url: authURL, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "state" })?.value ?? ""
            return URL(string: "msauth.com.shenanigans.sticky-notes://evil-host?code=abc&state=\(state)")!
        }

        do {
            try await auth.signIn()
            XCTFail("Expected host mismatch error")
        } catch {
            XCTAssertEqual((error as NSError).code, -3)
        }
        XCTAssertFalse(auth.isAuthenticated)
    }

    func testOAuthConfigUsesInjectedDefaultsAndTreatsBlankAsDefault() {
        let defaults = makeDefaults()
        let auth = AuthManager(
            keychain: KeychainHelper(inMemoryOnly: true),
            defaults: defaults,
            network: makeMockSession(),
            loadStoredAuth: false
        )
        XCTAssertEqual(auth.clientId, AuthManager.defaultClientId)
        XCTAssertEqual(auth.redirectUri, AuthManager.defaultRedirectUri)

        auth.clientId = "  custom-client-id  "
        auth.redirectUri = "myapp://callback/auth"
        XCTAssertEqual(auth.clientId, "custom-client-id")
        XCTAssertEqual(auth.callbackScheme, "myapp")
        // Must not pollute UserDefaults.standard
        XCTAssertNotEqual(UserDefaults.standard.string(forKey: "ms_client_id"), "custom-client-id")

        // Setting blank string falls back cleanly to default instead of persisting ""
        auth.clientId = "   "
        auth.redirectUri = ""
        XCTAssertEqual(auth.clientId, AuthManager.defaultClientId)
        XCTAssertEqual(auth.redirectUri, AuthManager.defaultRedirectUri)

        auth.clientId = "temp"
        auth.resetOAuthConfiguration()
        XCTAssertEqual(auth.clientId, AuthManager.defaultClientId)
    }

    func testTokenExchangeParsesStringExpiresInAndRejectsEmptyAccessToken() async throws {
        let defaults = makeDefaults()
        var currentTime = Date(timeIntervalSince1970: 1_800_000_000)
        let kc = KeychainHelper(inMemoryOnly: true)
        let auth = AuthManager(
            keychain: kc,
            defaults: defaults,
            network: makeMockSession(),
            loadStoredAuth: false,
            now: { currentTime }
        )
        auth.authSessionRunner = { authURL, _ in
            let state = URLComponents(url: authURL, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "state" })?.value ?? ""
            return URL(string: "msauth.com.shenanigans.sticky-notes://auth?code=ok-code&state=\(state)")!
        }

        // 1. Empty access_token must be rejected
        MockURLProtocol.handler = { req in
            if req.url?.host == "login.microsoftonline.com" {
                return .http(status: 200, json: ["access_token": "", "refresh_token": "r", "expires_in": "7200"])
            }
            return .http(status: 200, json: ["id": "u1"])
        }
        do {
            try await auth.signIn()
            XCTFail("Empty access_token must fail")
        } catch {
            XCTAssertEqual((error as NSError).code, -9)
        }

        // 2. String expires_in ("7200") should succeed and store expiry using injected `now()`
        MockURLProtocol.handler = { req in
            if req.url?.host == "login.microsoftonline.com" {
                return .http(status: 200, json: ["access_token": "tok-1", "refresh_token": "ref-1", "expires_in": "7200"])
            }
            return .http(status: 200, json: ["id": "u1", "displayName": "User", "mail": "u@example.test"])
        }
        try await auth.signIn()
        XCTAssertTrue(auth.isAuthenticated)
        let savedExpiry = Double(kc.readString(key: "ms_token_expiry") ?? "") ?? 0
        XCTAssertEqual(savedExpiry, currentTime.addingTimeInterval(7200).timeIntervalSince1970, accuracy: 0.5)

        // 3. Backward clock jump must not freeze backoff permanently
        MockURLProtocol.handler = { _ in .http(status: 503, json: [:]) }
        do { _ = try await auth.refreshTokens(); XCTFail("Expected 503 failure") } catch {}
        // Step system clock backward by 1 hour — backoff must discard stale wall-clock deadline instead of waiting 1h+30s
        currentTime = currentTime.addingTimeInterval(-3600)
        MockURLProtocol.handler = { _ in
            .http(status: 200, json: ["access_token": "tok-2", "refresh_token": "ref-2", "expires_in": 3600])
        }
        let refreshed = try await auth.refreshTokens()
        XCTAssertEqual(refreshed, "tok-2")
    }

    // MARK: - Graph @odata.nextLink Pagination, Loop Detection & Path Hardening (M-04, H-18)

    func testPullFollowsMultiPageNextLink() async throws {
        let engine = makeSyncEngine()
        let page2URL = "https://graph.microsoft.com/v1.0/me/mailFolders/notes/messages?$skiptoken=page2"
        MockURLProtocol.handler = { req in
            let urlStr = req.url?.absoluteString ?? ""
            if urlStr.contains("skiptoken=page2") {
                return .http(status: 200, json: [
                    "value": [
                        ["id": "N-2", "changeKey": "CK2", "body": ["content": "<div>Page two</div>"], "lastModifiedDateTime": "2030-01-01T00:00:00Z"]
                    ]
                ])
            }
            return .http(status: 200, json: [
                "value": [
                    ["id": "N-1", "changeKey": "CK1", "body": ["content": "<div>Page one</div>"], "lastModifiedDateTime": "2030-01-01T00:00:00Z"]
                ],
                "@odata.nextLink": page2URL
            ])
        }

        await engine.syncAll(modelContext: container.mainContext)
        XCTAssertEqual(engine.state, .idle)
        let notes = try container.mainContext.fetch(FetchDescriptor<StickyNote>())
        XCTAssertEqual(Set(notes.map(\.plainTextContent)), ["Page one", "Page two"])
    }

    func testPullRejectsInvalidNextLinkHostAndCyclicNextLink() async throws {
        let engine = makeSyncEngine()

        // 1. Disallowed host
        MockURLProtocol.handler = { _ in
            .http(status: 200, json: [
                "value": [],
                "@odata.nextLink": "https://evil.example/v1.0/me/mailFolders/notes/messages"
            ])
        }
        await engine.syncAll(modelContext: container.mainContext)
        if case .error = engine.state {} else { XCTFail("Invalid nextLink host must fail sync") }
        XCTAssertEqual(MockURLProtocol.requests.count, 1)

        // 2. Non-/v1.0/ path
        MockURLProtocol.reset()
        MockURLProtocol.handler = { _ in
            .http(status: 200, json: [
                "value": [],
                "@odata.nextLink": "https://graph.microsoft.com/beta/me/messages"
            ])
        }
        await engine.syncAll(modelContext: container.mainContext)
        if case .error = engine.state {} else { XCTFail("Non-/v1.0/ nextLink must fail sync") }

        // 3. Cyclic nextLink
        MockURLProtocol.reset()
        let loopURL = "https://graph.microsoft.com/v1.0/me/mailFolders/notes/messages?$skiptoken=loop"
        MockURLProtocol.handler = { _ in
            .http(status: 200, json: ["value": [], "@odata.nextLink": loopURL])
        }
        await engine.syncAll(modelContext: container.mainContext)
        if case .error = engine.state {} else { XCTFail("Cyclic nextLink must fail sync") }
        XCTAssertLessThanOrEqual(MockURLProtocol.requests.count, 2, "Must detect cycle on first repeat")
    }

    func testGraphItemURLRejectsPathTraversalIDs() async throws {
        let engine = makeSyncEngine()
        for badID in ["", "   ", ".", "..", "a/b", "a\\b", "../me"] {
            let note = StickyNote(content: "test", remoteId: badID, ownerAccountID: "test-account", changeKey: "ck")
            container.mainContext.insert(note)
            do {
                try await engine.uploadNote(note, token: "tok")
                XCTFail("Expected invalid URL error for remoteId '\(badID)'")
            } catch {
                XCTAssertEqual((error as NSError).code, -1)
            }
            container.mainContext.delete(note)
        }
        XCTAssertTrue(MockURLProtocol.requests.isEmpty)
    }

    // MARK: - ColorEditLedger LRU & NoteConverter Guards (P3-6, M-10)

    func testColorEditLedgerEvictsLeastRecentlyUsedNotOldestInserted() {
        let defaults = makeDefaults()
        let ledger = ColorEditLedger(defaults: defaults)
        let first = UUID()
        let second = UUID()
        ledger.markDirty(first)
        ledger.markDirty(second)
        // Re-touch `first` so `second` becomes the LRU entry
        ledger.markDirty(first)
        for _ in 0..<(ColorEditLedger.capacity - 1) {
            ledger.markDirty(UUID())
        }
        XCTAssertTrue(ledger.isDirty(first), "Recently re-touched ID must survive LRU eviction")
        XCTAssertFalse(ledger.isDirty(second), "Least-recently-used ID should be evicted first")
    }

    func testNoteConverterRejectsBooleanColorAndPreservesForeignSubstrateDocument() throws {
        XCTAssertNil(NoteConverter.noteColor(fromWebNoteJSON: "{\"color\":true}"))
        XCTAssertNil(NoteConverter.noteColor(fromWebNoteJSON: "{\"color\":false}"))

        // Windows-authored note has a different `createdWithLocalId`; Mac must NOT overwrite its `document`
        let windowsJSON = """
        {"schemaVersion":"beta","createdByApp":"StickyNotes","createdWithLocalId":"11111111-1111-1111-1111-111111111111","color":0,"document":{"type":"document","blocks":[{"type":"paragraph","content":[{"text":"Windows Original","styles":[]}]}]}}
        """
        let updated = NoteConverter.webNoteJSON(
            setting: .green,
            existing: windowsJSON,
            plainText: "Mac Edit",
            localID: UUID()
        )
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(updated.utf8)) as? [String: Any])
        XCTAssertEqual(obj["color"] as? Int, 1)
        let doc = try XCTUnwrap(obj["document"] as? [String: Any])
        let blocks = try XCTUnwrap(doc["blocks"] as? [[String: Any]])
        let content = try XCTUnwrap(blocks.first?["content"] as? [[String: Any]])
        XCTAssertEqual(content.first?["text"] as? String, "Windows Original", "Must not wipe another client's Substrate document")
    }

    // MARK: - DateFormatting & DurationFormatting (M-16, H-18)

    func testDateFormattingHandlesFutureDatesAndCalendarDayBoundaries() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: 0)!
        let ref = cal.date(from: DateComponents(year: 2026, month: 6, day: 15, hour: 10, minute: 0))!
        let yesterdayLate = cal.date(from: DateComponents(year: 2026, month: 6, day: 14, hour: 23, minute: 30))!
        let threeDaysAgo = cal.date(from: DateComponents(year: 2026, month: 6, day: 12, hour: 9, minute: 0))!
        let sevenDaysAgo = cal.date(from: DateComponents(year: 2026, month: 6, day: 8, hour: 12, minute: 0))!
        let tomorrow = cal.date(from: DateComponents(year: 2026, month: 6, day: 16, hour: 9, minute: 0))!

        XCTAssertEqual(yesterdayLate.noteListFormatted(relativeTo: ref, calendar: cal), String(localized: "Yesterday"))
        XCTAssertEqual(threeDaysAgo.noteListFormatted(relativeTo: ref, calendar: cal), threeDaysAgo.formatted(.dateTime.weekday(.wide)))
        // 7 calendar days ago must NOT show weekday (avoids ambiguity with today's weekday)
        XCTAssertEqual(sevenDaysAgo.noteListFormatted(relativeTo: ref, calendar: cal), sevenDaysAgo.formatted(date: .abbreviated, time: .omitted))
        // Future date must NOT show weekday
        XCTAssertEqual(tomorrow.noteListFormatted(relativeTo: ref, calendar: cal), tomorrow.formatted(date: .abbreviated, time: .omitted))
    }

    func testDurationFormattingHandlesSpecialFloatsAndNegativesSafely() {
        XCTAssertEqual(TimeInterval(0).formattedDuration, "0:00")
        XCTAssertEqual(TimeInterval(5).formattedDuration, "0:05")
        XCTAssertEqual(TimeInterval(65.9).formattedDuration, "1:05")
        XCTAssertEqual(TimeInterval(-10).formattedDuration, "0:00")
        XCTAssertEqual(TimeInterval.nan.formattedDuration, "0:00")
        XCTAssertEqual(TimeInterval.infinity.formattedDuration, "0:00")
        XCTAssertEqual((-TimeInterval.infinity).formattedDuration, "0:00")
    }

    // MARK: - WindowManager (H-15, H-18)

    func testWindowManagerReconcilesStaleOpenIDWhenNoVisibleWindowExists() {
        let manager = WindowManager()
        let id = UUID()
        XCTAssertFalse(manager.isOpen(id))
        manager.markOpened(id)
        XCTAssertTrue(manager.openNoteIDs.contains(id))
        // No visible window exists in hostless test process: bringToFront and isOpen must reconcile stale ID
        XCTAssertFalse(manager.bringToFront(id))
        XCTAssertFalse(manager.openNoteIDs.contains(id))
        manager.markOpened(id)
        XCTAssertFalse(manager.isOpen(id))
        XCTAssertFalse(manager.openNoteIDs.contains(id))
    }

    // MARK: - LocalExporter Finite Float & Provisional Scope Safety (M-06)

    func testLocalExporterSanitizesNonFiniteCoordinatesAndChecksIdentityVerification() throws {
        let note = StickyNote(content: "Export me", ownerAccountID: "acct-1")
        note.windowX = .nan
        note.windowY = .infinity
        note.windowWidth = -.infinity
        note.windowHeight = .nan

        // Provisional (unverified) account scope must require acknowledgement
        XCTAssertThrowsError(
            try LocalExporter.export([note], scope: .account("acct-1"), isIdentityVerified: false, acknowledgedOutOfScope: false)
        )

        // With acknowledgement or verified identity, non-finite coords must serialize cleanly without crashing
        let data = try LocalExporter.export([note], scope: .account("acct-1"), isIdentityVerified: true, acknowledgedOutOfScope: false)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let notes = try XCTUnwrap(json["notes"] as? [[String: Any]])
        let frame = try XCTUnwrap(notes.first?["windowFrame"] as? [Double])
        XCTAssertEqual(frame, [0, 0, 300, 350])
    }
}
