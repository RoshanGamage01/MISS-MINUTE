import Foundation
import MinutesCore

/// Runs a streaming TTS request and yields the response body in small chunks as it arrives.
enum PCMHTTPStream {
    /// ~40 ms of 24 kHz 16-bit audio per chunk.
    static let chunkSize = 2_048
    /// The first chunk goes out at ~25 ms so playback can start on the earliest bytes (the player starts on
    /// 25 ms too; with one 2 KB size for both, the player used to sit on the first chunk until a second arrived).
    static let firstChunkSize = 1_200

    /// `makeRequest` runs inside the producer task (it may need to look things up first). The stream starts
    /// downloading immediately and buffers until it's played; cancel the returned task to abort it.
    static func open(
        _ makeRequest: @escaping @Sendable () async throws -> URLRequest,
        errorPrefix: @escaping @Sendable (Int) -> String
    ) -> (AsyncThrowingStream<Data, Error>, Task<Void, Never>) {
        var continuation: AsyncThrowingStream<Data, Error>.Continuation!
        let stream = AsyncThrowingStream<Data, Error> { continuation = $0 }
        let output = continuation!
        let task = Task {
            do {
                let request = try await makeRequest()
                let (bytes, response) = try await URLSession.shared.bytes(for: request)
                guard let http = response as? HTTPURLResponse else {
                    throw ChatProviderError.underlying("Invalid response")
                }
                guard (200...299).contains(http.statusCode) else {
                    var body = Data()
                    for try await byte in bytes {
                        body.append(byte)
                        if body.count > 500 { break }
                    }
                    var message = String(decoding: body, as: UTF8.self)
                    if let json = JSONValue.parse(message),
                       let detail = json["detail"]?["message"]?.stringValue ?? json["detail"]?.stringValue
                           ?? json["error"]?["message"]?.stringValue {
                        message = detail
                    }
                    throw ChatProviderError.underlying("\(errorPrefix(http.statusCode)): \(message)")
                }
                var chunk = Data()
                chunk.reserveCapacity(chunkSize)
                var limit = firstChunkSize
                for try await byte in bytes {
                    chunk.append(byte)
                    if chunk.count >= limit {
                        output.yield(chunk)
                        chunk.removeAll(keepingCapacity: true)
                        limit = chunkSize
                    }
                }
                if !chunk.isEmpty { output.yield(chunk) }
                output.finish()
            } catch {
                output.finish(throwing: error)
            }
        }
        output.onTermination = { _ in task.cancel() }
        return (stream, task)
    }
}
