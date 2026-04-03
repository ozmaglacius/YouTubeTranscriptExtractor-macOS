import Foundation
import AppKit

// MARK: - Log types

enum LogLevel { case info, ok, warning, error, summary }

struct LogMessage: Identifiable {
    let id    = UUID()
    let text:  String
    let level: LogLevel
}

// MARK: - Internal settings bundle

private struct ExtractionSettings {
    let url:               String
    let outputDirURL:      URL
    let format:            OutputFormat
    let languages:         [String]
    let includeTimestamps: Bool
    let combined:          Bool
    let limit:             Int?
    let apiKey:            String
}

// MARK: - ExtractorService

@MainActor
final class ExtractorService: ObservableObject {

    // MARK: Settings (bound to UI)
    @Published var urlString:          String = ""
    @Published var outputDir:          String = "" {
        didSet { saveOutputDirBookmark() }
    }
    @Published var format:             OutputFormat = .txt
    @Published var languagesString:    String = "en"
    @Published var limitString:        String = ""
    @Published var includeTimestamps:  Bool = true
    @Published var combined:           Bool = false
    @Published var apiKey: String = "" {
        didSet { KeychainService.saveAPIKey(apiKey) }
    }

    private static let outputDirBookmarkKey = "outputDirBookmark"

    // MARK: State (observed by UI)
    @Published var logMessages:    [LogMessage] = []
    @Published var progress:       Double = 0
    @Published var progressLabel:  String = ""
    @Published var isRunning:      Bool = false
    @Published var summary:        ExtractionSummary? = nil

    private var extractionTask: Task<Void, Never>?

    // MARK: Init

    init() {
        // Restore output directory from security-scoped bookmark, or use ~/Downloads/Transcripts
        if let bookmark = UserDefaults.standard.data(forKey: Self.outputDirBookmarkKey) {
            var isStale = false
            if let url = try? URL(resolvingBookmarkData: bookmark,
                                  options: .withSecurityScope,
                                  relativeTo: nil,
                                  bookmarkDataIsStale: &isStale) {
                _ = url.startAccessingSecurityScopedResource()
                outputDir = url.path
            }
        }
        if outputDir.isEmpty {
            let downloads = FileManager.default
                .urls(for: .downloadsDirectory, in: .userDomainMask)
                .first ?? URL(fileURLWithPath: NSHomeDirectory() + "/Downloads")
            outputDir = downloads.appendingPathComponent("Transcripts").path
        }
        // Restore saved API key from Keychain
        if let saved = KeychainService.loadAPIKey() {
            apiKey = saved
        }
    }

    // MARK: Bookmark persistence

    func saveOutputDirBookmark() {
        let url = URL(fileURLWithPath: outputDir).standardized
        guard let bookmark = try? url.bookmarkData(
            options: .withSecurityScope,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        ) else { return }
        UserDefaults.standard.set(bookmark, forKey: Self.outputDirBookmarkKey)
    }

    // MARK: Control

    func start() {
        guard !isRunning else { return }

        let trimmedURL = urlString.trimmingCharacters(in: .whitespaces)
        guard !trimmedURL.isEmpty else {
            log("Please enter a YouTube playlist or video URL.", level: .error)
            return
        }
        guard !apiKey.trimmingCharacters(in: .whitespaces).isEmpty else {
            log("Please enter a YouTube Data API key.", level: .error)
            return
        }

        isRunning    = true
        logMessages  = []
        progress     = 0
        progressLabel = ""
        summary      = nil

        let settings = makeSettings()
        extractionTask = Task { [weak self] in
            await self?.runExtraction(settings: settings)
            self?.isRunning = false
        }
    }

    func stop() {
        extractionTask?.cancel()
        extractionTask = nil
        log("⛔  Extraction cancelled.", level: .warning)
        isRunning = false
    }

    // MARK: Extraction pipeline

