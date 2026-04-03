import SwiftUI

@main
struct YouTubeTranscriptExtractorApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified(showsTitle: true))
        .commands {
            CommandGroup(replacing: .newItem) { }   // hide File > New Window
        }
    }
}
