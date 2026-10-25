import Foundation
import MinutesCore

/// Minimal ElevenLabs text-to-speech client.
enum ElevenLabsClient {
    struct Voice: Identifiable, Hashable, Sendable {
        var id: String
        var name: String
        var detail: String
        var score: Int
    }

    static let models = [
        ("eleven_flash_v2_5", "Flash v2.5 — fastest (recommended)"),
        ("eleven_turbo_v2_5", "Turbo v2.5 — fast"),
        ("eleven_multilingual_v2", "Multilingual v2 — most natural, slower to start"),
        ("eleven_v3", "v3 — most expressive (if your plan has it), slowest")
    ]

    private static let base = URL(string: "https://api.elevenlabs.io/v1")!

    /// The account's voices, best Miss Minute candidates first.
    static func voices(apiKey: String) async throws -> [Voice] {
        var request = URLRequest(url: base.appendingPathComponent("voices"))
        request.setValue(apiKey, forHTTPHeaderField: "xi-api-key")
        request.timeoutInterval = 20
        let (data, response) = try await URLSession.shared.data(for: request)
        try check(response, data)
        guard let json = JSONValue.parse(String(decoding: data, as: UTF8.self)),
              let list = json["voices"]?.arrayValue else {
            throw ChatProviderError.decodingFailed("ElevenLabs voices")
        }
        return list.compactMap { item -> Voice? in
            guard let id = item["voice_id"]?.stringValue, let name = item["name"]?.stringValue else { return nil }
            let labels = item["labels"]?.objectValue ?? [:]
            let labelText = labels.values.compactMap(\.stringValue).joined(separator: ", ")
            let description = item["description"]?.stringValue ?? ""
            return Voice(id: id, name: name, detail: labelText, score: score(labels: labels, description: description, name: name))
        }
        .sorted { $0.score != $1.score ? $0.score > $1.score : $0.name < $1.name }
    }

    /// How well a voice fits a bright, warm, Southern cartoon hostess.
    static func score(labels: [String: JSONValue], description: String, name: String) -> Int {
        let all = (labels.values.compactMap(\.stringValue) + [description, name]).joined(separator: " ").lowercased()
        var score = 0
        if all.contains("southern") { score += 6 }
        if all.contains("female") || all.contains("woman") { score += 3 }
        if all.contains("american") { score += 2 }
        for word in ["warm", "friendly", "cheerful", "bubbly", "upbeat", "expressive", "animated", "playful"] where all.contains(word) {
            score += 1
        }
        if all.contains("young") || all.contains("middle") { score += 1 }
        if all.contains("male") && !all.contains("female") { score -= 4 }
        return score
    }

    static func synthesize(
        text: String,
        voiceID: String,
        model: String,
        apiKey: String,
        previousText: String?,
        nextText: String?
    ) async throws -> Data {
        // The streaming endpoint starts generating sooner; latency optimization trades a little polish for speed.
        var components = URLComponents(url: base.appendingPathComponent("text-to-speech/\(voiceID)/stream"), resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "output_format", value: "mp3_44100_128"),
            URLQueryItem(name: "optimize_streaming_latency", value: "3")
        ]
        var request = URLRequest(url: components.url!)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue(apiKey, forHTTPHeaderField: "xi-api-key")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("audio/mpeg", forHTTPHeaderField: "Accept")
        var body: [String: Any] = [
            "text": text,
            "model_id": model,
            "voice_settings": [
                // Lower stability = more emotional range; style adds personality.
                "stability": 0.38,
                "similarity_boost": 0.8,
                "style": 0.45,
                "use_speaker_boost": true
            ]
        ]
        // Neighbouring sentences keep intonation continuous across chunks.
        if let previousText { body["previous_text"] = previousText }
        if let nextText { body["next_text"] = nextText }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: request)
        try check(response, data)
        return data
    }

    private static func check(_ response: URLResponse, _ data: Data) throws {
        guard let http = response as? HTTPURLResponse else { throw ChatProviderError.underlying("Invalid response") }
        guard (200...299).contains(http.statusCode) else {
            var message = String(decoding: data.prefix(500), as: UTF8.self)
            if let json = JSONValue.parse(message), let detail = json["detail"]?["message"]?.stringValue ?? json["detail"]?.stringValue {
                message = detail
            }
            throw ChatProviderError.underlying("ElevenLabs \(http.statusCode): \(message)")
        }
    }
}
