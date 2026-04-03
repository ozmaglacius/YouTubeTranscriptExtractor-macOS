import Foundation

// MARK: - Errors

enum TranscriptError: LocalizedError {
    case transcriptsDisabled
    case noTranscriptFound(String)
    case fetchFailed(String)

    var errorDescription: String? {
        switch self {
        case .transcriptsDisabled:      return "Transcripts are disabled for this video"
        case .noTranscriptFound(let l): return "No transcript found for languages: \(l)"
        case .fetchFailed(let r):       return "Fetch failed: \(r)"
        }
    }
}

// MARK: - Domain types

struct TranscriptEntry {
    let text: String
    let start: Double
    let duration: Double
}

private struct CaptionTrack {
    let languageCode: String
    let language: String
    let baseUrl: String
    let isGenerated: Bool
}

// MARK: - Service

enum TranscriptService {

    static func fetchTranscript(
        videoId: String,
        languages: [String]
    ) async throws -> ([TranscriptEntry], String) {
        // Fresh session per video — avoids stale cookies from previous extractions
        // interfering with YouTube's session validation.
        let session = makeSession()

        // Step 1: Load the watch page.
        // This is exactly what the Python youtube-transcript-api does first.
        // The session captures the cookies YouTube sets (YSC, VISITOR_INFO1_LIVE).
        let html = try await fetchWatchPage(videoId: videoId, session: session)

        // Step 2: Extract the INNERTUBE_API_KEY embedded in the page HTML.
        // Every YouTube page includes this key — it's not the same as the Data API key.
        guard let innertubeKey = extractInnertubeKey(from: html) else {
            // Key not found usually means the page was bot-detected.
            // Fall back to parsing ytInitialPlayerResponse from whatever HTML we got.
            if let tracks = extractTracksFromHTML(html), !tracks.isEmpty,
               let result = try? await fetchTranscriptXML(tracks: tracks, languages: languages, session: session) {
                return result
            }
            throw TranscriptError.fetchFailed("Could not extract InnerTube key — YouTube may be rate-limiting this IP")
        }

        // Step 3: POST to /youtubei/v1/player with the ANDROID client.
        // This is the exact approach the Python library uses. The ANDROID client
        // combined with the API key from the page is the most reliable combination.
        // The session carries the cookies from Step 1 automatically.
        let playerData = try await fetchPlayerData(
            videoId: videoId, apiKey: innertubeKey, session: session
        )

        // Step 4: Extract caption tracks from the player response.
        if let tracks = try? extractCaptionTracks(from: playerData), !tracks.isEmpty,
           let result = try? await fetchTranscriptXML(tracks: tracks, languages: languages, session: session) {
            return result
        }

        // Step 5: If the InnerTube call returned no tracks, try ytInitialPlayerResponse
        // from the page HTML as a last resort.
        if let tracks = extractTracksFromHTML(html), !tracks.isEmpty,
           let result = try? await fetchTranscriptXML(tracks: tracks, languages: languages, session: session) {
            return result
        }

        throw TranscriptError.transcriptsDisabled
    }

    // MARK: - Session

