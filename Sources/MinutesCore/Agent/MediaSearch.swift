import Foundation

/// Finds a YouTube video for a search, without an API key, so "play some lofi" plays instead of opening a search page.
public enum MediaSearch {
    public struct Video: Sendable, Equatable {
        public var id: String
        public var title: String?
        public var watchURL: URL { URL(string: "https://www.youtube.com/watch?v=\(id)")! }
    }

    private static let videoID = try! NSRegularExpression(pattern: #""videoRenderer":\{"videoId":"([A-Za-z0-9_-]{11})""#)
    private static let anyVideoID = try! NSRegularExpression(pattern: #""videoId":"([A-Za-z0-9_-]{11})""#)

    /// Video ids in result order, from a YouTube search results page (ads and shorts shelves skipped where possible).
    public static func videoIDs(inResultsPage html: String) -> [String] {
        var ids = matches(videoID, in: html)
        if ids.isEmpty { ids = matches(anyVideoID, in: html) }
        var seen = Set<String>()
        return ids.filter { seen.insert($0).inserted }
    }

    public static func searchURL(_ query: String) -> URL {
        var components = URLComponents(string: "https://www.youtube.com/results")!
        components.queryItems = [URLQueryItem(name: "search_query", value: query)]
        return components.url!
    }

    public static func findVideo(_ query: String, session: URLSession = .shared) async throws -> Video? {
        var request = URLRequest(url: searchURL(query), timeoutInterval: 12)
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 14_0) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0 Safari/537.36",
                         forHTTPHeaderField: "User-Agent")
        request.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")
        let (data, _) = try await session.data(for: request)
        guard let id = videoIDs(inResultsPage: String(decoding: data, as: UTF8.self)).first else { return nil }
        return Video(id: id, title: await title(of: id, session: session))
    }

    private static func title(of id: String, session: URLSession) async -> String? {
        guard let url = URL(string: "https://www.youtube.com/oembed?format=json&url=https://www.youtube.com/watch?v=\(id)"),
              let (data, _) = try? await session.data(from: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return object["title"] as? String
    }

    private static func matches(_ regex: NSRegularExpression, in text: String) -> [String] {
        regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { match in
            Range(match.range(at: 1), in: text).map { String(text[$0]) }
        }
    }
}
