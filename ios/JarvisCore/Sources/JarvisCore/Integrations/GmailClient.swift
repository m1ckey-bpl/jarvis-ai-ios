import Foundation

/// Gmail integration via Google's official Gmail REST API (OAuth 2.0).
///
/// Scope requested by the app: `gmail.readonly` for search/read and
/// `gmail.compose` (or `gmail.send`) only if the user explicitly enables sending.
/// Sending is `communicating` risk → always confirmed by the tool engine.
public final class GmailClient {
    private let secrets: SecretStore
    private let http: IntegrationHTTP
    private let base = URL(string: "https://gmail.googleapis.com/gmail/v1/users/me")!

    public init(secrets: SecretStore, transport: HTTPTransport = URLSessionTransport()) {
        self.secrets = secrets
        self.http = IntegrationHTTP(transport: transport)
    }

    public var accessToken: String? { try? secrets.secret(for: SecretKey.gmailAccessToken) }
    public var refreshToken: String? { try? secrets.secret(for: SecretKey.gmailRefreshToken) }

    public func state() -> CapabilityState {
        guard let token = accessToken, !token.isEmpty else {
            return .requiresConfiguration(detail: "Connect Gmail in Settings ▸ Connected Services (Google OAuth, read-only by default).")
        }
        return .ready
    }

    private func url(_ path: String, query: [URLQueryItem] = []) -> URL {
        var components = URLComponents(url: base.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { components.queryItems = query }
        return components.url!
    }

    // MARK: Reads

    public func search(_ query: String, limit: Int = 10) async throws -> [JSONValue] {
        let json = try await http.get(url("messages", query: [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "maxResults", value: String(limit))
        ]), token: accessToken, label: "gmail.search")
        return json["messages"]?.arrayValue ?? []
    }

    /// Fetches metadata + a plain-text body excerpt. Bodies are treated as
    /// UNTRUSTED content by the caller (prompt-injection guard).
    public func message(id: String) async throws -> (id: String, subject: String, from: String, date: Date?, body: String) {
        let json = try await http.get(url("messages/\(id)", query: [URLQueryItem(name: "format", value: "full")]),
                                     token: accessToken, label: "gmail.message")
        let headers = json["payload"]?["headers"]?.arrayValue ?? []
        func header(_ name: String) -> String {
            headers.first { $0["name"]?.stringValue?.lowercased() == name.lowercased() }?["value"]?.stringValue ?? ""
        }
        let body = Self.extractPlainText(json["payload"]) ?? json["snippet"]?.stringValue ?? ""
        let date = header("Date").isEmpty ? nil : Self.parseRFC2822(header("Date"))
        return (id, header("Subject"), header("From"), date, body)
    }

    static func extractPlainText(_ payload: JSONValue?) -> String? {
        guard let payload else { return nil }
        if let mime = payload["mimeType"]?.stringValue, mime == "text/plain",
           let data = payload["body"]?["data"]?.stringValue {
            return decodeBase64URL(data)
        }
        for part in payload["parts"]?.arrayValue ?? [] {
            if let text = extractPlainText(part) { return text }
        }
        if let data = payload["body"]?["data"]?.stringValue { return decodeBase64URL(data) }
        return nil
    }

    static func decodeBase64URL(_ value: String) -> String? {
        var base64 = value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 { base64 += "=" }
        guard let data = Data(base64Encoded: base64) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func parseRFC2822(_ value: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEE, d MMM yyyy HH:mm:ss Z"
        return formatter.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }

    // MARK: Drafts and sending (never silently)

    public func createDraft(to: String, subject: String, body: String, threadID: String? = nil) async throws -> JSONValue {
        let raw = Self.mimeMessage(to: to, subject: subject, body: body)
        var payload: [String: JSONValue] = ["message": .obj(("raw", .string(raw)))]
        if let threadID { payload["message"] = .obj(("raw", .string(raw)), ("threadId", .string(threadID))) }
        let json = try await http.request(url("drafts"), method: "POST", token: accessToken,
                                          body: try JSONEncoder.jarvis.encode(JSONValue.object(payload)), label: "gmail.draft")
        guard json["id"]?.stringValue != nil else {
            throw JarvisError.providerBadResponse("Gmail did not confirm draft creation")
        }
        return json
    }

    public func send(rawMessage: String, threadID: String? = nil) async throws -> JSONValue {
        var payload: [String: JSONValue] = ["raw": .string(rawMessage)]
        if let threadID { payload["threadId"] = .string(threadID) }
        let json = try await http.request(url("messages/send"), method: "POST", token: accessToken,
                                          body: try JSONEncoder.jarvis.encode(JSONValue.object(payload)), label: "gmail.send")
        // Only a returned message id counts as a sent email.
        guard let id = json["id"]?.stringValue, !id.isEmpty else {
            throw JarvisError.providerBadResponse("Gmail did not confirm the send (no message id returned)")
        }
        return json
    }

    static func mimeMessage(to: String, subject: String, body: String) -> String {
        let message = "To: \(to)\r\nSubject: \(subject)\r\nContent-Type: text/plain; charset=UTF-8\r\n\r\n\(body)"
        let data = Data(message.utf8)
        return data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

/// OAuth 2.0 + PKCE request construction for Google (device/authorization code flows).
/// The actual browser step is performed by `ASWebAuthenticationSession` in the app layer;
/// only non-secret parameters are produced here.
public enum GoogleOAuth {
    public static let authorizationEndpoint = URL(string: "https://accounts.google.com/o/oauth2/v2/auth")!
    public static let tokenEndpoint = URL(string: "https://oauth2.googleapis.com/token")!
    public static let gmailReadOnlyScope = "https://www.googleapis.com/auth/gmail.readonly"
    public static let gmailSendScope = "https://www.googleapis.com/auth/gmail.send"

    /// Builds the authorization URL. `codeChallenge` is the S256 PKCE challenge.
    public static func authorizationURL(clientID: String, redirectURI: String, scopes: [String],
                                        codeChallenge: String, state: String) -> URL? {
        var components = URLComponents(url: authorizationEndpoint, resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: scopes.joined(separator: " ")),
            URLQueryItem(name: "code_challenge", value: codeChallenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "access_type", value: "offline"),
            URLQueryItem(name: "prompt", value: "consent"),
            URLQueryItem(name: "state", value: state)
        ]
        return components?.url
    }
}

/// RFC 7636 PKCE helper (testable, no crypto dependencies beyond CommonCrypto-free SHA256 in the app layer).
public struct PKCE {
    public let verifier: String
    public let challenge: String

    /// `challenge` must be `base64url(sha256(verifier))`; the hash is supplied by the
    /// caller so this type stays dependency-free and unit-testable.
    public init(verifier: String, challenge: String) {
        self.verifier = verifier
        self.challenge = challenge
    }

    public static func randomVerifier(length: Int = 64) -> String {
        let characters = Array("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        return String((0..<length).map { _ in characters[Int.random(in: 0..<characters.count)] })
    }

    public static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
