import XCTest
@testable import JarvisCore

final class IntegrationTests: XCTestCase {

    // MARK: WhatsApp (on-device compose only)

    func testWhatsAppDeepLinkIsBuiltCorrectly() throws {
        let url = try XCTUnwrap(WhatsAppComposer.sendURL(phone: "+91 98765 43210", text: "Hello there"))
        XCTAssertEqual(url.scheme, "whatsapp")
        XCTAssertEqual(url.host, "send")
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let items = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(items["phone"], "919876543210", "only digits survive sanitisation")
        XCTAssertEqual(items["text"], "Hello there")
    }

    func testWhatsAppWebFallback() throws {
        let url = try XCTUnwrap(WhatsAppComposer.webURL(phone: "919876543210", text: "hi"))
        XCTAssertEqual(url.absoluteString, "https://wa.me/919876543210?text=hi")
    }

    func testWhatsAppComposeToolNeverClaimsToSend() async throws {
        let tool = WhatsAppComposeTool()
        let result = try await tool.execute(arguments: .obj(("text", .string("hello"))),
                                            context: ToolExecutionContext())
        XCTAssertTrue(result.success)
        XCTAssertFalse(result.verified, "JARVIS did not send anything — it prepared a link")
        XCTAssertEqual(result.payload?["sent"]?.boolValue, false)
        XCTAssertTrue(result.summary.contains("NOT sent") || result.summary.contains("yourself"))
    }

    func testMailtoComposer() throws {
        let url = try XCTUnwrap(MailComposer.url(to: "a@b.com", subject: "Hi", body: "Body"))
        XCTAssertTrue(url.absoluteString.hasPrefix("mailto:a@b.com?"))
        XCTAssertTrue(url.absoluteString.contains("subject=Hi"))
    }

    // MARK: GitHub

    func testGitHubReportsUnconfiguredWithoutToken() {
        let client = GitHubClient(secrets: InMemorySecretStore(), transport: MockTransport())
        if case .requiresConfiguration(let detail) = client.state() {
            XCTAssertTrue(detail.contains("Settings"))
        } else { XCTFail("expected requiresConfiguration") }
    }

    func testGitHubCreateIssueRequiresServerConfirmation() async throws {
        // GitHub replies without an issue number: JARVIS must not report success.
        let transport = MockTransport(responses: [HTTPResponsePayload(statusCode: 200, data: Data("{}".utf8))])
        let secrets = InMemorySecretStore(seed: [SecretKey.githubToken: "test-token"])
        let client = GitHubClient(secrets: secrets, transport: transport)
        do {
            _ = try await client.createIssue(owner: "o", repo: "r", title: "t", body: "b")
            XCTFail("must not report an unconfirmed issue as created")
        } catch let error as JarvisError {
            if case .providerBadResponse(let message) = error { XCTAssertTrue(message.contains("did not confirm")) }
            else { XCTFail("wrong error: \(error)") }
        }
        XCTAssertEqual(transport.recorded.first?.headers["Authorization"], "Bearer test-token")
        XCTAssertEqual(transport.recorded.first?.method, "POST")
    }

