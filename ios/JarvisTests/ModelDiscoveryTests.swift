import XCTest
@testable import JarvisCore

/// Tests for live model discovery and the provider diagnostics that the Settings
/// screen shows. These exist because the first device build sent a Gemini key to
/// whichever provider happened to be selected, and the user saw only
/// "Invalid API Key" with no way to tell why.
final class ModelDiscoveryTests: XCTestCase {

    private func payload(_ json: String, status: Int = 200) -> HTTPResponsePayload {
        HTTPResponsePayload(statusCode: status, headers: [:], data: Data(json.utf8))
    }

    // MARK: Gemini

    func testGeminiListingKeepsOnlyChatCapableModels() {
        let body = """
        {"models":[
          {"name":"models/gemini-2.5-flash","displayName":"Gemini 2.5 Flash","supportedGenerationMethods":["generateContent","countTokens"]},
          {"name":"models/gemini-2.0-flash","displayName":"Gemini 2.0 Flash","supportedGenerationMethods":["generateContent"]},
          {"name":"models/text-embedding-004","displayName":"Embedding","supportedGenerationMethods":["embedContent"]},
          {"name":"models/imagen-3.0","displayName":"Imagen","supportedGenerationMethods":["generateContent"]},
          {"name":"models/gemini-2.5-pro","displayName":"Gemini 2.5 Pro","supportedGenerationMethods":["generateContent"]}
        ]}
        """
        let models = ProviderModelDiscovery.parseGemini(body).map(\.id)
        XCTAssertEqual(models, ["gemini-2.5-flash", "gemini-2.0-flash", "gemini-2.5-pro"],
                       "embedding-only and image models are dropped, the models/ prefix is stripped")
    }

    func testGeminiListingIsRankedFlashFirstAndIsStable() {
        let body = """
        {"models":[
          {"name":"models/gemini-2.5-pro","supportedGenerationMethods":["generateContent"]},
          {"name":"models/gemini-2.0-flash","supportedGenerationMethods":["generateContent"]},
          {"name":"models/gemini-2.5-flash","supportedGenerationMethods":["generateContent"]}
        ]}
        """
        let ranked = ProviderModelDiscovery.rank(ProviderModelDiscovery.parseGemini(body), preferring: ["flash"])
        XCTAssertEqual(ranked.first?.id, "gemini-2.0-flash")
        XCTAssertEqual(ranked.map(\.id), ["gemini-2.0-flash", "gemini-2.5-flash", "gemini-2.5-pro"])
    }

    func testGeminiListingSurvivesGarbage() {
        XCTAssertTrue(ProviderModelDiscovery.parseGemini("not json at all").isEmpty)
        XCTAssertTrue(ProviderModelDiscovery.parseGemini("{}").isEmpty)
        XCTAssertTrue(ProviderModelDiscovery.parseGemini("{\"models\":\"oops\"}").isEmpty)
    }

    // MARK: OpenAI-compatible

    func testOpenAIListingKeepsChatModelsOnly() {
        let body = """
        {"object":"list","data":[
          {"id":"openai/gpt-oss-120b"},{"id":"openai/gpt-oss-20b"},{"id":"qwen/qwen3-32b"},
          {"id":"whisper-large-v3"},{"id":"whisper-large-v3-turbo"},
          {"id":"meta-llama/llama-guard-4-12b"},{"id":"playai-tts"}
        ]}
        """
        let ranked = ProviderModelDiscovery.rank(ProviderModelDiscovery.parseOpenAICompatible(body),
                                                 preferring: ["gpt-oss", "llama", "qwen"])
        XCTAssertEqual(ranked.map(\.id),
                       ["openai/gpt-oss-120b", "openai/gpt-oss-20b", "qwen/qwen3-32b"],
                       "speech, guard and TTS models never appear as chat choices")
    }

    // MARK: Live call plumbing

    func testListingSendsTheKeyInTheDocumentedHeaderAndNeverInTheURL() async throws {
        let transport = MockTransport(responses: [payload("{\"data\":[{\"id\":\"gpt-oss-120b\"}]}")])
        let entry = TestFixtures.entry(id: "groq", kind: .openAICompatible)
        _ = try await ProviderModelDiscovery.list(entry: entry, apiKey: "gsk_syntheticfixture",
                                                  transport: transport)
        let recorded = try XCTUnwrap(transport.recorded.first)
        XCTAssertEqual(recorded.method, "GET")
        XCTAssertEqual(recorded.headers["Authorization"], "Bearer gsk_syntheticfixture")
        XCTAssertFalse(recorded.url.absoluteString.contains("gsk_"),
                       "a key must never be placed in the URL")
    }

    func testListingSurfacesAnInvalidKeyWithTheProvidersOwnWords() async throws {
        let transport = MockTransport(responses: [payload(
            "{\"error\":{\"code\":400,\"message\":\"API key not valid. Please pass a valid API key.\",\"status\":\"INVALID_ARGUMENT\"}}",
            status: 400)])
        let entry = TestFixtures.entry(id: "google-ai-studio", kind: .gemini)
        do {
            _ = try await ProviderModelDiscovery.list(entry: entry, apiKey: "AIzaSyntheticFixture",
                                                      transport: transport)
            XCTFail("an invalid key must throw")
        } catch let error as JarvisError {
            XCTAssertTrue(error.userMessage.contains("Re-enter"), "the UI must say what to do: \(error)")
        }
    }

