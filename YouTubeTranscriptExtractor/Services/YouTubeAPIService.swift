import Foundation

// MARK: - Errors

enum YouTubeAPIError: LocalizedError {
    case invalidURL
    case invalidResponse
    case apiError(String)
    case noVideosFound

    var errorDescription: String? {
        switch self {
        case .invalidURL:           return "Invalid URL"
        case .invalidResponse:      return "Invalid API response"
        case .apiError(let msg):    return msg
        case .noVideosFound:        return "No videos found"
        }
    }
}

// MARK: - Model

struct VideoInfo {
    let id: String
    let title: String
}

// MARK: - Service

enum YouTubeAPIService {

    // MARK: URL parsing

    static func parseVideoId(from urlString: String) -> String? {
        guard let url = URL(string: urlString) else { return nil }
        // youtu.be short links
        if url.host == "youtu.be" {
            let path = url.pathComponents.filter { $0 != "/" }
            return path.first
        }
        // youtube.com/watch?v=
        if let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
           let v = components.queryItems?.first(where: { $0.name == "v" })?.value {
            return v
        }
        return nil
    }

    static func parsePlaylistId(from urlString: String) -> String? {
        guard let url = URL(string: urlString),
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return nil
        }
        return components.queryItems?.first(where: { $0.name == "list" })?.value
    }

    // MARK: Playlist fetch

    static func fetchPlaylistVideos(
        playlistId: String,
        apiKey: String,
        limit: Int?
    ) async throws -> [VideoInfo] {
        var videos: [VideoInfo] = []
        var pageToken: String? = nil

        repeat {
            var comps = URLComponents(string: "https://www.googleapis.com/youtube/v3/playlistItems")!
            var items: [URLQueryItem] = [
                URLQueryItem(name: "part",       value: "snippet"),
                URLQueryItem(name: "playlistId", value: playlistId),
                URLQueryItem(name: "maxResults", value: "50"),
                URLQueryItem(name: "key",        value: apiKey),
            ]
            if let token = pageToken {
                items.append(URLQueryItem(name: "pageToken", value: token))
            }
            comps.queryItems = items
            guard let url = comps.url else { throw YouTubeAPIError.invalidURL }

            let (data, response) = try await URLSession.shared.data(from: url)

            if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let error = json["error"] as? [String: Any],
                   let message = error["message"] as? String {
                    throw YouTubeAPIError.apiError(message)
                }
                throw YouTubeAPIError.invalidResponse
            }

            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw YouTubeAPIError.invalidResponse
            }

            let entries = json["items"] as? [[String: Any]] ?? []
            for entry in entries {
                guard let snippet    = entry["snippet"] as? [String: Any],
                      let resourceId = snippet["resourceId"] as? [String: Any],
                      let videoId    = resourceId["videoId"] as? String else { continue }
                let title = snippet["title"] as? String ?? videoId
                guard title != "Deleted video", title != "Private video" else { continue }
                videos.append(VideoInfo(id: videoId, title: title))
                if let lim = limit, videos.count >= lim { break }
            }

            pageToken = json["nextPageToken"] as? String

            if let lim = limit, videos.count >= lim {
                videos = Array(videos.prefix(lim))
                break
            }
        } while pageToken != nil

        return videos
    }

    // MARK: Single video fetch

    static func fetchSingleVideoInfo(videoId: String, apiKey: String) async throws -> VideoInfo {
        var comps = URLComponents(string: "https://www.googleapis.com/youtube/v3/videos")!
        comps.queryItems = [
            URLQueryItem(name: "part", value: "snippet"),
            URLQueryItem(name: "id",   value: videoId),
            URLQueryItem(name: "key",  value: apiKey),
        ]
        guard let url = comps.url else { throw YouTubeAPIError.invalidURL }

        let (data, response) = try await URLSession.shared.data(from: url)

        // Surface API-level errors (invalid key, quota exceeded, etc.) directly
        // rather than collapsing them into noVideosFound.
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            let json    = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])
            let message = (json?["error"] as? [String: Any])?["message"] as? String
                          ?? "HTTP \(http.statusCode)"
            throw YouTubeAPIError.apiError(message)
        }

        guard let json    = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let entries = json["items"] as? [[String: Any]],
              let first   = entries.first,
              let snippet = first["snippet"] as? [String: Any] else {
            throw YouTubeAPIError.noVideosFound
        }
        let title = snippet["title"] as? String ?? videoId
        return VideoInfo(id: videoId, title: title)
    }
}