    private func runExtraction(settings: ExtractionSettings) async {
        // Create output directory
        do {
            try FileManager.default.createDirectory(at: settings.outputDirURL, withIntermediateDirectories: true)
        } catch {
            log("❌  Could not create output directory: \(error.localizedDescription)", level: .error)
            return
        }

        // Resolve video list
        var videos: [VideoInfo] = []
        do {
            if let playlistId = YouTubeAPIService.parsePlaylistId(from: settings.url) {
                log("📋  Fetching playlist metadata…", level: .info)
                videos = try await YouTubeAPIService.fetchPlaylistVideos(
                    playlistId: playlistId, apiKey: settings.apiKey, limit: settings.limit)
                log("   Found \(videos.count) video(s) to process.\n", level: .info)

            } else if let videoId = YouTubeAPIService.parseVideoId(from: settings.url) {
                log("📋  Fetching video info…", level: .info)
                let info = try await YouTubeAPIService.fetchSingleVideoInfo(
                    videoId: videoId, apiKey: settings.apiKey)
                videos = [info]
                log("   Found 1 video to process.\n", level: .info)

            } else {
                log("❌  Could not parse a video or playlist ID from the URL.", level: .error)
                return
            }
        } catch {
            log("❌  Failed to fetch video list: \(error.localizedDescription)", level: .error)
            return
        }

        var s = ExtractionSummary(total: videos.count, outputDir: settings.outputDirURL)
        var combinedParts: [String] = []

        for (idx, video) in videos.enumerated() {
            if Task.isCancelled { break }

            let n      = idx + 1
            let prefix = String(format: "  [%03d/%03d]", n, videos.count)
            let fname  = buildFilename(index: n, title: video.title, fmt: settings.format)
            let outURL = settings.outputDirURL.appendingPathComponent(fname)

            do {
                let (entries, langCode) = try await TranscriptService.fetchTranscript(
                    videoId: video.id, languages: settings.languages)

                let content: String
                switch settings.format {
                case .txt:  content = formatTxt(entries: entries, title: video.title, timestamps: settings.includeTimestamps)
                case .json: content = formatJSON(entries: entries, title: video.title)
                case .srt:  content = formatSRT(entries: entries)
                }
                try content.write(to: outURL, atomically: true, encoding: .utf8)

                let langNote = settings.languages.contains(langCode) ? "" : " [\(langCode)]"
                log("\(prefix) ✅  \(video.title)\(langNote)", level: .ok)
                s.results.append(VideoResult(index: n, videoId: video.id, title: video.title, status: .ok, outputPath: outURL))
                s.succeeded += 1

                if settings.combined {
                    combinedParts.append(formatTxt(entries: entries, title: video.title, timestamps: settings.includeTimestamps))
                }

            } catch TranscriptError.transcriptsDisabled {
                log("\(prefix) ⚠️   \(video.title)  (transcripts disabled)", level: .warning)
                s.results.append(VideoResult(index: n, videoId: video.id, title: video.title, status: .skipped, message: "Transcripts disabled"))
                s.skipped += 1

            } catch TranscriptError.noTranscriptFound(let lang) {
                log("\(prefix) ⚠️   \(video.title)  (no transcript for: \(lang))", level: .warning)
                s.results.append(VideoResult(index: n, videoId: video.id, title: video.title, status: .skipped, message: "No transcript found"))
                s.skipped += 1

            } catch {
                log("\(prefix) ❌  \(video.title)  (\(error.localizedDescription))", level: .error)
                s.results.append(VideoResult(index: n, videoId: video.id, title: video.title, status: .error, message: error.localizedDescription))
                s.failed += 1
            }

            progress      = Double(n) / Double(videos.count) * 100
            progressLabel = "\(n) / \(videos.count)"
        }

        // Write combined file
        if settings.combined && !combinedParts.isEmpty {
            let sep      = "\n\n" + String(repeating: "=", count: 60) + "\n\n"
            let combined = combinedParts.joined(separator: sep)
            let combURL  = settings.outputDirURL.appendingPathComponent("combined_transcripts.txt")
            try? combined.write(to: combURL, atomically: true, encoding: .utf8)
            log("\n📄  Combined file written: \(combURL.path)", level: .info)
        }

        summary = s
        appendSummary(s)
    }

    // MARK: Formatters

    private func ts(_ seconds: Double) -> String {
        let t = Int(seconds)
        return String(format: "%02d:%02d:%02d", t / 3600, (t % 3600) / 60, t % 60)
    }

