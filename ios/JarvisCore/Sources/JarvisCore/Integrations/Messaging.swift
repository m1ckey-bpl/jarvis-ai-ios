import Foundation

/// WhatsApp support that is actually possible on iOS.
///
/// What this does: builds official `whatsapp://` / `wa.me` deep links so the user
/// can send a message *they* composed, and (optionally) talks to the WhatsApp
/// Business Cloud API for a business number the user owns.
///
/// What is deliberately **not** implemented: reading personal chats or DMs. No
/// official API permits that, so JARVIS never claims to (see docs/INTEGRATIONS.md).
public final class WhatsAppComposer {
    public init() {}

    public func state() -> CapabilityState { .ready }

    /// Deep link that opens WhatsApp with a prefilled message.
    public static func sendURL(phone: String?, text: String) -> URL? {
        var components = URLComponents()
        components.scheme = "whatsapp"
        components.host = "send"
        var items: [URLQueryItem] = []
        if let phone { items.append(URLQueryItem(name: "phone", value: sanitize(phone: phone))) }
        items.append(URLQueryItem(name: "text", value: text))
        components.queryItems = items
        return components.url
    }

    /// Web fallback for devices without the WhatsApp app installed.
    public static func webURL(phone: String?, text: String) -> URL? {
        var components = URLComponents(string: "https://wa.me/")
        if let phone { components?.path = "/" + sanitize(phone: phone) }
        components?.queryItems = [URLQueryItem(name: "text", value: text)]
        return components?.url
    }

    static func sanitize(phone: String) -> String {
        phone.filter { $0.isNumber || $0 == "+" }.replacingOccurrences(of: "+", with: "")
    }

    /// Waits for a user tap: the app opens the URL, it never sends by itself.
    public var requiresUserAction: Bool { true }
}

/// Email composition through the system mail composer (works with any provider).
public enum MailComposer {
    public static func url(to: String?, subject: String?, body: String?) -> URL? {
        var components = URLComponents()
        components.scheme = "mailto"
        components.path = to ?? ""
        var items: [URLQueryItem] = []
        if let subject { items.append(URLQueryItem(name: "subject", value: subject)) }
        if let body { items.append(URLQueryItem(name: "body", value: body)) }
        components.queryItems = items.isEmpty ? nil : items
        return components.url
    }
}

/// Instagram: official Graph API only, for **professional** accounts the user owns.
/// Personal-account DMs and private data are not available through any official API.
public final class InstagramClient {
    private let secrets: SecretStore
    private let http: IntegrationHTTP
    private let graphBase = URL(string: "https://graph.facebook.com/v21.0")!

    public init(secrets: SecretStore, transport: HTTPTransport = URLSessionTransport()) {
        self.secrets = secrets
        self.http = IntegrationHTTP(transport: transport)
    }

    public var token: String? { try? secrets.secret(for: SecretKey.instagramAccessToken) }

    public func state() -> CapabilityState {
        guard let token, !token.isEmpty else {
            return .requiresConfiguration(detail: "Instagram automation requires a Meta app and a professional (Business/Creator) account. Personal accounts cannot be automated through official APIs.")
        }
        return .ready
    }

    /// Reads the connected professional account's basic profile.
    public func profile() async throws -> JSONValue {
        guard let token else { throw JarvisError.providerNotConfigured }
        guard let url = URL(string: "\(graphBase)/me?fields=id,username,account_type,media_count&access_token=\(token)") else {
            throw JarvisError.unexpected("invalid Instagram Graph URL")
        }
        return try await http.get(url, token: nil, label: "instagram.profile")
    }

    /// Recent media for the connected professional account.
    public func recentMedia(limit: Int = 10) async throws -> [JSONValue] {
        guard let token else { throw JarvisError.providerNotConfigured }
        guard let url = URL(string: "\(graphBase)/me/media?fields=id,caption,media_type,permalink,timestamp&limit=\(limit)&access_token=\(token)") else {
            throw JarvisError.unexpected("invalid Instagram Graph URL")
        }
        let json = try await http.get(url, token: nil, label: "instagram.media")
        return json["data"]?.arrayValue ?? []
    }

    /// Profile deep link (opening the app is always allowed).
    public static func appURL(username: String) -> URL? {
        URL(string: "instagram://user?username=\(username)")
    }
}

/// Bridge to Apple Calendar / Reminders (EventKit). Implemented in the app layer so
/// that JarvisCore stays free of platform frameworks; this is the contract it fulfils.
public protocol CalendarBridge: AnyObject {
    func state() async -> CapabilityState
    func requestAccess() async -> CapabilityState
    func upcomingEvents(days: Int) async throws -> [(title: String, start: Date, end: Date, calendar: String, location: String?)]
    func createEvent(title: String, start: Date, end: Date, notes: String?, calendarName: String?) async throws -> String
}
