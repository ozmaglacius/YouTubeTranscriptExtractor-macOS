import Foundation

enum VideoStatus {
    case ok, skipped, error
}

enum OutputFormat: String, CaseIterable {
    case txt  = "txt"
    case json = "json"
    case srt  = "srt"
}

struct VideoResult: Identifiable {
    let id = UUID()
    let index: Int
    let videoId: String
    let title: String
    let status: VideoStatus
    let message: String
    let outputPath: URL?

    init(
        index: Int,
        videoId: String,
        title: String,
        status: VideoStatus,
        message: String = "",
        outputPath: URL? = nil
    ) {
        self.index      = index
        self.videoId    = videoId
        self.title      = title
        self.status     = status
        self.message    = message
        self.outputPath = outputPath
    }
}