    private static func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral  // ephemeral = no disk cache, but still has in-memory cookie jar
        config.httpCookieAcceptPolicy = .always
        config.httpShouldSetCookies   = true
        config.httpAdditionalHeaders  = browserHeaders()
        return URLSession(configuration: config)
    }

    private static func browserHeaders() -> [String: String] {
        [
            "User-Agent":      "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36",
            "Accept-Language": "en-US,en;q=0.9",
            "Accept":          "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
        ]
    }

    // MARK: - Step 1: Fetch watch page

    private static func fetchWatchPage(videoId: String, session: URLSession) async throws -> String {
        guard let url = URL(string: "https://www.youtube.com/watch?v=\(videoId)") else {
            throw TranscriptError.fetchFailed("Invalid video ID")
        }
        var req = URLRequest(url: url)
        // Accept-Language tells YouTube which language to serve the page in.
        // The CONSENT cookie skips the GDPR cookie-wall in EU regions.
        req.setValue("en-US,en;q=0.9",         forHTTPHeaderField: "Accept-Language")
        req.setValue("CONSENT=YES+cb; SOCS=CAE", forHTTPHeaderField: "Cookie")

        let (data, resp) = try await session.data(for: req)
        if let http = resp as? HTTPURLResponse, http.statusCode != 200 {
            throw TranscriptError.fetchFailed("Watch page HTTP \(http.statusCode)")
        }
        let raw = String(data: data, encoding: .utf8) ?? ""
        // Unescape HTML entities that appear in the embedded JSON
        return raw
            .replacingOccurrences(of: "&amp;",  with: "&")
            .replacingOccurrences(of: "&#39;",  with: "'")
            .replacingOccurrences(of: "&quot;", with: "\"")
    }

    // MARK: - Step 2: Extract INNERTUBE_API_KEY

    private static func extractInnertubeKey(from html: String) -> String? {
        // YouTube embeds this as: "INNERTUBE_API_KEY":"AIzaSy..."
        // This key is NOT the YouTube Data API key — it's a public key for internal YouTube APIs.
        let pattern = #""INNERTUBE_API_KEY"\s*:\s*"([A-Za-z0-9_\-]+)""#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
              let range = Range(match.range(at: 1), in: html) else { return nil }
        return String(html[range])
    }

    // MARK: - Step 3: InnerTube /player call (ANDROID client, mirrors Python library)

    private static func fetchPlayerData(
        videoId: String,
        apiKey: String,
        session: URLSession
    ) async throws -> [String: Any] {
        // Exact URL format from the Python youtube-transcript-api:
        // https://www.youtube.com/youtubei/v1/player?key={api_key}
        guard let url = URL(string: "https://www.youtube.com/youtubei/v1/player?key=\(apiKey)") else {
            throw TranscriptError.fetchFailed("Invalid InnerTube URL")
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json",        forHTTPHeaderField: "Content-Type")
        req.setValue("https://www.youtube.com", forHTTPHeaderField: "Origin")
        req.setValue("https://www.youtube.com/watch?v=\(videoId)", forHTTPHeaderField: "Referer")

        // ANDROID client context — exactly what the Python library sends.
        // This client is less likely to require bot tokens than WEB.
        let body: [String: Any] = [
            "context": [
                "client": [
                    "clientName":    "ANDROID",
                    "clientVersion": "20.10.38",
                    "androidSdkVersion": 30,
                    "userAgent":     "com.google.android.youtube/20.10.38 (Linux; U; Android 11) gzip",
                    "hl":            "en",
                    "gl":            "US",
                ]
            ],
            "videoId": videoId,
            "params":  "8AEB",   // tells YouTube to include caption tracks in the response
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, resp) = try await session.data(for: req)
        if let http = resp as? HTTPURLResponse, http.statusCode != 200 {
            throw TranscriptError.fetchFailed("InnerTube HTTP \(http.statusCode)")
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw TranscriptError.fetchFailed("InnerTube response not JSON")
        }
        return json
    }

    // MARK: - Extract caption tracks from player JSON

    private static func extractCaptionTracks(from player: [String: Any]) throws -> [CaptionTrack] {
        if let ps     = player["playabilityStatus"] as? [String: Any],
           let status = ps["status"] as? String,
           status != "OK" {
            throw TranscriptError.transcriptsDisabled
        }
        guard let captions  = player["captions"]  as? [String: Any],
              let renderer  = captions["playerCaptionsTracklistRenderer"] as? [String: Any],
              let rawTracks = renderer["captionTracks"] as? [[String: Any]] else {
            throw TranscriptError.transcriptsDisabled
        }
        return rawTracks.compactMap { raw -> CaptionTrack? in
            guard let langCode = raw["languageCode"] as? String,
                  let baseUrl  = raw["baseUrl"]      as? String else { return nil }
            let name: String
            if let nameObj = raw["name"] as? [String: Any],
               let runs    = nameObj["runs"] as? [[String: Any]],
               let text    = runs.first?["text"] as? String { name = text }
            else { name = langCode }
            return CaptionTrack(languageCode: langCode, language: name, baseUrl: baseUrl,
                                isGenerated: (raw["kind"] as? String) == "asr")
        }
    }

    // MARK: - Extract tracks from ytInitialPlayerResponse in page HTML

    private static func extractTracksFromHTML(_ html: String) -> [CaptionTrack]? {
        guard let startRange = html.range(of: "ytInitialPlayerResponse = ") else { return nil }
        let tail = html[startRange.upperBound...]
        var depth = 0
        var end   = tail.startIndex
        for (i, ch) in tail.enumerated() {
            if      ch == "{" { depth += 1 }
            else if ch == "}" { depth -= 1; if depth == 0 { end = tail.index(tail.startIndex, offsetBy: i + 1); break } }
        }
        guard end > tail.startIndex else { return nil }
        guard let data   = String(tail[..<end]).data(using: .utf8),
              let player = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return try? extractCaptionTracks(from: player)
    }

    // MARK: - Pick best track and fetch transcript XML

    private static func fetchTranscriptXML(
        tracks: [CaptionTrack],
        languages: [String],
        session: URLSession
    ) async throws -> ([TranscriptEntry], String)? {
        let (track, langCode) = try findBestTrack(tracks, languages: languages)

        // Build a clean timedtext URL: remove format overrides and request plain XML
        var url = track.baseUrl
        for p in ["&fmt=srv3", "&fmt=srv2", "&fmt=srv1", "&fmt=json3", "&exp=xpe"] {
            url = url.replacingOccurrences(of: p, with: "")
        }
        if !url.contains("&fmt=") { url += "&fmt=xml" }

        guard let body = try? await fetchText(from: url, session: session), !body.isEmpty else { return nil }

        let entries: [TranscriptEntry] = body.hasPrefix("{") || body.hasPrefix("[")
            ? parseJSON3(body)
            : ((try? parseXML(body)) ?? [])

        guard !entries.isEmpty else { return nil }
        return (entries, langCode)
    }

    // MARK: - Language selection

    private static func findBestTrack(_ tracks: [CaptionTrack], languages: [String]) throws -> (CaptionTrack, String) {
        for lang in languages { if let t = tracks.first(where: { $0.languageCode == lang && !$0.isGenerated }) { return (t, lang) } }
        for lang in languages { if let t = tracks.first(where: { $0.languageCode == lang }) { return (t, lang) } }
        if let t = tracks.first(where: { $0.isGenerated }) { return (t, t.languageCode) }
        if let t = tracks.first { return (t, t.languageCode) }
        throw TranscriptError.noTranscriptFound(languages.joined(separator: ", "))
    }

    // MARK: - Fetch helpers

    private static func fetchText(from urlString: String, session: URLSession) async throws -> String {
        guard let url = URL(string: urlString) else { return "" }
        let (data, _) = try await session.data(from: url)
        return String(data: data, encoding: .utf8) ?? ""
    }

    // MARK: - XML parser

    private static func parseXML(_ xml: String) throws -> [TranscriptEntry] {
        guard let data = xml.data(using: .utf8) else { return [] }
        let delegate = XMLTranscriptParser()
        let parser   = XMLParser(data: data)
        parser.delegate = delegate
        parser.parse()
        return delegate.entries
    }

    // MARK: - JSON3 parser
    // Format: {"events":[{"tStartMs":0,"dDurationMs":5000,"segs":[{"utf8":"text"}]}]}

    private static func parseJSON3(_ json: String) -> [TranscriptEntry] {
        guard let data   = json.data(using: .utf8),
              let root   = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let events = root["events"] as? [[String: Any]] else { return [] }
        return events.compactMap { ev -> TranscriptEntry? in
            guard let startMs = ev["tStartMs"] as? Double,
                  let segs    = ev["segs"]     as? [[String: Any]] else { return nil }
            let text = segs.compactMap { $0["utf8"] as? String }.joined().trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            return TranscriptEntry(text: text, start: startMs / 1000, duration: (ev["dDurationMs"] as? Double ?? 0) / 1000)
        }
    }
}

