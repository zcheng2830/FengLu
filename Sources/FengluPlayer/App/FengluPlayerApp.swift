import SwiftUI

@main
struct FengluPlayerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var store = PlaylistStore()
    @StateObject private var playback = PlaybackController()
    @StateObject private var lyricsWindow = LyricsWindowState()

    var body: some Scene {
        Window("Fenglu Player", id: "main") {
            ContentView(store: store, playback: playback)
                .onAppear {
                    appDelegate.configureOpenURLsHandler(openURLs)
                    appDelegate.configureAddToPlaylistHandler(addURLsToPlaylist)
                    appDelegate.configureWillTerminateHandler {
                        playback.stop()
                    }
                }
        }
        .defaultSize(width: 1080, height: 720)
        .commands {
            FileCommands(store: store, playback: playback)
            SidebarCommands()
            LyricsCommands(windowState: lyricsWindow)
        }

        Window("Lyrics", id: LyricsWindowState.windowID) {
            LyricsWindowView(store: store, playback: playback, playbackClock: playback.clock, windowState: lyricsWindow)
        }
        .defaultSize(width: 420, height: 560)
        .restorationBehavior(.disabled)
    }

    private func openURLs(_ urls: [URL]) {
        DebugLog.log("Application open file request received for \(urls.count) URL(s)")
        Task { @MainActor in
            let importedTracks = await store.importItems(urls)
            DebugLog.log("Application open file request imported \(importedTracks.count) track(s)")
            guard let firstTrack = importedTracks.first else {
                DebugLog.log("Application open file request produced no playable tracks")
                return
            }

            store.select(firstTrack)
            playback.beginTransition(to: firstTrack)
            await playback.play(track: firstTrack)
            if playback.currentTrackID == firstTrack.id {
                store.activate(firstTrack)
                store.updateDuration(for: firstTrack.id, duration: playback.duration)
            }
        }
    }

    private func addURLsToPlaylist(_ urls: [URL]) {
        DebugLog.log("Finder add-to-playlist request received for \(urls.count) URL(s)")
        Task { @MainActor in
            let importedTracks = await store.importItems(urls)
            DebugLog.log("Finder add-to-playlist request imported \(importedTracks.count) track(s)")
        }
    }
}
