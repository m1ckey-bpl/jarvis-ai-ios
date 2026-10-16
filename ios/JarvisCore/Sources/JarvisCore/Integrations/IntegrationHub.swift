import Foundation

/// Aggregates optional integrations. Each one is independent and reports its own
/// honest capability state; a missing integration never breaks the others.
public final class IntegrationHub {
    public let github: GitHubClient?
    public let gmail: GmailClient?
    public let instagram: InstagramClient?
    public let whatsapp: WhatsAppComposer
    public let calendar: CalendarBridge?
    public let capabilities: CapabilityRegistry

    public init(secrets: SecretStore, transport: HTTPTransport = URLSessionTransport(),
                capabilities: CapabilityRegistry = CapabilityRegistry(),
                calendar: CalendarBridge? = nil) {
        self.capabilities = capabilities
        self.github = GitHubClient(secrets: secrets, transport: transport)
        self.gmail = GmailClient(secrets: secrets, transport: transport)
        self.instagram = InstagramClient(secrets: secrets, transport: transport)
        self.whatsapp = WhatsAppComposer()
        self.calendar = calendar
    }

    /// Refreshes the capability registry from the current credential/config state.
    public func refreshCapabilities() async {
        capabilities.update(id: CapabilityID.github, state: (github?.state() ?? .unavailable(reason: "not initialised")))
        capabilities.update(id: CapabilityID.gmail, state: (gmail?.state() ?? .unavailable(reason: "not initialised")))
        capabilities.update(id: CapabilityID.instagram, state: (instagram?.state() ?? .unavailable(reason: "not initialised")))
        capabilities.update(id: CapabilityID.whatsapp, state: whatsapp.state())
        if let calendar {
            capabilities.update(id: CapabilityID.appleCalendar, state: await calendar.state())
        }
    }
}

/// Minimal HTTP JSON helper shared by integration clients.
struct IntegrationHTTP {
    let transport: HTTPTransport

    func get(_ url: URL, token: String?, extraHeaders: [String: String] = [:], label: String) async throws -> JSONValue {
        try await request(url, method: "GET", token: token, extraHeaders: extraHeaders, body: nil, label: label)
    }

    func request(_ url: URL, method: String, token: String?, extraHeaders: [String: String] = [:],
                 body: Data?, label: String) async throws -> JSONValue {
        var headers = extraHeaders
        if let token, !token.isEmpty { headers["Authorization"] = "Bearer \(token)" }
        if body != nil { headers["Content-Type"] = "application/json" }
        let response = try await transport.send(HTTPRequestSpec(url: url, method: method, headers: headers,
                                                                body: body, timeout: 30, label: label))
        guard (200..<300).contains(response.statusCode) else {
            // Many APIs explain 4xx failures in a JSON body ("message" / "error").
            // Those explanations are surfaced verbatim so the UI can be specific.
            let detail = (try? response.json())
                .flatMap { $0["message"]?.stringValue ?? $0["error"]?["message"]?.stringValue }
            let suffix = detail.map { ": \($0)" } ?? ""
            if response.statusCode == 401 || response.statusCode == 403 {
                throw JarvisError.providerUnauthorized("\(label)\(suffix)")
            }
            if response.statusCode == 404 { throw JarvisError.unavailable(reason: "\(label): the requested item was not found\(suffix)") }
            if response.statusCode == 429 { throw JarvisError.providerQuotaExceeded(retryAfterSeconds: response.headers["retry-after"].flatMap(Int.init)) }
            throw JarvisError.network("\(label) failed with HTTP \(response.statusCode)\(suffix)")
        }
        return try response.json()
    }
}