    func testGitHubDeviceFlowPollingStates() async throws {
        let secrets = InMemorySecretStore()
        let pending = HTTPResponsePayload(statusCode: 200, data: Data(#"{"error":"authorization_pending"}"#.utf8))
        let transport = MockTransport(responses: [pending])
        let client = GitHubClient(secrets: secrets, transport: transport)
        let token = try await client.pollDeviceFlow(clientID: "cid", deviceCode: "dc")
        XCTAssertNil(token, "pending authorization is not an error, and definitely not a token")

        let granted = HTTPResponsePayload(statusCode: 200, data: Data(#"{"access_token":"gho_test123"}"#.utf8))
        let transport2 = MockTransport(responses: [granted])
        let client2 = GitHubClient(secrets: secrets, transport: transport2)
        let grantedToken = try await client2.pollDeviceFlow(clientID: "cid", deviceCode: "dc")
        XCTAssertEqual(grantedToken, "gho_test123")

        let denied = HTTPResponsePayload(statusCode: 200, data: Data(#"{"error":"access_denied"}"#.utf8))
        let transport3 = MockTransport(responses: [denied])
        let client3 = GitHubClient(secrets: secrets, transport: transport3)
        do {
            _ = try await client3.pollDeviceFlow(clientID: "cid", deviceCode: "dc")
            XCTFail("denial must surface")
        } catch let error as JarvisError {
            if case .policyBlocked = error {} else { XCTFail("wrong error: \(error)") }
        }
    }

    func testGitHubRateLimitIsReportedAsQuota() async throws {
        let transport = MockTransport(responses: [HTTPResponsePayload(statusCode: 429, headers: ["retry-after": "60"], data: Data("{}".utf8))])
        let secrets = InMemorySecretStore(seed: [SecretKey.githubToken: "t"])
        let client = GitHubClient(secrets: secrets, transport: transport)
        do {
            _ = try await client.repositories()
            XCTFail("expected quota error")
        } catch let error as JarvisError {
            XCTAssertEqual(error, .providerQuotaExceeded(retryAfterSeconds: 60))
        }
    }

    // MARK: Gmail

    func testGmailMimeEncodingIsBase64URL() {
        let raw = GmailClient.mimeMessage(to: "a@b.com", subject: "Test", body: "Hello")
        XCTAssertFalse(raw.contains("+"))
        XCTAssertFalse(raw.contains("/"))
        XCTAssertFalse(raw.contains("="))
        let padded = raw.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        let withPadding = padded + String(repeating: "=", count: (4 - padded.count % 4) % 4)
        let decoded = String(data: Data(base64Encoded: withPadding) ?? Data(), encoding: .utf8) ?? ""
        XCTAssertTrue(decoded.contains("To: a@b.com"))
        XCTAssertTrue(decoded.contains("Subject: Test"))
    }

    func testGmailSendRequiresMessageIDConfirmation() async throws {
        let secrets = InMemorySecretStore(seed: [SecretKey.gmailAccessToken: "token"])
        let transport = MockTransport(responses: [HTTPResponsePayload(statusCode: 200, data: Data("{}".utf8))])
        let client = GmailClient(secrets: secrets, transport: transport)
        do {
            _ = try await client.send(rawMessage: "raw")
            XCTFail("an email is only sent when the server confirms it with an id")
        } catch let error as JarvisError {
            if case .providerBadResponse(let message) = error { XCTAssertTrue(message.contains("send")) }
            else { XCTFail("wrong error: \(error)") }
        }
    }

    func testGmailPlainTextExtractionDecodesBase64URL() throws {
        let body = "Invoice attached, total 42."
        let encoded = PKCE.base64URL(Data(body.utf8))
        let payload = JSONValue.obj(("mimeType", .string("text/plain")), ("body", .obj(("data", .string(encoded)))))
        XCTAssertEqual(GmailClient.extractPlainText(payload), body)
    }

    func testGmailSearchParsesMessageList() async throws {
        let json = #"{"messages":[{"id":"18f1","threadId":"t1"},{"id":"18f2","threadId":"t2"}]}"#
        let secrets = InMemorySecretStore(seed: [SecretKey.gmailAccessToken: "token"])
        let transport = MockTransport(responses: [HTTPResponsePayload(statusCode: 200, data: Data(json.utf8))])
        let client = GmailClient(secrets: secrets, transport: transport)
        let messages = try await client.search("is:unread", limit: 10)
        XCTAssertEqual(messages.count, 2)
        XCTAssertTrue(transport.recorded.first?.url.absoluteString.contains("q=is:unread") ?? false)
    }

    // MARK: PKCE / OAuth helpers

    func testPKCEBase64URLEncodingHasNoPadding() {
        let data = Data([0xFB, 0xFF, 0x3E, 0x3F])
        let encoded = PKCE.base64URL(data)
        XCTAssertFalse(encoded.contains("="))
        XCTAssertFalse(encoded.contains("+"))
        XCTAssertFalse(encoded.contains("/"))
    }

    func testVerifierIsRandomAndURLSafe() {
        let characters = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        let a = PKCE.randomVerifier()
        let b = PKCE.randomVerifier()
        XCTAssertNotEqual(a, b)
        XCTAssertEqual(a.count, 64)
        XCTAssertTrue(a.unicodeScalars.allSatisfy { characters.contains($0) })
    }

    func testGoogleAuthorizationURLContainsRequiredParameters() throws {
        let url = try XCTUnwrap(GoogleOAuth.authorizationURL(clientID: "cid", redirectURI: "com.jarvis.app:/oauth",
                                                             scopes: [GoogleOAuth.gmailReadOnlyScope],
                                                             codeChallenge: "challenge", state: "state123"))
        let items = Dictionary(uniqueKeysWithValues: (URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? [])
            .map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(items["client_id"], "cid")
        XCTAssertEqual(items["code_challenge_method"], "S256")
        XCTAssertEqual(items["state"], "state123")
        XCTAssertEqual(items["access_type"], "offline")
        XCTAssertTrue(items["scope"]?.contains("gmail.readonly") ?? false)
        XCTAssertFalse(items.keys.contains("client_secret"), "no client secret is ever placed in the URL")
    }

    // MARK: Instagram limits are surfaced, not hidden

    func testInstagramExplainsItsLimitations() {
        let client = InstagramClient(secrets: InMemorySecretStore(), transport: MockTransport())
        if case .requiresConfiguration(let detail) = client.state() {
            XCTAssertTrue(detail.lowercased().contains("professional"))
            XCTAssertTrue(detail.lowercased().contains("personal"))
        } else { XCTFail("expected requiresConfiguration") }
    }
}
