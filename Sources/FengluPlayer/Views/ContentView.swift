import Combine
import Foundation
import SwiftUI

struct ContentView: View {
    @ObservedObject var store: PlaylistStore
    @ObservedObject var playback: PlaybackController
    @State private var playTask: Task<Void, Never>?
    @State private var playRequestSerial = 0

    private let clock = Timer.publish(every: 0.10, on: .main, in: .common).autoconnect()

    var body: some View {
        NavigationSplitView {
            SidebarView(store: store, playback: playback)
                .navigationSplitViewColumnWidth(min: 190, ideal: 220, max: 260)
        } detail: {
            VStack(spacing: 0) {
                PlayerToolbarView(
                    onImport: importItemsFromPanel,
                    onRemove: removeSelectedTrack,
                    onClear: clearAllTracks
                )

                Divider()

                NowPlayingView(track: playbackTrack, playback: playback)

                Divider()

                PlaylistTableView(
                    store: store,
                    playback: playback,
                    onRemove: removeTracks,
                    onClear: clearAllTracks,
                    onPlay: { track in
                        play(track)
                    }
                )

                Divider()

                TransportBarView(
                    track: playbackTrack,
                    playback: playback,
                    playbackClock: playback.clock,
                    onPrevious: {
                        DebugLog.log("Transport previous button selected")
                        playPrevious()
                    },
                    onNext: {
                        DebugLog.log("Transport next button selected")
                        playNext()
                    },
                    onToggle: togglePlayback,
                    onStop: {
                        playback.stop()
                        store.activeTrackID = nil
                    }
                )
            }
            .searchable(text: $store.searchText, placement: .toolbar, prompt: "Search")
        }
        .alert(
            store.alert?.title ?? "",
            isPresented: Binding {
                store.alert != nil
            } set: { isPresented in
                if !isPresented {
                    store.alert = nil
                }
            },
            presenting: store.alert
        ) { _ in
            Button("OK", role: .cancel) {}
        } message: { alert in
            Text(alert.message)
        }
        .background {
            // Plain-key shortcuts are handled here, not with `.keyboardShortcut`,
            // so they never fire while the search field is being edited.
            PlayerKeyCommands { command in
                switch command {
                case .togglePlayback:
                    togglePlayback()
                case .removeSelection:
                    removeSelectedTrack()
                case .previous:
                    DebugLog.log("Keyboard previous shortcut")
                    playPrevious()
                case .next:
                    DebugLog.log("Keyboard next shortcut")
                    playNext()
                }
            }
        }
        .onReceive(clock) { _ in
            playback.refresh()
            syncActiveTrackDuration()
            handleAutoAdvance(trigger: "poll")
        }
        .onChange(of: playback.cueBoundaryAdvanceRequest) { _, request in
            if let request {
                handleAutoAdvance(
                    trigger: "\(request.route.rawValue) cue boundary",
                    force: true,
                    sourceTrackID: request.sourceTrackID
                )
            }
        }
    }

    private func togglePlayback() {
        Task {
            await playback.togglePlayback(for: playbackTrack)
            if playback.state.isPlaying,
               let currentTrackID = playback.currentTrackID,
               let currentTrack = store.track(with: currentTrackID),
               store.activeTrackID == nil {
                store.activate(currentTrack)
            }
            syncActiveTrackDuration()
        }
    }

    private func removeSelectedTrack() {
        guard let selectedTrackID = store.selectedTrackID else {
            return
        }

        removeTracks([selectedTrackID])
    }

    private func removeTracks(_ ids: Set<AudioTrack.ID>) {
        let playbackIDs = [playback.currentTrackID, playback.loadingTrackID, store.activeTrackID].compactMap(\.self)
        if playbackIDs.contains(where: ids.contains) {
            DebugLog.log("ContentView stopping playback before removing the active track")
            playRequestSerial += 1
            playTask?.cancel()
            playTask = nil
            playback.stop()
        }

        store.remove(ids: ids)
    }

    private func clearAllTracks() {
        DebugLog.log("ContentView clearing all tracks")
        playRequestSerial += 1
        playTask?.cancel()
        playTask = nil
        playback.stop()
        store.clear()
    }

    private func importItemsFromPanel() {
        DebugLog.log("Toolbar import button selected")
        guard let urls = ImportOpenPanel.selectURLs() else {
            DebugLog.log("Toolbar import panel cancelled")
            return
        }

        Task { @MainActor in
            _ = await store.importItems(urls)
        }
    }

