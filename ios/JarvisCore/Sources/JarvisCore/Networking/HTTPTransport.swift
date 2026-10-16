import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Transport-agnostic HTTP request description.
public struct HTTPRequestSpec: Sendable {
    public var url: URL
    public var method: String
    public var headers: [String: String]
    public var body: Data?
    public var timeout: TimeInterval
    /// Label used in diagnostics only (never contains secrets).
    public var label: String

    public init(url: URL, method: String = "GET", headers: [String: String] = [:],
                body: Data? = nil, timeout: TimeInterval = 30, label: String = "") {
        self.url = url; self.method = method; self.headers = headers
        self.body = body; self.timeout = timeout; self.label = label
    }
}

public struct HTTPResponsePayload: Sendable {
    public var statusCode: Int
    public var headers: [String: String]
    public var data: Data

    public init(statusCode: Int, headers: [String: String] = [:], data: Data = Data()) {
        self.statusCode = statusCode; self.headers = headers; self.data = data
    }

    public var text: String { String(data: data, encoding: .utf8) ?? "" }

    public func json() throws -> JSONValue {
        do { return try JSONDecoder.jarvis.decode(JSONValue.self, from: data) }
        catch { throw JarvisError.providerBadResponse("response was not valid JSON") }
    }
}

/// Injection point for HTTP. Tests use `MockTransport`; production uses `URLSessionTransport`.
public protocol HTTPTransport: Sendable {
    func send(_ request: HTTPRequestSpec) async throws -> HTTPResponsePayload
    /// Streaming variant used by SSE-based inference endpoints.
    func stream(_ request: HTTPRequestSpec) -> AsyncThrowingStream<String, Error>
}

public extension HTTPTransport {
    /// Default streaming implementation: falls back to a single buffered response.
    func stream(_ request: HTTPRequestSpec) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let response = try await send(request)
                    guard (200..<300).contains(response.statusCode) else {
                        throw JarvisError.providerBadResponse("HTTP \(response.statusCode)")
                    }
                    continuation.yield(response.text)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

/// Real network transport.
public struct URLSessionTransport: HTTPTransport {
    private let session: URLSession

    public init(timeout: TimeInterval = 30) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = 120
        configuration.httpAdditionalHeaders = ["User-Agent": "JARVIS-iOS/1.0 (+zero-cost)"]
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        self.session = URLSession(configuration: configuration)
    }

