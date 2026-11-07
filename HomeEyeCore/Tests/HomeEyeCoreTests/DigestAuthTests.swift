import XCTest
@testable import HomeEyeCore

final class DigestAuthTests: XCTestCase {
    private let creds = Credentials(username: "Mufasa", password: "Circle Of Life")

    func testRFC2617Vector() {
        let challenge = AuthChallenge.digest(realm: "testrealm@host.com", nonce: "dcd98b7102dd2f0e8b11d0f600bfb0c093",
                                             opaque: "5ccc069c403ebaf9f0171e9517f40e41", qop: "auth", algorithm: nil)
        let auth = Authenticator(credentials: creds, challenge: challenge, cnonce: "0a4f113b")
        let header = auth.authorization(method: "GET", uri: "/dir/index.html")
        XCTAssertTrue(header.contains("response=\"6629fae49393a05397450978507c4ef1\""), header)
        XCTAssertTrue(header.hasPrefix("Digest username=\"Mufasa\", realm=\"testrealm@host.com\""), header)
        XCTAssertTrue(header.contains("opaque=\"5ccc069c403ebaf9f0171e9517f40e41\""))
        XCTAssertTrue(header.contains("qop=auth, nc=00000001, cnonce=\"0a4f113b\""))
        let second = auth.authorization(method: "GET", uri: "/dir/index.html")
        XCTAssertTrue(second.contains("nc=00000002"), second)
    }

    func testNoQopDigest() {
        let challenge = AuthChallenge.digest(realm: "r", nonce: "n", opaque: nil, qop: nil, algorithm: nil)
        let auth = Authenticator(credentials: creds, challenge: challenge)
        let header = auth.authorization(method: "DESCRIBE", uri: "rtsp://h/s")
        let ha1 = MD5.hex("Mufasa:r:Circle Of Life")
        let ha2 = MD5.hex("DESCRIBE:rtsp://h/s")
        XCTAssertTrue(header.contains("response=\"\(MD5.hex("\(ha1):n:\(ha2)"))\""), header)
        XCTAssertFalse(header.contains("qop"))
        XCTAssertFalse(header.contains("opaque"))
    }

    func testMD5Sess() {
        let challenge = AuthChallenge.digest(realm: "r", nonce: "n", opaque: nil, qop: "auth", algorithm: "MD5-sess")
        let auth = Authenticator(credentials: creds, challenge: challenge, cnonce: "cc")
        let header = auth.authorization(method: "GET", uri: "/")
        let ha1 = MD5.hex("\(MD5.hex("Mufasa:r:Circle Of Life")):n:cc")
        let ha2 = MD5.hex("GET:/")
        XCTAssertTrue(header.contains("response=\"\(MD5.hex("\(ha1):n:00000001:cc:auth:\(ha2)"))\""), header)
        XCTAssertTrue(header.contains("algorithm=MD5-sess"))
    }

    func testHeaderEscapesQuotesAndBackslashes() {
        let c = Credentials(username: "a\"b\\c", password: "p")
        let auth = Authenticator(credentials: c, challenge: .digest(realm: "r\"x", nonce: "n", opaque: nil, qop: nil, algorithm: nil))
        let header = auth.authorization(method: "GET", uri: "/")
        XCTAssertTrue(header.contains("username=\"a\\\"b\\\\c\""), header)
        XCTAssertTrue(header.contains("realm=\"r\\\"x\""), header)
    }

    func testMultipleChallengesInOneValue() {
        let digest = AuthChallenge.digest(realm: "y", nonce: "n", opaque: nil, qop: nil, algorithm: nil)
        XCTAssertEqual(AuthChallenge.parse(["Basic realm=\"x\", Digest realm=\"y\", nonce=\"n\""]), digest)
        XCTAssertEqual(AuthChallenge.parse(["Digest realm=\"y\", nonce=\"n\", Basic realm=\"x\""]), digest)
    }

    func testUnsupportedAlgorithmSkipped() {
        XCTAssertEqual(AuthChallenge.parse(["Digest realm=\"y\", nonce=\"n\", algorithm=SHA-256", "Basic realm=\"x\""]), .basic(realm: "x"))
        XCTAssertNil(AuthChallenge.parse(["Digest realm=\"y\", nonce=\"n\", algorithm=SHA-256"]))
        XCTAssertNil(AuthChallenge.parse(["Digest realm=\"y\", nonce=\"n\", algorithm=MD5-sess"]))
    }

    func testNoncelessDigestFallsBackToBasic() {
        XCTAssertEqual(AuthChallenge.parse(["Digest realm=\"y\"", "Basic realm=\"x\""]), .basic(realm: "x"))
    }

    func testBasic() {
        let auth = Authenticator(credentials: Credentials(username: "user", password: "pass"), challenge: .basic(realm: "x"))
        XCTAssertEqual(auth.authorization(method: "GET", uri: "/"), "Basic dXNlcjpwYXNz")
    }

    func testParseDigestWithQuotedCommas() {
        let c = AuthChallenge.parse(["Digest realm=\"a, b\", NONCE=\"abc\", qop=\"auth,auth-int\", Opaque=\"o\", algorithm=MD5"])
        XCTAssertEqual(c, .digest(realm: "a, b", nonce: "abc", opaque: "o", qop: "auth,auth-int", algorithm: "MD5"))
    }

    func testParsePrefersDigestOverBasic() {
        let c = AuthChallenge.parse(["Basic realm=\"cam\"", "Digest realm=\"cam\", nonce=\"n1\""])
        XCTAssertEqual(c, .digest(realm: "cam", nonce: "n1", opaque: nil, qop: nil, algorithm: nil))
    }

    func testParseBasicOnlyAndGarbage() {
        XCTAssertEqual(AuthChallenge.parse(["basic realm=\"cam\""]), .basic(realm: "cam"))
        XCTAssertNil(AuthChallenge.parse([]))
        XCTAssertNil(AuthChallenge.parse(["Negotiate abc", "Digest realm=\"x\""]))
        XCTAssertNil(AuthChallenge.parse([""]))
        // Unterminated quote swallows the rest, so no nonce is found.
        XCTAssertNil(AuthChallenge.parse(["Digest realm=\"unterminated, nonce=\"x"]))
    }
}
