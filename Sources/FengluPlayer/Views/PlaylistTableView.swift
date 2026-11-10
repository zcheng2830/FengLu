import AppKit
import Foundation
import SwiftUI

struct PlaylistTableView: View {
    @ObservedObject var store: PlaylistStore
    @ObservedObject var playback: PlaybackController
    var onRemove: (Set<AudioTrack.ID>) -> Void
    var onClear: () -> Void
    var onPlay: (AudioTrack) -> Void

    private var visibleTracks: [AudioTrack] {
        store.visibleTracks(includingLiveFFmpegTrackID: liveFFmpegTrackID)
    }

    private var liveFFmpegTrackID: AudioTrack.ID? {
        playback.route == .ffmpeg ? playback.currentTrackID : nil
    }


    private var selection: Binding<Set<AudioTrack.ID>> {
        Binding {
            if let selectedTrackID = store.selectedTrackID {
                return [selectedTrackID]
            }
            return []
        } set: { newSelection in
            guard let track = firstSelectedVisibleTrack(in: newSelection) else {
                DebugLog.log(
                    "Playlist selection cleared or off-screen: newSelection=\(idList(newSelection)) " +
                    "visibleCount=\(visibleTracks.count) selectedBefore=\(idLabel(store.selectedTrackID)) " +
                    "activeBefore=\(idLabel(store.activeTrackID))"
                )
                store.selectedTrackID = nil
                return
            }

            store.selectedTrackID = track.id
            DebugLog.log("Playlist selection changed: \(trackDebugDescription(track))")
        }
    }

