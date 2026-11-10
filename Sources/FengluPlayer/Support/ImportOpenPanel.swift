import AppKit

enum ImportOpenPanel {
    @MainActor
    static func selectURLs() -> [URL]? {
        let panel = NSOpenPanel()
        panel.title = "Open Audio or Playlist"
        panel.prompt = "Open"
        panel.allowedContentTypes = SupportedFileTypes.importableTypes
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.resolvesAliases = true

        DebugLog.log("NSOpenPanel configured for content types: \(SupportedFileTypes.importableTypes.map(\.identifier).sorted().joined(separator: ", "))")
        guard panel.runModal() == .OK else {
            return nil
        }

        for url in panel.urls {
            DebugLog.log("NSOpenPanel selected: \(url.path)")
        }
        return panel.urls
    }
}
