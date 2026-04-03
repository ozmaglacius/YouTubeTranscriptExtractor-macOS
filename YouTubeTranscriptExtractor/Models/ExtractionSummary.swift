import Foundation

struct ExtractionSummary {
    var total: Int = 0
    var succeeded: Int = 0
    var skipped: Int = 0
    var failed: Int = 0
    var outputDir: URL = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Documents/Transcripts")
    var results: [VideoResult] = []
}