    // MARK: probe() — status and provider words, never a thrown-away failure

    func testProbeReportsTheExactStatusAndTheProvidersOwnWords() async throws {
        let transport = MockTransport(responses: [payload(
            "{\"error\":{\"code\":400,\"message\":\"API key not valid. Please pass a valid API key.\",\"status\":\"INVALID_ARGUMENT\"}}",
            status: 400)])
        let entry = TestFixtures.entry(id: "google-ai-studio", kind: .gemini)
        let outcome = await ProviderModelDiscovery.probe(entry: entry, apiKey: "AIzaSyntheticFixture",
                                                         transport: transport)
        XCTAssertFalse(outcome.isSuccess)
        XCTAssertEqual(outcome.httpStatus, 400)
        XCTAssertEqual(outcome.providerMessage, "API key not valid. Please pass a valid API key.")
        XCTAssertTrue(outcome.models.isEmpty)
        XCTAssertNotNil(outcome.error)
        // The outcome carries no key material, so diagnostics can be shared safely.
        let description = String(describing: outcome)
        XCTAssertFalse(description.contains("AIzaSyntheticFixture"))
    }

    func testProbeReturnsModelsAndStatusOnSuccess() async throws {
        let transport = MockTransport(responses: [payload(
            "{\"models\":[{\"name\":\"models/gemini-2.5-flash\",\"supportedGenerationMethods\":[\"generateContent\"]}]}")])
        let entry = TestFixtures.entry(id: "google-ai-studio", kind: .gemini)
        let outcome = await ProviderModelDiscovery.probe(entry: entry, apiKey: "AIzaSyntheticFixture",
                                                         transport: transport)
        XCTAssertTrue(outcome.isSuccess)
        XCTAssertEqual(outcome.httpStatus, 200)
        XCTAssertNil(outcome.error)
        XCTAssertEqual(outcome.models.map(\.id), ["gemini-2.5-flash"])
    }

    func testProbeNeverThrowsEvenWhenTheNetworkFails() async {
        // A transport-level failure (no connectivity, DNS, timeout) must come back as a
        // value the UI can render — never as a crash or an unhandled error.
        let transport = MockTransport(errorToThrow: .network("The Internet connection appears to be offline."))
        let entry = TestFixtures.entry(id: "groq", kind: .openAICompatible)
        let outcome = await ProviderModelDiscovery.probe(entry: entry, apiKey: "gsk_syntheticfixture",
                                                         transport: transport)
        XCTAssertFalse(outcome.isSuccess)
        XCTAssertNotNil(outcome.error, "a transport failure must come back as a value, not a crash")
    }

    // MARK: Diagnostics never leak the key

    func testDiagnosticsReportHidesTheKeyButIdentifiesIt() {
        let report = ProviderDiagnostics(
            providerName: "Google AI Studio (Gemini)", providerID: "google-ai-studio",
            model: "gemini-2.5-flash", endpointHost: "generativelanguage.googleapis.com",
            requestPath: "/v1beta/models", keyFingerprint: ProviderModelDiscovery.fingerprint(of: "AIzaSyExampleKey1234abcd"),
            httpStatus: 400, providerMessage: "API key not valid.", outcome: "rejected"
        ).report()
        XCTAssertFalse(report.contains("AIzaSyExampleKey"))
        XCTAssertTrue(report.contains("…abcd · 24 characters"), "fingerprint: \(report)")
        XCTAssertTrue(report.contains("provider said: API key not valid."))
    }

    func testRedactedPathStripsAKeyThatSomehowEndedUpInAURL() {
        XCTAssertEqual(ProviderModelDiscovery.redactedPath("/v1beta/models?key=SECRET&pageSize=200"),
                       "/v1beta/models?key=<redacted>&pageSize=200")
        XCTAssertEqual(ProviderModelDiscovery.redactedPath("/v1beta/models"), "/v1beta/models")
    }

    // MARK: Error mapping that the user actually reads

    func testModelNotFoundExplainsWhatToDoInsteadOfJustPrinting404() {
        let error = URLSessionTransport.mapStatus(404, body: "{\"error\":{\"message\":\"models/nope is not found\"}}", headers: [:])
        guard case .providerBadResponse(let message) = error else {
            return XCTFail("expected a bad-response error, got \(error)")
        }
        XCTAssertTrue(message.contains("models/nope is not found"))
        XCTAssertTrue(message.contains("List models"), "must point at the picker: \(message)")
    }

    func testGoogleInvalidKeyArrivesAs400AndIsStillReportedAsAnAuthProblem() {
        let error = URLSessionTransport.mapStatus(
            400, body: "{\"error\":{\"code\":400,\"message\":\"API key not valid.\",\"status\":\"INVALID_ARGUMENT\"}}", headers: [:])
        XCTAssertEqual(error, .providerUnauthorized("the provider rejected the credential (HTTP 400) — API key not valid."))
    }

    func testOrdinary401KeepsItsPlainWording() {
        XCTAssertEqual(URLSessionTransport.mapStatus(401, body: "", headers: [:]),
                       .providerUnauthorized("the provider rejected the credential (HTTP 401)"))
    }
}
