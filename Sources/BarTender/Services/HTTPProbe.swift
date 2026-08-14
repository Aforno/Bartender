import Foundation

enum HTTPProbe {
    struct Result: Sendable {
        var ok: Bool
        var statusCode: Int?
        var message: String
        var latencyMS: Int
        var displayURL: String
    }

    static func check(
        urlString: String,
        expectedStatusCode: Int?,
        timeout: TimeInterval
    ) async -> Result {
        guard let url = validatedRequestURL(urlString) else {
            return Result(
                ok: false,
                statusCode: nil,
                message: "Invalid URL",
                latencyMS: 0,
                displayURL: sanitizedDisplayString(from: urlString)
            )
        }

        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = "GET"
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let displayURL = sanitizedDisplayString(for: url)

        let started = Date()
        do {
            // We only need the final response headers. `bytes(for:)` exposes
            // them without buffering an arbitrary or never-ending body; cancel
            // the underlying task as soon as the status has been captured.
            let (bytes, response) = try await URLSession.shared.bytes(for: request)
            defer { bytes.task.cancel() }
            let latency = Int(Date().timeIntervalSince(started) * 1000)
            guard let http = response as? HTTPURLResponse else {
                return Result(
                    ok: false,
                    statusCode: nil,
                    message: "Non-HTTP response",
                    latencyMS: latency,
                    displayURL: displayURL
                )
            }
            let code = http.statusCode
            let ok = isHealthy(statusCode: code, expectedStatusCode: expectedStatusCode)
            return Result(
                ok: ok,
                statusCode: code,
                message: "HTTP \(code)",
                latencyMS: latency,
                displayURL: displayURL
            )
        } catch {
            let latency = Int(Date().timeIntervalSince(started) * 1000)
            return Result(
                ok: false,
                statusCode: nil,
                message: error.localizedDescription,
                latencyMS: latency,
                displayURL: displayURL
            )
        }
    }

    /// Re-validates at the execution boundary so a mutated manifest cannot skip
    /// the http(s)+host checks applied at import/save time.
    static func validatedRequestURL(_ urlString: String) -> URL? {
        guard let url = URL(string: urlString),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = url.host,
              !host.isEmpty else {
            return nil
        }
        return url
    }

    /// 2xx is healthy unless the applet configured an exact status code.
    static func isHealthy(statusCode: Int, expectedStatusCode: Int?) -> Bool {
        if let expected = expectedStatusCode {
            return statusCode == expected
        }
        return (200...299).contains(statusCode)
    }

    static func sanitizedDisplayString(for url: URL) -> String {
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.user = nil
        components?.password = nil
        return components?.string ?? url.absoluteString
    }

    static func sanitizedDisplayString(from urlString: String) -> String {
        if let url = URL(string: urlString) {
            return sanitizedDisplayString(for: url)
        }
        return urlString
    }
}
