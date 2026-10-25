import Foundation

/// Minimal server-sent events line parser for OpenAI-style and Anthropic-style streams.
public enum SSEParser {
    public static func dataPayloads(from chunk: String) -> [String] {
        var payloads: [String] = []
        for rawLine in chunk.split(whereSeparator: \.isNewline) {
            let line = String(rawLine).trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("data:") else { continue }
            let value = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            if value == "[DONE]" { continue }
            if !value.isEmpty {
                payloads.append(value)
            }
        }
        return payloads
    }

    public static func openAIDeltaContent(from json: String) -> String? {
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = obj["choices"] as? [[String: Any]],
              let first = choices.first
        else { return nil }

        if let delta = first["delta"] as? [String: Any],
           let content = delta["content"] as? String {
            return content
        }
        if let message = first["message"] as? [String: Any],
           let content = message["content"] as? String {
            return content
        }
        return nil
    }

    public static func anthropicDeltaText(from json: String) -> String? {
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = obj["type"] as? String
        else { return nil }

        if type == "content_block_delta",
           let delta = obj["delta"] as? [String: Any],
           let text = delta["text"] as? String {
            return text
        }
        return nil
    }

    public static func ollamaMessageContent(from json: String) -> (content: String, done: Bool)? {
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        let done = (obj["done"] as? Bool) ?? false
        if let message = obj["message"] as? [String: Any],
           let content = message["content"] as? String {
            return (content, done)
        }
        if let response = obj["response"] as? String {
            return (response, done)
        }
        return ("", done)
    }
}
