import Foundation

enum HTTPStreaming {
    /// Status codes worth one more try before giving up (rate limit, overload, transient server errors).
    static let retryableStatuses: Set<Int> = [408, 429, 500, 502, 503, 504, 529]

    static func getJSON(
        url: URL,
        headers: [String: String] = [:],
        session: URLSession
    ) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 20
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw ChatProviderError.underlying("Invalid response type")
        }
        return (data, http)
    }

    static func postData(
        url: URL,
        headers: [String: String],
        body: [String: Any],
        session: URLSession
    ) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 60
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw ChatProviderError.underlying("Invalid response type")
        }
        return (data, http)
    }

    /// POSTs JSON and yields the response body line by line (SSE or NDJSON).
    /// Retries transient failures that happen before any bytes are streamed.
    static func streamLines(
        url: URL,
        headers: [String: String],
        body: [String: Any],
        session: URLSession,
        maxAttempts: Int = 3
    ) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var request = URLRequest(url: url)
                    request.httpMethod = "POST"
                    request.timeoutInterval = 300
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    for (key, value) in headers {
                        request.setValue(value, forHTTPHeaderField: key)
                    }
                    request.httpBody = try JSONSerialization.data(withJSONObject: body)

                    var attempt = 0
                    while true {
                        attempt += 1
                        let (bytes, response) = try await session.bytes(for: request)
                        guard let http = response as? HTTPURLResponse else {
                            throw ChatProviderError.underlying("Invalid response type")
                        }
                        if (200...299).contains(http.statusCode) {
                            for try await line in bytes.lines {
                                continuation.yield(line)
                            }
                            continuation.finish()
                            return
                        }

                        var errorBody = ""
                        for try await line in bytes.lines {
                            errorBody += line
                            if errorBody.count > 4_000 { break }
                        }
                        if retryableStatuses.contains(http.statusCode), attempt < maxAttempts {
                            let retryAfter = http.value(forHTTPHeaderField: "retry-after").flatMap(Double.init)
                            let delay = min(retryAfter ?? Double(attempt) * 1.5, 8)
                            try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                            continue
                        }
                        throw ChatProviderError.httpStatus(http.statusCode, errorBody)
                    }
                } catch is CancellationError {
                    continuation.finish(throwing: ChatProviderError.cancelled)
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }
}
