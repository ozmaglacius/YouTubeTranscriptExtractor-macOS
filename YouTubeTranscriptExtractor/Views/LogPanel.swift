import SwiftUI

struct LogPanel: View {
    @EnvironmentObject var extractor: ExtractorService

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Log")
                .font(.system(size: 11, weight: .bold))
                .foregroundColor(.secondary)
                .padding(.horizontal, 10)
                .padding(.top, 10)
                .padding(.bottom, 4)

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(extractor.logMessages) { msg in
                            Text(msg.text)
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundColor(logColor(msg.level))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .id(msg.id)
                        }
                    }
                    .padding(10)
                }
                .background(Color(nsColor: .textBackgroundColor).opacity(0.6))
                .onChange(of: extractor.logMessages.count) { _ in
                    if let last = extractor.logMessages.last {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
        }
    }

    private func logColor(_ level: LogLevel) -> Color {
        switch level {
        case .ok:      return Color(red: 0.29, green: 0.85, blue: 0.50)   // green
        case .warning: return Color(red: 1.00, green: 0.84, blue: 0.04)   // amber
        case .error:   return Color(red: 1.00, green: 0.42, blue: 0.42)   // red
        case .summary: return Color(red: 0.39, green: 0.82, blue: 1.00)   // cyan
        case .info:    return .primary
        }
    }
}