    public func send(_ request: HTTPRequestSpec) async throws -> HTTPResponsePayload {
        var urlRequest = URLRequest(url: request.url, timeoutInterval: request.timeout)
        urlRequest.httpMethod = request.method
        urlRequest.httpBody = request.body
        for (key, value) in request.headers { urlRequest.setValue(value, forHTTPHeaderField: key) }

        do {
            let (data, response) = try await session.data(for: urlRequest)
            guard let http = response as? HTTPURLResponse else {
                throw JarvisError.network("unexpected response type")
            }
            var headers: [String: String] = [:]
            for (key, value) in http.allHeaderFields {
                if let k = key as? String, let v = value as? String { headers[k.lowercased()] = v }
            }
            return HTTPResponsePayload(statusCode: http.statusCode, headers: headers, data: data)
        } catch let error as JarvisError {
            throw error
        } catch let error as URLError {
            throw Self.mapURLError(error)
        } catch {
            if Task.isCancelled { throw JarvisError.cancelled }
            throw JarvisError.network(error.localizedDescription)
        }
    }

#if canImport(FoundationNetworking)
    /// Linux (swift-corelibs-foundation) has no `URLSession.bytes(for:)`;
    /// we buffer the response and replay it line-by-line. Real streaming is used
    /// on Apple platforms, which is where the app runs.
    public func stream(_ request: HTTPRequestSpec) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let response = try await send(request)
                    guard (200..<300).contains(response.statusCode) else {
                        throw Self.mapStatus(response.statusCode, body: response.text, headers: response.headers)
                    }
                    for line in response.text.components(separatedBy: "\n") {
                        if Task.isCancelled { break }
                        continuation.yield(line)
                    }
                    continuation.finish()
                } catch let error as JarvisError {
                    continuation.finish(throwing: error)
                } catch {
                    continuation.finish(throwing: JarvisError.network(error.localizedDescription))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
#else
    /// True incremental streaming (Apple platforms).
    public func stream(_ request: HTTPRequestSpec) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var urlRequest = URLRequest(url: request.url, timeoutInterval: request.timeout)
                    urlRequest.httpMethod = request.method
                    urlRequest.httpBody = request.body
                    for (key, value) in request.headers { urlRequest.setValue(value, forHTTPHeaderField: key) }

                    let (bytes, response) = try await session.bytes(for: urlRequest)
                    if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                        var body = ""
                        for try await line in bytes.lines { body += line + "\n"; if body.count > 4_000 { break } }
                        var headers: [String: String] = [:]
                        for (key, value) in http.allHeaderFields {
                            if let k = key as? String, let v = value as? String { headers[k.lowercased()] = v }
                        }
                        throw Self.mapStatus(http.statusCode, body: body, headers: headers)
                    }
                    for try await line in bytes.lines {
                        if Task.isCancelled { break }
                        continuation.yield(line)
                    }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish(throwing: JarvisError.cancelled)
                } catch let error as JarvisError {
                    continuation.finish(throwing: error)
                } catch let error as URLError {
                    continuation.finish(throwing: Self.mapURLError(error))
                } catch {
                    continuation.finish(throwing: JarvisError.network(error.localizedDescription))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
#endif

    static func mapURLError(_ error: URLError) -> JarvisError {
        switch error.code {
        case .timedOut: return .timeout(seconds: 30)
        case .notConnectedToInternet, .networkConnectionLost: return .network("the device appears to be offline")
        case .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed: return .network("the provider host could not be reached")
        case .secureConnectionFailed, .serverCertificateUntrusted: return .network("TLS negotiation with the provider failed")
        case .cancelled: return .cancelled
        default: return .network(error.localizedDescription)
        }
    }

    static func mapStatus(_ status: Int, body: String, headers: [String: String]) -> JarvisError {
        switch status {
        case 401, 403: return .providerUnauthorized("the provider rejected the credential (HTTP \(status))")
        case 429:
            let retry = headers["retry-after"].flatMap { Int($0) }
            return .providerQuotaExceeded(retryAfterSeconds: retry)
        case 400, 404: return .providerBadResponse("provider returned HTTP \(status): \(body.prefix(200))")
        case 500...599: return .network("provider is having trouble (HTTP \(status))")
        default: return .providerBadResponse("unexpected HTTP \(status)")
        }
    }
}

/// Retry policy with bounded exponential backoff and jitter.
public struct RetryPolicy: Sendable {
    public var maxAttempts: Int
    public var baseDelay: TimeInterval
    public var maxDelay: TimeInterval
    public var jitter: Bool

    public init(maxAttempts: Int = 3, baseDelay: TimeInterval = 1.0, maxDelay: TimeInterval = 12.0, jitter: Bool = true) {
        self.maxAttempts = maxAttempts; self.baseDelay = baseDelay
        self.maxDelay = maxDelay; self.jitter = jitter
    }

    public static let `default` = RetryPolicy()
    public static let streaming = RetryPolicy(maxAttempts: 2, baseDelay: 1.0, maxDelay: 4.0)

    public func delay(forAttempt attempt: Int) -> TimeInterval {
        let exponential = baseDelay * pow(2.0, Double(max(0, attempt - 1)))
        let capped = min(exponential, maxDelay)
        guard jitter else { return capped }
        return capped * Double.random(in: 0.7...1.3)
    }

    /// Executes `operation`, retrying only when the error is genuinely retryable.
    public func run<T>(_ operation: () async throws -> T) async throws -> T {
        var attempt = 1
        while true {
            do { return try await operation() }
            catch let error as JarvisError {
                guard error.isRetryable, attempt < maxAttempts else { throw error }
                if case .providerQuotaExceeded(let retry) = error, let retry, retry > 30 { throw error }
                let delay = delay(forAttempt: attempt)
                JarvisLog.shared.warn("net", "attempt \(attempt) failed (\(error)); retrying in \(String(format: "%.1f", delay))s")
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                attempt += 1
            } catch is CancellationError {
                throw JarvisError.cancelled
            }
        }
    }
}