// MARK: - SAX XML parser

private final class XMLTranscriptParser: NSObject, XMLParserDelegate {
    var entries: [TranscriptEntry] = []
    private var inText = false, currentText = "", currentStart = 0.0, currentDur = 0.0

    func parser(_ parser: XMLParser, didStartElement el: String, namespaceURI _: String?,
                qualifiedName _: String?, attributes attrs: [String: String] = [:]) {
        guard el == "text" else { return }
        inText = true; currentText = ""
        currentStart = Double(attrs["start"] ?? "0") ?? 0
        currentDur   = Double(attrs["dur"]   ?? "0") ?? 0
    }
    func parser(_ parser: XMLParser, foundCharacters s: String) { if inText { currentText += s } }
    func parser(_ parser: XMLParser, didEndElement el: String, namespaceURI _: String?, qualifiedName _: String?) {
        guard el == "text", inText else { return }
        inText = false
        let t = currentText
            .replacingOccurrences(of: "&#39;",  with: "'")
            .replacingOccurrences(of: "&amp;",  with: "&")
            .replacingOccurrences(of: "&lt;",   with: "<")
            .replacingOccurrences(of: "&gt;",   with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !t.isEmpty { entries.append(TranscriptEntry(text: t, start: currentStart, duration: currentDur)) }
    }
}
