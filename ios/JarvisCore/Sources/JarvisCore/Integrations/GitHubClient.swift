import Foundation

/// GitHub integration via the documented REST API using a personal access token
/// (fine-grained, least privilege) or an OAuth token obtained by device flow.
///
/// The token lives in the Keychain. Requests are read-mostly; anything that writes
/// is `modifying`/`communicating` risk and goes through confirmation.
public final class GitHubClient {
    private let secrets: SecretStore
    private let http: IntegrationHTTP
    private let apiBase: URL

    public init(secrets: SecretStore, transport: HTTPTransport = URLSessionTransport(),
                apiBase: URL = URL(string: "https://api.github.com")!) {
        self.secrets = secrets
        self.http = IntegrationHTTP(transport: transport)
        self.apiBase = apiBase
    }

    public var token: String? { try? secrets.secret(for: SecretKey.githubToken) }

    public func state() -> CapabilityState {
        guard let token, !token.isEmpty else {
            return .requiresConfiguration(detail: "Add a GitHub personal access token (or connect via device flow) in Settings ▸ Connected Services.")
        }
        return .ready
    }

    private func url(_ path: String, query: [URLQueryItem] = []) throws -> URL {
        guard var components = URLComponents(url: apiBase.appendingPathComponent(path), resolvingAgainstBaseURL: false) else {
            throw JarvisError.invalidArguments("invalid GitHub API path")
        }
        if !query.isEmpty { components.queryItems = query }
        guard let url = components.url else { throw JarvisError.invalidArguments("invalid GitHub API URL") }
        return url
    }

    private var headers: [String: String] {
        ["Accept": "application/vnd.github+json", "X-GitHub-Api-Version": "2022-11-28"]
    }

    // MARK: Reads

    public func currentUser() async throws -> JSONValue {
        try await http.get(try url("user"), token: token, extraHeaders: headers, label: "github.user")
    }

    public func repositories(limit: Int = 30) async throws -> [JSONValue] {
        let json = try await http.get(try url("user/repos", query: [
            URLQueryItem(name: "per_page", value: String(limit)),
            URLQueryItem(name: "sort", value: "updated")
        ]), token: token, extraHeaders: headers, label: "github.repos")
        return json.arrayValue ?? []
    }