    private func play(_ track: AudioTrack, routePolicy: PlaybackRoutePolicy = .automatic) {
        if playTask != nil {
            DebugLog.log("ContentView cancelling previous play task before starting \(idLabel(track.id))")
            playTask?.cancel()
        }

        playRequestSerial += 1
        let requestSerial = playRequestSerial
        DebugLog.log(
            "ContentView play requested #\(requestSerial): target=\(trackDebugDescription(track)) " +
            "selectedBefore=\(idLabel(store.selectedTrackID)) activeBefore=\(idLabel(store.activeTrackID)) " +
            "playbackState=\(playback.state.title) route=\(playback.route.rawValue) " +
            "routePolicy=\(routePolicy.debugDescription) current=\(display(playback.currentTime))"
        )
        playback.beginTransition(to: track, routePolicy: routePolicy)
        playTask = Task { @MainActor in
            await playback.play(track: track, routePolicy: routePolicy)
            if Task.isCancelled {
                DebugLog.log(
                    "ContentView play task #\(requestSerial) observed cancellation after playback.play: " +
                    trackDebugDescription(track)
                )
            } else {
                if playRequestSerial == requestSerial, playback.currentTrackID == track.id {
                    store.activate(track)
                    store.updateDuration(for: track.id, duration: playback.duration)
                } else if playRequestSerial == requestSerial, !playback.state.isPlaying {
                    store.activeTrackID = nil
                }

                DebugLog.log(
                    "ContentView play task #\(requestSerial) completed: target=\(trackDebugDescription(track)) " +
                    "state=\(playback.state.title) route=\(playback.route.rawValue) " +
                    "current=\(display(playback.currentTime)) selectedNow=\(idLabel(store.selectedTrackID)) " +
                    "activeNow=\(idLabel(store.activeTrackID))"
                )
            }

            if playRequestSerial == requestSerial {
                playTask = nil
            }
        }
        store.select(track)
    }

    private func playNext(routePolicy: PlaybackRoutePolicy = .automatic) {
        guard let next = store.nextTrack(
            after: store.activeTrackID ?? store.selectedTrackID,
            liveFFmpegTrackID: liveFFmpegTrackID
        ) else {
            playback.stop()
            store.activeTrackID = nil
            return
        }

        play(next, routePolicy: routePolicy)
    }

    private func playPrevious() {
        guard let previous = store.previousTrack(
            before: store.activeTrackID ?? store.selectedTrackID,
            liveFFmpegTrackID: liveFFmpegTrackID
        ) else {
            return
        }

        play(previous)
    }

    private func handleAutoAdvance(
        trigger: String,
        force: Bool = false,
        sourceTrackID: AudioTrack.ID? = nil
    ) {
        guard playTask == nil else {
            // The 100 ms poll lands here on every tick while a track loads;
            // only explicit boundary requests are worth a log line.
            if force || sourceTrackID != nil {
                DebugLog.log(
                    "ContentView auto advance ignored during active play task: trigger=\(trigger) " +
                    "active=\(idLabel(store.activeTrackID)) current=\(display(playback.currentTime))"
                )
            }
            return
        }

        if !playback.state.isPlaying {
            if force || sourceTrackID != nil {
                DebugLog.log(
                    "ContentView auto advance ignored while playback is not playing: trigger=\(trigger) " +
                    "state=\(playback.state.title) active=\(idLabel(store.activeTrackID)) " +
                    "current=\(display(playback.currentTime))"
                )
            }
            return
        }

        if let sourceTrackID, store.activeTrackID != sourceTrackID {
            DebugLog.log(
                "ContentView auto advance ignored for stale boundary request: trigger=\(trigger) " +
                "source=\(idLabel(sourceTrackID)) active=\(idLabel(store.activeTrackID)) " +
                "current=\(display(playback.currentTime))"
            )
            return
        }

        guard force || playback.shouldAdvance(from: store.activeTrack) else {
            return
        }

        DebugLog.log(
            "ContentView auto advance requested: trigger=\(trigger) active=\(idLabel(store.activeTrackID)) " +
            "current=\(display(playback.currentTime))"
        )
        playNext(routePolicy: .cueAutoAdvance)
    }

    private func syncActiveTrackDuration() {
        guard let activeTrackID = playback.currentTrackID else {
            return
        }

        store.updateDuration(for: activeTrackID, duration: playback.duration)
    }

    private var liveFFmpegTrackID: AudioTrack.ID? {
        playback.route == .ffmpeg ? playback.currentTrackID : nil
    }

    private var playbackTrack: AudioTrack? {
        if let currentTrackID = playback.currentTrackID,
           let currentTrack = store.track(with: currentTrackID) {
            return currentTrack
        }

        if let loadingTrackID = playback.loadingTrackID,
           let loadingTrack = store.track(with: loadingTrackID) {
            return loadingTrack
        }

        return store.activeTrack ?? store.selectedTrack
    }

    private func trackDebugDescription(_ track: AudioTrack) -> String {
        "id=\(idLabel(track.id)) title='\(track.title)' source=\(track.source.rawValue) " +
        "file='\(track.url.lastPathComponent)' cueStart=\(display(track.cueStart)) cueEnd=\(display(track.cueEnd))"
    }

    private func idLabel(_ id: AudioTrack.ID?) -> String {
        guard let id else {
            return "nil"
        }

        return idLabel(id)
    }

    private func idLabel(_ id: AudioTrack.ID) -> String {
        String(id.uuidString.prefix(8))
    }

    private func display(_ time: TimeInterval?) -> String {
        guard let time else {
            return "<none>"
        }

        return String(format: "%.2f", time)
    }
}
