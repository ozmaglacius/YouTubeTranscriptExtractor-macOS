import SwiftUI
import AppKit

struct SettingsPanel: View {
    @EnvironmentObject var extractor: ExtractorService

    var body: some View {
        ScrollView(.vertical, showsIndicators: true) {
            VStack(alignment: .leading, spacing: 0) {

                // ── API Key ──────────────────────────────────────────────
                sectionHeader("YouTube Data API Key")
                SecureField("AIzaSy…", text: $extractor.apiKey)
                    .textFieldStyle(.roundedBorder)
                helpText("Required. Get a free key at console.cloud.google.com → YouTube Data API v3.")

                divider()

                // ── URL ──────────────────────────────────────────────────
                sectionHeader("Playlist / Video URL")
                TextField("https://youtube.com/playlist?list=PL…", text: $extractor.urlString)
                    .textFieldStyle(.roundedBorder)

                // ── Output dir ───────────────────────────────────────────
                sectionHeader("Output Directory")
                HStack(spacing: 6) {
                    TextField("", text: $extractor.outputDir)
                        .textFieldStyle(.roundedBorder)
                    Button("📁") { browseDir() }
                        .frame(width: 34)
                        .help("Choose output folder")
                }

                // ── Format ───────────────────────────────────────────────
                sectionHeader("Format")
                Picker("", selection: $extractor.format) {
                    ForEach(OutputFormat.allCases, id: \.self) { fmt in
                        Text(fmt.rawValue.uppercased()).tag(fmt)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                // ── Languages ────────────────────────────────────────────
                sectionHeader("Languages  (space-separated)")
                TextField("en", text: $extractor.languagesString)
                    .textFieldStyle(.roundedBorder)
                helpText("e.g. \"en es fr\" — tried in order, falls back to any available language.")

                // ── Limit ────────────────────────────────────────────────
                sectionHeader("Limit  (blank = all videos)")
                TextField("e.g. 10", text: $extractor.limitString)
                    .textFieldStyle(.roundedBorder)

                divider()

                // ── Toggles ──────────────────────────────────────────────
                Toggle("Include timestamps", isOn: $extractor.includeTimestamps)
                    .padding(.bottom, 6)
                Toggle("Write combined file", isOn: $extractor.combined)
                    .padding(.bottom, 18)

                // ── Start / Stop button ──────────────────────────────────
                Button(action: extractor.isRunning ? extractor.stop : extractor.start) {
                    HStack {
                        Spacer()
                        Text(extractor.isRunning ? "■  Stop" : "▶  Start")
                            .fontWeight(.semibold)
                            .padding(.vertical, 4)
                        Spacer()
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(extractor.isRunning ? .red : .accentColor)
                .controlSize(.large)

                Spacer(minLength: 0)
            }
            .padding(14)
        }
    }

    // MARK: Helpers

    @ViewBuilder
    private func sectionHeader(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .bold))
            .foregroundColor(.secondary)
            .padding(.top, 10)
            .padding(.bottom, 3)
    }

    @ViewBuilder
    private func helpText(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10))
            .foregroundColor(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, 2)
    }

    @ViewBuilder
    private func divider() -> some View {
        Divider().padding(.vertical, 12)
    }

    private func browseDir() {
        let panel = NSOpenPanel()
        panel.canChooseFiles        = false
        panel.canChooseDirectories  = true
        panel.canCreateDirectories  = true
        panel.prompt                = "Select"
        panel.message               = "Choose the output directory for transcripts"
        // Start at the current directory if it exists
        let current = URL(fileURLWithPath: extractor.outputDir)
        if FileManager.default.fileExists(atPath: current.path) {
            panel.directoryURL = current
        }
        if panel.runModal() == .OK, let url = panel.url {
            _ = url.startAccessingSecurityScopedResource()
            extractor.outputDir = url.path  // didSet saves the bookmark
        }
    }
}