    private func srts(_ seconds: Double) -> String {
        let ms = Int((seconds.truncatingRemainder(dividingBy: 1)) * 1000)
        let t  = Int(seconds)
        return String(format: "%02d:%02d:%02d,%03d", t / 3600, (t % 3600) / 60, t % 60, ms)
    }

    private func formatTxt(entries: [TranscriptEntry], title: String, timestamps: Bool) -> String {
        var lines = ["# \(title)", ""]
        for e in entries {
            let text = e.text.trimmingCharacters(in: .whitespaces)
            lines.append(timestamps ? "[\(ts(e.start))] \(text)" : text)
        }
        return lines.joined(separator: "\n")
    }

    private func formatJSON(entries: [TranscriptEntry], title: String) -> String {
        let arr = entries.map { e -> [String: Any] in
            ["start": (e.start * 1000).rounded() / 1000,
             "duration": (e.duration * 1000).rounded() / 1000,
             "text": e.text]
        }
        let obj: [String: Any] = ["title": title, "transcript": arr]
        guard let data = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .withoutEscapingSlashes]),
              let str  = String(data: data, encoding: .utf8) else { return "{}" }
        return str
    }

    private func formatSRT(entries: [TranscriptEntry]) -> String {
        var lines: [String] = []
        for (i, e) in entries.enumerated() {
            lines += ["\(i + 1)", "\(srts(e.start)) --> \(srts(e.start + e.duration))",
                      e.text.trimmingCharacters(in: .whitespaces), ""]
        }
        return lines.joined(separator: "\n")
    }

    private func buildFilename(index: Int, title: String, fmt: OutputFormat) -> String {
        var safe = title
        let bad  = CharacterSet(charactersIn: #"\/:*?"<>|"#)
        safe = safe.components(separatedBy: bad).joined(separator: "_")
        // Collapse runs of whitespace/underscores
        while safe.contains("  ") || safe.contains("__") {
            safe = safe.replacingOccurrences(of: "  ", with: " ")
            safe = safe.replacingOccurrences(of: "__", with: "_")
        }
        safe = safe.replacingOccurrences(of: " ", with: "_")
        safe = String(safe.prefix(120)).trimmingCharacters(in: CharacterSet(charactersIn: "_. "))
        return String(format: "%03d_%@.%@", index, safe, fmt.rawValue)
    }

    // MARK: Logging

    func log(_ text: String, level: LogLevel = .info) {
        logMessages.append(LogMessage(text: text, level: level))
    }

    private func appendSummary(_ s: ExtractionSummary) {
        let sep = String(repeating: "─", count: 44)
        var lines: [String] = [
            "\n\(sep)", "  SUMMARY", sep,
            "  Total    : \(s.total)",
            "  ✅ OK    : \(s.succeeded)",
            "  ⚠️  Skip  : \(s.skipped)",
            "  ❌ Error : \(s.failed)",
            "  Output   : \(s.outputDir.path)",
            sep,
        ]
        for r in s.results where r.status != .ok {
            let icon = r.status == .skipped ? "⚠️ " : "❌"
            lines.append("    \(icon) [\(String(format: "%03d", r.index))] \(r.title)")
            if !r.message.isEmpty { lines.append("         → \(r.message)") }
        }
        log(lines.joined(separator: "\n"), level: .summary)
    }

    // MARK: Settings builder

    private func makeSettings() -> ExtractionSettings {
        let langs = languagesString
            .components(separatedBy: CharacterSet.whitespaces.union(CharacterSet(charactersIn: ",")))
            .filter { !$0.isEmpty }
        let lim = Int(limitString.trimmingCharacters(in: .whitespaces))
        let raw = outputDir.trimmingCharacters(in: .whitespaces)
        let dir = raw.isEmpty
            ? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!.appendingPathComponent("Transcripts")
            : URL(fileURLWithPath: raw).standardized
        return ExtractionSettings(
            url:               urlString.trimmingCharacters(in: .whitespaces),
            outputDirURL:      dir,
            format:            format,
            languages:         langs.isEmpty ? ["en"] : langs,
            includeTimestamps: includeTimestamps,
            combined:          combined,
            limit:             lim,
            apiKey:            apiKey.trimmingCharacters(in: .whitespaces)
        )
    }
}
