import Foundation

/// Keyless web access: DuckDuckGo search and plain-text page reading. Works with any model, including local ones.
public enum WebTools {
    public static func all(session: URLSession = .shared) -> [AgentTool] {
        [
            AgentTool(spec: .object(
                "search_web",
                "Search the web (DuckDuckGo). Returns titles, links, and snippets. Use read_webpage to read a result.",
                properties: ["query": ["type": "string"]],
                required: ["query"]
            )) { args in
                let query = try args.requiredString("query")
                let results = try await search(query, session: session)
                guard !results.isEmpty else { return .ok("No results for \"\(query)\".") }
                let text = results.prefix(8).enumerated().map { index, r in
                    "\(index + 1). \(r.title)\n   \(r.url)\n   \(r.snippet)"
                }.joined(separator: "\n")
                return .ok(text, summary: "Searched the web: \(query)")
            },

            AgentTool(spec: .object(
                "read_webpage",
                "Fetch a web page and return its readable text (no login; for signed-in pages, use the browser tools).",
                properties: ["url": ["type": "string"]],
                required: ["url"]
            )) { args in
                var raw = try args.requiredString("url")
                if !raw.contains("://") { raw = "https://" + raw }
                guard let url = URL(string: raw) else { throw ToolError("Invalid URL.") }
                let text = try await readable(url, session: session)
                return .ok(text.isEmpty ? "The page had no readable text." : text, summary: "Read \(url.host ?? raw)")
            }
        ]
    }

    public struct SearchResult: Sendable, Equatable {
        public var title: String
        public var url: String
        public var snippet: String
    }

    static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 14_0) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"

    public static func search(_ query: String, session: URLSession) async throws -> [SearchResult] {
        var components = URLComponents(string: "https://html.duckduckgo.com/html/")!
        components.queryItems = [URLQueryItem(name: "q", value: query)]
        var request = URLRequest(url: components.url!)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 15
        let (data, _) = try await session.data(for: request)
        return parseResults(String(decoding: data, as: UTF8.self))
    }

    /// Parses DuckDuckGo's HTML results page.
    public static func parseResults(_ html: String) -> [SearchResult] {
        let linkPattern = #"<a[^>]*class="result__a"[^>]*href="([^"]+)"[^>]*>([\s\S]*?)</a>"#
        let snippetPattern = #"<a[^>]*class="result__snippet"[^>]*>([\s\S]*?)</a>"#
        let links = matches(linkPattern, in: html)
        let snippets = matches(snippetPattern, in: html).map { $0[0] }
        return links.enumerated().compactMap { index, groups in
            let href = decodeEntities(groups[0])
            let title = plainText(groups[1])
            guard !title.isEmpty else { return nil }
            return SearchResult(
                title: title,
                url: resolveRedirect(href),
                snippet: index < snippets.count ? plainText(snippets[index]) : ""
            )
        }
    }

    /// DuckDuckGo wraps links as //duckduckgo.com/l/?uddg=<encoded target>.
    static func resolveRedirect(_ href: String) -> String {
        let full = href.hasPrefix("//") ? "https:" + href : href
        if let components = URLComponents(string: full),
           let target = components.queryItems?.first(where: { $0.name == "uddg" })?.value {
            return target
        }
        return full
    }

    public static func readable(_ url: URL, session: URLSession, limit: Int = 12_000) async throws -> String {
        var request = URLRequest(url: url)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 20
        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw ToolError("The page returned HTTP \(http.statusCode).")
        }
        var text = plainText(String(decoding: data, as: UTF8.self))
        if text.count > limit { text = String(text.prefix(limit)) + "\n…(truncated)" }
        return text
    }

    /// Strips scripts, styles, and tags; keeps paragraph breaks.
    public static func plainText(_ html: String) -> String {
        var s = html
        for pattern in [#"<script[\s\S]*?</script>"#, #"<style[\s\S]*?</style>"#, #"<noscript[\s\S]*?</noscript>"#,
                        #"<svg[\s\S]*?</svg>"#, #"<!--[\s\S]*?-->"#] {
            s = s.replacingOccurrences(of: pattern, with: " ", options: [.regularExpression, .caseInsensitive])
        }
        s = s.replacingOccurrences(of: #"<(br|/p|/div|/li|/h[1-6]|/tr)[^>]*>"#, with: "\n", options: [.regularExpression, .caseInsensitive])
        // Inline tags join words; any other tag is a word break.
        s = s.replacingOccurrences(of: #"</?(b|i|em|strong|span|a|code|small|sup|sub|mark|u)\b[^>]*>"#, with: "", options: [.regularExpression, .caseInsensitive])
        s = s.replacingOccurrences(of: #"<[^>]+>"#, with: " ", options: .regularExpression)
        s = decodeEntities(s)
        s = s.replacingOccurrences(of: #"[ \t\x{00A0}]+"#, with: " ", options: .regularExpression)
        s = s.replacingOccurrences(of: #"\s*\n\s*(\n\s*)+"#, with: "\n\n", options: .regularExpression)
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func decodeEntities(_ s: String) -> String {
        var out = s
        let map = ["&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&#39;": "'", "&#x27;": "'", "&nbsp;": " ", "&apos;": "'"]
        for (entity, char) in map { out = out.replacingOccurrences(of: entity, with: char) }
        // Numeric entities.
        if let regex = try? NSRegularExpression(pattern: #"&#(x?)([0-9a-fA-F]+);"#) {
            let ns = out as NSString
            var result = ""
            var last = 0
            for match in regex.matches(in: out, range: NSRange(location: 0, length: ns.length)) {
                result += ns.substring(with: NSRange(location: last, length: match.range.location - last))
                let hex = ns.substring(with: match.range(at: 1)) == "x"
                let digits = ns.substring(with: match.range(at: 2))
                if let code = UInt32(digits, radix: hex ? 16 : 10), let scalar = Unicode.Scalar(code) {
                    result.append(Character(scalar))
                }
                last = match.range.location + match.range.length
            }
            result += ns.substring(from: last)
            out = result
        }
        return out
    }

    private static func matches(_ pattern: String, in text: String) -> [[String]] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return [] }
        let ns = text as NSString
        return regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).map { match in
            (1..<match.numberOfRanges).map { i in
                let r = match.range(at: i)
                return r.location == NSNotFound ? "" : ns.substring(with: r)
            }
        }
    }
}
