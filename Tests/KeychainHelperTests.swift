import XCTest

final class KeychainHelperTests: XCTestCase {

    private func makeHelper() -> KeychainHelper {
        KeychainHelper(service: "com.shenanigans.sticky-notes.tests", inMemoryOnly: true)
    }

    func testMultipleKeysRoundTripFromSessionCacheWithoutSecItem() {
        let store = makeHelper()
        XCTAssertTrue(store.save(key: "ms_access_token", string: "tok-a"))
        XCTAssertTrue(store.save(key: "ms_refresh_token", string: "tok-r"))
        XCTAssertTrue(store.save(key: "ms_token_expiry", string: "12345"))
        XCTAssertTrue(store.save(key: "ms_user_email", string: "user@example.com"))
        XCTAssertTrue(store.save(key: "ms_user_name", string: "User"))

        XCTAssertEqual(store.copyMatchingCallCount, 0, "内存会话不得访问钥匙串")
        XCTAssertEqual(store.writeCallCount, 0, "内存会话不得写入钥匙串")

        XCTAssertEqual(store.readString(key: "ms_access_token"), "tok-a")
        XCTAssertEqual(store.readString(key: "ms_refresh_token"), "tok-r")
        XCTAssertEqual(store.readString(key: "ms_token_expiry"), "12345")
        XCTAssertEqual(store.readString(key: "ms_user_email"), "user@example.com")
        XCTAssertEqual(store.readString(key: "ms_user_name"), "User")
        XCTAssertEqual(store.copyMatchingCallCount, 0)
    }

    func testRepeatedReadsDoNotTouchKeychainAfterHydration() {
        let store = makeHelper()
        XCTAssertTrue(store.save(key: "ms_access_token", string: "cached"))
        for _ in 0..<20 {
            XCTAssertEqual(store.readString(key: "ms_access_token"), "cached")
        }
        XCTAssertEqual(store.copyMatchingCallCount, 0)
    }

    func testDeleteRemovesOnlyThatFieldFromSession() {
        let store = makeHelper()
        _ = store.save(key: "ms_access_token", string: "tok-a")
        _ = store.save(key: "ms_refresh_token", string: "tok-r")
        XCTAssertTrue(store.delete(key: "ms_access_token"))
        XCTAssertNil(store.readString(key: "ms_access_token"))
        XCTAssertEqual(store.readString(key: "ms_refresh_token"), "tok-r")
    }
}