    var body: some View {
        // Resolve the visible rows once per evaluation; the store caches them
        // between playlist, filter and search changes.
        let visibleTracks = self.visibleTracks
        let revealTrackID = store.activeTrackID ?? store.selectedTrackID
        let revealRow = revealTrackID.flatMap { id in visibleTracks.firstIndex { $0.id == id } }

        Table(visibleTracks, selection: selection) {
            TableColumn("#") { track in
                activatingCell(for: track) {
                    Text(track.trackNumber.map { String($0) } ?? "")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
            .width(min: 34, ideal: 44, max: 54)

            TableColumn("Title") { track in
                activatingCell(for: track) {
                    HStack(spacing: 8) {
                        Image(systemName: track.source.systemImage)
                            .foregroundStyle(.secondary)
                            .frame(width: 16)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(track.title)
                                .lineLimit(1)
                            if let playlistName = track.playlistName {
                                Text(playlistName)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                    }
                }
            }
            .width(min: 260, ideal: 420)

            TableColumn("Artist") { track in
                activatingCell(for: track) {
                    Text(track.artist ?? "")
                        .lineLimit(1)
                }
            }
            .width(min: 120, ideal: 180)

            TableColumn("Album") { track in
                activatingCell(for: track) {
                    Text(track.album ?? "")
                        .lineLimit(1)
                }
            }
            .width(min: 120, ideal: 180)

            TableColumn("Time") { track in
                activatingCell(for: track) {
                    Text(track.displayDuration)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
            .width(min: 70, ideal: 82, max: 94)

            TableColumn("Format") { track in
                activatingCell(for: track) {
                    Text(track.formatLabel)
                        .foregroundStyle(.secondary)
                        .monospaced()
                }
            }
            .width(min: 70, ideal: 82, max: 94)

            TableColumn("Route") { track in
                PlaylistRouteCell(track: track, playback: playback)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .width(min: 96, ideal: 116, max: 140)
        }
        .contextMenu(forSelectionType: AudioTrack.ID.self) { selection in
            Button("Play") {
                guard let track = visibleTracks.first(where: { selection.contains($0.id) }) else {
                    return
                }
                onPlay(track)
            }
            .disabled(selection.isEmpty)
            // Acts on the rows the menu was opened on, which need not be the
            // current selection.
            Button("Remove") {
                onRemove(selection)
            }
            .disabled(selection.isEmpty)

            Divider()

            Button("Clear All Tracks") {
                onClear()
            }
        }
        .background {
            PlaylistTableRowRevealer(
                trackID: revealRow == nil ? nil : revealTrackID,
                row: revealRow,
                visibleRowCount: visibleTracks.count
            )
        }
    }

    private func firstSelectedVisibleTrack(in selection: Set<AudioTrack.ID>) -> AudioTrack? {
        visibleTracks.first { selection.contains($0.id) }
    }

    private func activatingCell<Content: View>(
        for track: AudioTrack,
        @ViewBuilder content: () -> Content
    ) -> some View {
        content()
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture {
                DebugLog.log("Playlist row clicked for playback: \(trackDebugDescription(track))")
                onPlay(track)
            }
    }

    private func trackDebugDescription(_ track: AudioTrack) -> String {
        "id=\(idLabel(track.id)) visibleIndex=\(visibleIndexDescription(for: track)) " +
        "title='\(track.title)' source=\(track.source.rawValue) file='\(track.url.lastPathComponent)' " +
        "cueStart=\(display(track.cueStart)) cueEnd=\(display(track.cueEnd)) " +
        "selectedBefore=\(idLabel(store.selectedTrackID)) activeBefore=\(idLabel(store.activeTrackID))"
    }

    private func visibleIndexDescription(for track: AudioTrack) -> String {
        guard let index = visibleTracks.firstIndex(where: { $0.id == track.id }) else {
            return "<not-visible>/\(visibleTracks.count)"
        }

        return "\(index + 1)/\(visibleTracks.count)"
    }

    private func idList(_ ids: Set<AudioTrack.ID>) -> String {
        guard !ids.isEmpty else {
            return "[]"
        }

        return "[" + ids.map { idLabel($0) }.sorted().joined(separator: ",") + "]"
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

/// SwiftUI's macOS `Table` updates its bound selection without scrolling the
/// selected row into view. Locate the backing `NSTableView` and reveal the row
/// whenever playback moves to another visible track.
private struct PlaylistTableRowRevealer: NSViewRepresentable {
    let trackID: AudioTrack.ID?
    let row: Int?
    let visibleRowCount: Int

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSView {
        NSView(frame: .zero)
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard let trackID, let row else {
            context.coordinator.cancelPendingReveal()
            return
        }

        let request = RevealRequest(trackID: trackID, row: row, visibleRowCount: visibleRowCount)
        context.coordinator.reveal(request, from: nsView)
    }

    struct RevealRequest: Equatable {
        let trackID: AudioTrack.ID
        let row: Int
        let visibleRowCount: Int
    }

    @MainActor
    final class Coordinator {
        private var generation = 0
        private var lastCompletedRequest: RevealRequest?
        private var pendingRequest: RevealRequest?

        func cancelPendingReveal() {
            generation += 1
            pendingRequest = nil
            lastCompletedRequest = nil
        }

        func reveal(_ request: RevealRequest, from locatorView: NSView) {
            guard request != lastCompletedRequest, request != pendingRequest else {
                return
            }

            generation += 1
            pendingRequest = request
            let requestGeneration = generation
            attemptReveal(
                request,
                from: locatorView,
                generation: requestGeneration,
                remainingAttempts: 4
            )
        }

        private func attemptReveal(
            _ request: RevealRequest,
            from locatorView: NSView,
            generation requestGeneration: Int,
            remainingAttempts: Int
        ) {
            DispatchQueue.main.async { [weak self, weak locatorView] in
                guard let self,
                      let locatorView,
                      requestGeneration == self.generation
                else {
                    return
                }

                if let tableView = self.nearestTableView(from: locatorView),
                   request.row >= 0,
                   request.row < tableView.numberOfRows {
                    tableView.scrollRowToVisible(request.row)
                    self.pendingRequest = nil
                    self.lastCompletedRequest = request
                    DebugLog.log(
                        "Playlist revealed playing row: id=\(self.idLabel(request.trackID)) " +
                        "row=\(request.row + 1)/\(request.visibleRowCount)"
                    )
                    return
                }

                guard remainingAttempts > 1 else {
                    self.pendingRequest = nil
                    DebugLog.log(
                        "Playlist could not reveal playing row: id=\(self.idLabel(request.trackID)) " +
                        "row=\(request.row + 1)/\(request.visibleRowCount)"
                    )
                    return
                }

                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self, weak locatorView] in
                    guard let self,
                          let locatorView,
                          requestGeneration == self.generation
                    else {
                        return
                    }

                    self.attemptReveal(
                        request,
                        from: locatorView,
                        generation: requestGeneration,
                        remainingAttempts: remainingAttempts - 1
                    )
                }
            }
        }

        private func nearestTableView(from locatorView: NSView) -> NSTableView? {
            var ancestor: NSView? = locatorView
            while let current = ancestor {
                if let tableView = firstTableView(in: current) {
                    return tableView
                }
                ancestor = current.superview
            }
            return nil
        }

        private func firstTableView(in view: NSView) -> NSTableView? {
            if let tableView = view as? NSTableView {
                return tableView
            }

            for subview in view.subviews {
                if let tableView = firstTableView(in: subview) {
                    return tableView
                }
            }
            return nil
        }

        private func idLabel(_ id: AudioTrack.ID) -> String {
            String(id.uuidString.prefix(8))
        }
    }
}

private struct PlaylistRouteCell: View {
    let track: AudioTrack
    @ObservedObject var playback: PlaybackController

    var body: some View {
        Text(routeLabel)
            .id(routeLabel)
            .foregroundStyle(.secondary)
            .lineLimit(1)
    }

    private var routeLabel: String {
        if case .loading = playback.state {
            return track.id == playback.loadingTrackID ? "Loading" : track.routePreferenceLabel
        }

        if track.id == playback.currentTrackID {
            switch playback.route {
            case .native:
                return "Native"
            case .ffmpeg:
                return "FFmpeg"
            case .idle:
                break
            }
        }

        return track.routePreferenceLabel
    }
}
