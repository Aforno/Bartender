import Foundation

enum HTTPProbe {
    struct Result: Sendable {
        var ok: Bool
        var statusCode: Int?
        var message: String
        var latencyMS: Int
    }

    static func check(
        urlString: String,
        expectedStatusCode: Int?,
        timeout: TimeInterval
    ) async -> Result {
        guard let url = URL(string: urlString) else {
            return Result(ok: false, statusCode: nil, message: "Invalid URL", latencyMS: 0)
        }

        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = "GET"
        request.cachePolicy = .reloadIgnoringLocalCacheData

        let started = Date()
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            let latency = Int(Date().timeIntervalSince(started) * 1000)
            guard let http = response as? HTTPURLResponse else {
                return Result(ok: false, statusCode: nil, message: "Non-HTTP response", latencyMS: latency)
            }
            let code = http.statusCode
            let ok: Bool
            if let expected = expectedStatusCode {
                ok = code == expected
            } else {
                ok = (200...399).contains(code)
            }
            return Result(
                ok: ok,
                statusCode: code,
                message: ok ? "HTTP \(code)" : "HTTP \(code)",
                latencyMS: latency
            )
        } catch {
            let latency = Int(Date().timeIntervalSince(started) * 1000)
            return Result(ok: false, statusCode: nil, message: error.localizedDescription, latencyMS: latency)
        }
    }
}