    public func issues(owner: String, repo: String, state: String = "open", limit: Int = 20) async throws -> [JSONValue] {
        let json = try await http.get(try url("repos/\(owner)/\(repo)/issues", query: [
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "per_page", value: String(limit))
        ]), token: token, extraHeaders: headers, label: "github.issues")
        return json.arrayValue ?? []
    }

    public func notifications(limit: Int = 20) async throws -> [JSONValue] {
        let json = try await http.get(try url("notifications", query: [URLQueryItem(name: "per_page", value: String(limit))]),
                                      token: token, extraHeaders: headers, label: "github.notifications")
        return json.arrayValue ?? []
    }

    public func fileContents(owner: String, repo: String, path: String, ref: String? = nil) async throws -> String {
        var query: [URLQueryItem] = []
        if let ref { query.append(URLQueryItem(name: "ref", value: ref)) }
        let json = try await http.get(try url("repos/\(owner)/\(repo)/contents/\(path)", query: query),
                                     token: token, extraHeaders: headers, label: "github.contents")
        guard let encoded = json["content"]?.stringValue else {
            throw JarvisError.unavailable(reason: "GitHub returned no file content for \(path) (is it a directory?)")
        }
        let cleaned = encoded.replacingOccurrences(of: "\n", with: "")
        guard let data = Data(base64Encoded: cleaned), let text = String(data: data, encoding: .utf8) else {
            throw JarvisError.providerBadResponse("GitHub file content could not be decoded")
        }
        return text
    }

    // MARK: Writes (confirmed by the tool engine before these run)

    public func createIssue(owner: String, repo: String, title: String, body: String, labels: [String] = []) async throws -> JSONValue {
        let payload: JSONValue = .obj(("title", .string(title)), ("body", .string(body)), ("labels", .array(labels.map { .string($0) })))
        let json = try await http.request(try url("repos/\(owner)/\(repo)/issues"), method: "POST", token: token,
                                          extraHeaders: headers, body: try JSONEncoder.jarvis.encode(payload), label: "github.createIssue")
        guard json["number"]?.intValue != nil else {
            throw JarvisError.providerBadResponse("GitHub did not confirm the created issue")
        }
        return json
    }

    public func addComment(owner: String, repo: String, issueNumber: Int, body: String) async throws -> JSONValue {
        let payload: JSONValue = .obj(("body", .string(body)))
        let json = try await http.request(try url("repos/\(owner)/\(repo)/issues/\(issueNumber)/comments"), method: "POST",
                                          token: token, extraHeaders: headers, body: try JSONEncoder.jarvis.encode(payload),
                                          label: "github.addComment")
        guard json["id"]?.intValue != nil else {
            throw JarvisError.providerBadResponse("GitHub did not confirm the comment")
        }
        return json
    }

    /// Creates a branch ref (used by the coding agent flow). Requires an existing SHA.
    public func createBranch(owner: String, repo: String, branch: String, fromSHA: String) async throws -> JSONValue {
        let payload: JSONValue = .obj(("ref", .string("refs/heads/\(branch)")), ("sha", .string(fromSHA)))
        return try await http.request(try url("repos/\(owner)/\(repo)/git/refs"), method: "POST", token: token,
                                      extraHeaders: headers, body: try JSONEncoder.jarvis.encode(payload), label: "github.createBranch")
    }

    /// Head SHA of a branch — the base for the coding agent's working branch.
    public func headSHA(owner: String, repo: String, branch: String) async throws -> String {
        let json = try await http.get(try url("repos/\(owner)/\(repo)/git/ref/heads/\(branch)"),
                                      token: token, extraHeaders: headers, label: "github.headSHA")
        guard let sha = json["object"]?["sha"]?.stringValue else {
            throw JarvisError.providerBadResponse("GitHub did not return a branch head for \(branch)")
        }
        return sha
    }

    /// Commits (creates or updates) a text file on a branch. Returns the commit SHA.
    public func commitFile(owner: String, repo: String, path: String, content: String,
                           message: String, branch: String) async throws -> String {
        let encoded = Data(content.utf8).base64EncodedString()
        let payload: JSONValue = .obj(
            ("message", .string(message)),
            ("content", .string(encoded)),
            ("branch", .string(branch))
        )
        let json = try await http.request(try url("repos/\(owner)/\(repo)/contents/\(path)"), method: "PUT",
                                          token: token, extraHeaders: headers,
                                          body: try JSONEncoder.jarvis.encode(payload),
                                          label: "github.commitFile")
        guard let sha = json["commit"]?["sha"]?.stringValue else {
            throw JarvisError.providerBadResponse("GitHub did not confirm the commit")
        }
        return sha
    }

    /// Opens a pull request. Reviewable and revertible by design.
    public func openPullRequest(owner: String, repo: String, title: String,
                                head: String, base: String, body: String) async throws -> (number: Int, htmlURL: String) {
        let payload: JSONValue = .obj(
            ("title", .string(title)), ("head", .string(head)),
            ("base", .string(base)), ("body", .string(body))
        )
        let json = try await http.request(try url("repos/\(owner)/\(repo)/pulls"), method: "POST",
                                          token: token, extraHeaders: headers,
                                          body: try JSONEncoder.jarvis.encode(payload),
                                          label: "github.openPullRequest")
        guard let number = json["number"]?.intValue, let html = json["html_url"]?.stringValue else {
            throw JarvisError.providerBadResponse("GitHub did not confirm the pull request")
        }
        return (number, html)
    }

    // MARK: OAuth device flow (no client secret required for public clients)

    public struct DeviceCodeResponse: Equatable, Sendable {
        public var deviceCode: String
        public var userCode: String
        public var verificationURI: String
        public var interval: Int
        public var expiresIn: Int
    }

    /// Starts GitHub's device-flow authorization. Requires a GitHub OAuth app
    /// client id (the user's own, free to create). Documented in INTEGRATIONS.md.
    public func startDeviceFlow(clientID: String, scope: String = "repo read:user") async throws -> DeviceCodeResponse {
        guard let url = URL(string: "https://github.com/login/device/code") else {
            throw JarvisError.unexpected("invalid GitHub device flow URL")
        }
        let body = "client_id=\(clientID)&scope=\(scope.replacingOccurrences(of: " ", with: "%20"))".data(using: .utf8)
        let response = try await http.transport.send(HTTPRequestSpec(
            url: url, method: "POST", headers: ["Accept": "application/json", "Content-Type": "application/x-www-form-urlencoded"],
            body: body, timeout: 30, label: "github.deviceCode"))
        let json = try response.json()
        guard let deviceCode = json["device_code"]?.stringValue,
              let userCode = json["user_code"]?.stringValue,
              let verification = json["verification_uri"]?.stringValue else {
            throw JarvisError.providerBadResponse("GitHub did not return a device code")
        }
        return DeviceCodeResponse(deviceCode: deviceCode, userCode: userCode, verificationURI: verification,
                                  interval: json["interval"]?.intValue ?? 5, expiresIn: json["expires_in"]?.intValue ?? 900)
    }

    /// Polls for the access token. Returns nil while the user has not finished.
    public func pollDeviceFlow(clientID: String, deviceCode: String) async throws -> String? {
        guard let url = URL(string: "https://github.com/login/oauth/access_token") else {
            throw JarvisError.unexpected("invalid GitHub token URL")
        }
        let body = "client_id=\(clientID)&device_code=\(deviceCode)&grant_type=urn:ietf:params:oauth:grant-type:device_code"
            .data(using: .utf8)
        let response = try await http.transport.send(HTTPRequestSpec(
            url: url, method: "POST", headers: ["Accept": "application/json", "Content-Type": "application/x-www-form-urlencoded"],
            body: body, timeout: 30, label: "github.deviceToken"))
        let json = try response.json()
        if let token = json["access_token"]?.stringValue, !token.isEmpty { return token }
        switch json["error"]?.stringValue {
        case "authorization_pending", "slow_down": return nil
        case "expired_token": throw JarvisError.timeout(seconds: 900)
        case "access_denied": throw JarvisError.policyBlocked("GitHub authorization was denied by the user")
        case let other?: throw JarvisError.providerBadResponse("GitHub device flow error: \(other)")
        case nil: return nil
        }
    }
}
