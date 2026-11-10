import AppKit
import UniformTypeIdentifiers

enum PlaylistSavePanel {
    @MainActor
    static func selectURL(defaultName: String) -> URL? {
        let panel = NSSavePanel()
        panel.title = "Save Playlist"
        panel.prompt = "Save"
        panel.nameFieldStringValue = defaultName
        panel.allowedContentTypes = [UTType(filenameExtension: "xspf") ?? .xml]
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false

        DebugLog.log("NSSavePanel configured for XSPF playlist export")
        guard panel.runModal() == .OK, var url = panel.url else {
            return nil
        }

        if url.pathExtension.localizedLowercase != "xspf" {
            url.deletePathExtension()
            url.appendPathExtension("xspf")
        }

        DebugLog.log("NSSavePanel selected: \(url.path)")
        return url
    }
}
