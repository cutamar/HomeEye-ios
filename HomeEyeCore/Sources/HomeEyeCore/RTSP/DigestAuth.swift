import Foundation

public struct Credentials: Equatable {
    public let username: String
    public let password: String

    public init(username: String, password: String) {
        self.username = username
        self.password = password
    }
}

public enum AuthChallenge: Equatable {
    case basic(realm: String)
    case digest(realm: String, nonce: String, opaque: String?, qop: String?, algorithm: String?)

    /// Parses `WWW-Authenticate` header values. Digest is preferred over Basic.
    public static func parse(_ headerValues: [String]) -> AuthChallenge? {
        var basic: AuthChallenge?
        for value in headerValues {
            for (scheme, rest) in splitChallenges(value) {
                let params = parseParams(rest)
                if scheme == "digest" {
                    guard let nonce = params["nonce"], isSupported(algorithm: params["algorithm"], qop: params["qop"]) else { continue }
                    return .digest(realm: params["realm"] ?? "", nonce: nonce, opaque: params["opaque"],
                                   qop: params["qop"], algorithm: params["algorithm"])
                } else if scheme == "basic", basic == nil {
                    basic = .basic(realm: params["realm"] ?? "")
                }
            }
        }
        return basic
    }

    /// Only MD5 (and MD5-sess with qop=auth) can be answered.
    private static func isSupported(algorithm: String?, qop: String?) -> Bool {
        guard let alg = algorithm?.lowercased() else { return true }
        if alg == "md5" { return true }
        if alg == "md5-sess" { return hasAuthQop(qop) }
        return false
    }

    static func hasAuthQop(_ qop: String?) -> Bool {
        (qop ?? "").split(separator: ",").contains { $0.trimmingCharacters(in: .whitespaces).lowercased() == "auth" }
    }

    /// Splits one header value into (lowercased scheme, parameter text) challenges (RFC 7235).
    static func splitChallenges(_ value: String) -> [(String, String)] {
        // Comma-separated pieces, ignoring commas inside quotes.
        var pieces: [String] = []
        var current = ""
        var inQuotes = false
        var escaped = false
        for c in value {
            if inQuotes {
                current.append(c)
                if escaped { escaped = false } else if c == "\\" { escaped = true } else if c == "\"" { inQuotes = false }
            } else if c == "," {
                pieces.append(current); current = ""
            } else {
                if c == "\"" { inQuotes = true }
                current.append(c)
            }
        }
        pieces.append(current)

        var result: [(String, [String])] = []
        for piece in pieces {
            let t = piece.trimmingCharacters(in: .whitespaces)
            if t.isEmpty { continue }
            let tokenEnd = t.firstIndex(where: { $0 == " " || $0 == "\t" || $0 == "=" }) ?? t.endIndex
            let afterToken = t[tokenEnd...].drop(while: { $0 == " " || $0 == "\t" })
            if tokenEnd < t.endIndex, afterToken.first == "=" || (t[tokenEnd] == "=") {
                // key=value parameter of the current challenge
                if !result.isEmpty { result[result.count - 1].1.append(t) }
            } else {
                result.append((t[t.startIndex..<tokenEnd].lowercased(), [String(afterToken)]))
            }
        }
        return result.map { ($0.0, $0.1.joined(separator: ",")) }
    }

    /// Quoted-string-aware `key=value, key="value, with comma"` parser; keys lowercased.
    static func parseParams(_ s: String) -> [String: String] {
        var result: [String: String] = [:]
        let chars = Array(s)
        var i = 0
        let n = chars.count
        while i < n {
            while i < n && (chars[i] == "," || chars[i] == " " || chars[i] == "\t") { i += 1 }
            var key = ""
            while i < n && chars[i] != "=" && chars[i] != "," { key.append(chars[i]); i += 1 }
            guard i < n, chars[i] == "=" else { continue }
            i += 1
            while i < n && (chars[i] == " " || chars[i] == "\t") { i += 1 }
            var value = ""
            if i < n && chars[i] == "\"" {
                i += 1
                while i < n && chars[i] != "\"" {
                    if chars[i] == "\\" && i + 1 < n { i += 1 }
                    value.append(chars[i])
                    i += 1
                }
                if i < n { i += 1 }
            } else {
                while i < n && chars[i] != "," { value.append(chars[i]); i += 1 }
                value = value.trimmingCharacters(in: .whitespaces)
            }
            let k = key.trimmingCharacters(in: .whitespaces).lowercased()
            if !k.isEmpty { result[k] = value }
        }
        return result
    }
}

/// Builds `Authorization` header values for Basic and Digest challenges.
public final class Authenticator {
    private let credentials: Credentials
    private let challenge: AuthChallenge
    private let cnonce: String
    private var nonceCount: UInt32 = 0
    private let lock = NSLock()

    public init(credentials: Credentials, challenge: AuthChallenge, cnonce: String? = nil) {
        self.credentials = credentials
        self.challenge = challenge
        self.cnonce = cnonce ?? Authenticator.randomCnonce()
    }

    public func authorization(method: String, uri: String) -> String {
        switch challenge {
        case .basic:
            let raw = "\(credentials.username):\(credentials.password)"
            return "Basic " + Data(raw.utf8).base64EncodedString()
        case let .digest(realm, nonce, opaque, qop, algorithm):
            return digestHeader(method: method, uri: uri, realm: realm, nonce: nonce,
                                opaque: opaque, qop: qop, algorithm: algorithm)
        }
    }

    private func digestHeader(method: String, uri: String, realm: String, nonce: String,
                              opaque: String?, qop: String?, algorithm: String?) -> String {
        var ha1 = MD5.hex("\(credentials.username):\(realm):\(credentials.password)")
        if algorithm?.lowercased() == "md5-sess" {
            ha1 = MD5.hex("\(ha1):\(nonce):\(cnonce)")
        }
        let ha2 = MD5.hex("\(method):\(uri)")
        let useAuth = AuthChallenge.hasAuthQop(qop)

        var response: String
        var nc = ""
        if useAuth {
            lock.lock()
            nonceCount &+= 1
            nc = String(format: "%08x", nonceCount)
            lock.unlock()
            response = MD5.hex("\(ha1):\(nonce):\(nc):\(cnonce):auth:\(ha2)")
        } else {
            response = MD5.hex("\(ha1):\(nonce):\(ha2)")
        }

        var header = "Digest username=\"\(q(credentials.username))\", realm=\"\(q(realm))\", nonce=\"\(q(nonce))\", uri=\"\(q(uri))\", response=\"\(response)\""
        if let opaque = opaque { header += ", opaque=\"\(q(opaque))\"" }
        if let algorithm = algorithm { header += ", algorithm=\(algorithm)" }
        if useAuth { header += ", qop=auth, nc=\(nc), cnonce=\"\(cnonce)\"" }
        return header
    }

    /// Escapes `\` and `"` for use inside a quoted-string.
    private func q(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }

    private static func randomCnonce() -> String {
        var g = SystemRandomNumberGenerator()
        return (0..<8).map { _ in String(format: "%02x", UInt8.random(in: 0...255, using: &g)) }.joined()
    }
}
