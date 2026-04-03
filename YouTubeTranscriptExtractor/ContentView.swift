import SwiftUI

struct ContentView: View {
    @StateObject private var extractor = ExtractorService()

    var body: some View {
        VStack(spacing: 0) {

            // ── Header ─────────────────────────────────────────────────
            HStack {
                Text("🎬  YouTube Transcript Extractor")
                    .font(.system(size: 17, weight: .bold))
                    .padding(.leading, 16)
                Spacer()
            }
            .padding(.vertical, 12)

            Divider()

            // ── Main content: Settings | Log ───────────────────────────
            HStack(spacing: 0) {
                SettingsPanel()
                    .frame(minWidth: 280, maxWidth: 320)
                    .environmentObject(extractor)

                Divider()

                LogPanel()
                    .frame(maxWidth: .infinity)
                    .environmentObject(extractor)
            }

            Divider()

            // ── Progress bar ───────────────────────────────────────────
            HStack(spacing: 8) {
                ProgressView(value: extractor.progress, total: 100)
                    .padding(.leading, 14)
                Text(extractor.progressLabel)
                    .frame(width: 72, alignment: .trailing)
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                    .padding(.trailing, 14)
            }
            .padding(.vertical, 6)
        }
        .frame(minWidth: 900, minHeight: 560)
    }
}
