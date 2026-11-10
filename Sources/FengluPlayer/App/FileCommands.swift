import SwiftUI

struct FileCommands: Commands {
    @ObservedObject var store: PlaylistStore
    @ObservedObject var playback: PlaybackController

    init(store: PlaylistStore, playback: PlaybackController) {
        self.store = store
        self.playback = playback
    }

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("Open...") {
                DebugLog.log("File > Open... command selected")
                openItems()
            }
            .keyboardShortcut("o", modifiers: [.command])

            Button("Save Playlist As...") {
                DebugLog.log("File > Save Playlist As... command selected")
                savePlaylist()
            }
            .keyboardShortcut("s", modifiers: [.command, .shift])

            Button("Clear All Tracks") {
                DebugLog.log("File > Clear All Tracks command selected")
                clearAllTracks()
            }
        }
    }

    private func openItems() {
        DebugLog.log("Presenting open panel from File menu")
        guard let urls = ImportOpenPanel.selectURLs() else {
            DebugLog.log("Open panel cancelled")
            return
        }

        DebugLog.log("Open panel returned \(urls.count) URL(s)")
        Task { @MainActor in
            let importedTracks = await store.importItems(urls)
            DebugLog.log("File menu import produced \(importedTracks.count) track(s)")
            guard let firstTrack = importedTracks.first else {
                DebugLog.log("No imported tracks to play")
                return
            }

            DebugLog.log("Starting playback from opened item: \(firstTrack.url.path)")
            store.select(firstTrack)
            playback.beginTransition(to: firstTrack)
            await playback.play(track: firstTrack)
            if playback.currentTrackID == firstTrack.id {
                store.activate(firstTrack)
            }
        }
    }

    private func savePlaylist() {
        Task { @MainActor in
            let tracks = store.tracks
            guard !tracks.isEmpty else {
                DebugLog.log("Save playlist skipped because there are no tracks")
                return
            }

            DebugLog.log("Presenting save panel for \(tracks.count) current track(s)")
            guard let url = PlaylistSavePanel.selectURL(defaultName: defaultPlaylistFileName(for: tracks)) else {
                DebugLog.log("Save playlist panel cancelled")
                return
            }

            do {
                let title = url.deletingPathExtension().lastPathComponent
                try XSPFExporter().write(tracks, to: url, title: title)
                DebugLog.log("File menu saved playlist to \(url.path)")
            } catch {
                DebugLog.log("Save playlist failed: \(error.localizedDescription)")
                store.presentAlert(
                    title: "Playlist Could Not Be Saved",
                    message: "\(url.lastPathComponent): \(error.localizedDescription)"
                )
            }
        }
    }

    private func clearAllTracks() {
        Task { @MainActor in
            playback.stop()
            store.clear()
        }
    }

    private func defaultPlaylistFileName(for tracks: [AudioTrack]) -> String {
        let baseName = tracks.first?.playlistName?.nonEmpty ?? "Fenglu Playlist"
        let sanitized = baseName
            .components(separatedBy: CharacterSet(charactersIn: "/:\\"))
            .joined(separator: "-")
            .nonEmpty ?? "Fenglu Playlist"
        return "\(sanitized).xspf"
    }
}
