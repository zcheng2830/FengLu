import Foundation

private actor PlaylistImportWorker {
    func importItems(_ urls: [URL]) -> PlaylistImportResult {
        PlaylistImportService().importItems(urls)
    }
}

/// A message the main window should show once. Each one has its own identity,
/// so two failures with the same text are still two alerts.
struct PlaylistAlert: Identifiable, Equatable {
    let id = UUID()
    var title: String
    var message: String
}

@MainActor
final class PlaylistStore: ObservableObject {
    @Published private(set) var tracks: [AudioTrack] = [] {
        didSet {
            rebuildDerivedState()
        }
    }
    @Published var selectedTrackID: AudioTrack.ID?
    @Published var activeTrackID: AudioTrack.ID?
    @Published var filter: LibraryFilter = .all
    @Published var searchText = ""
    @Published var alert: PlaylistAlert?

    private let importWorker = PlaylistImportWorker()

    // Derived from `tracks`; rebuilt only when the list changes so views that
    // re-evaluate on every playback tick do not rescan the playlist.
    private var tracksRevision = 0
    private var indexByID: [AudioTrack.ID: Int] = [:]
    private var sourceCounts: [TrackSource: Int] = [:]
    private var ffmpegLikelyCount = 0
    private var visibleTracksCache: (key: VisibleTracksKey, tracks: [AudioTrack])?

    private struct VisibleTracksKey: Equatable {
        var revision: Int
        var filter: LibraryFilter
        var query: String
        var liveFFmpegTrackID: AudioTrack.ID?
    }

    private func rebuildDerivedState() {
        tracksRevision += 1
        visibleTracksCache = nil
        var indexByID: [AudioTrack.ID: Int] = [:]
        var sourceCounts: [TrackSource: Int] = [:]
        var ffmpegLikelyCount = 0
        indexByID.reserveCapacity(tracks.count)
        for (index, track) in tracks.enumerated() {
            indexByID[track.id] = index
            sourceCounts[track.source, default: 0] += 1
            if track.isFFmpegLikely {
                ffmpegLikelyCount += 1
            }
        }
        self.indexByID = indexByID
        self.sourceCounts = sourceCounts
        self.ffmpegLikelyCount = ffmpegLikelyCount
    }

    var selectedTrack: AudioTrack? {
        selectedTrackID.flatMap(track(with:))
    }

    var activeTrack: AudioTrack? {
        activeTrackID.flatMap(track(with:))
    }

    var visibleTracks: [AudioTrack] {
        visibleTracks(includingLiveFFmpegTrackID: nil)
    }

    func visibleTracks(includingLiveFFmpegTrackID liveFFmpegTrackID: AudioTrack.ID?) -> [AudioTrack] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).localizedLowercase
        let key = VisibleTracksKey(
            revision: tracksRevision,
            filter: filter,
            query: query,
            // Only the FFmpeg filter depends on the live track.
            liveFFmpegTrackID: filter == .ffmpegLikely ? liveFFmpegTrackID : nil
        )
        if let visibleTracksCache, visibleTracksCache.key == key {
            return visibleTracksCache.tracks
        }

        let visible = tracks.filter { track in
            let matchesFilter = switch filter {
            case .all:
                true
            case .files:
                track.source == .file
            case .playlists:
                track.source == .playlist
            case .cues:
                track.source == .cue
            case .ffmpegLikely:
                track.isFFmpegLikely || track.id == liveFFmpegTrackID
            }

            guard matchesFilter else {
                return false
            }

            guard !query.isEmpty else {
                return true
            }

            return [
                track.title,
                track.artist,
                track.album,
                track.fileName,
                track.playlistName
            ]
            .compactMap(\.self)
            .contains { $0.localizedLowercase.contains(query) }
        }

        visibleTracksCache = (key, visible)
        return visible
    }

    /// Imports the items and returns the playlist rows they map to: new rows,
    /// or the existing row when an item was already in the playlist.
    @discardableResult
    func importItems(_ urls: [URL]) async -> [AudioTrack] {
        DebugLog.log("PlaylistStore importing \(urls.count) item(s)")
        let result = await importWorker.importItems(urls)
        DebugLog.log("PlaylistStore imported \(result.tracks.count) track(s), \(result.warnings.count) warning(s)")
        let rows = append(result.tracks)
        reportImportWarnings(result.warnings, importedAnything: !result.tracks.isEmpty)
        return rows
    }

    private func reportImportWarnings(_ warnings: [String], importedAnything: Bool) {
        guard !warnings.isEmpty else {
            if !importedAnything {
                presentAlert(title: "Nothing to Import", message: "No supported audio files or playlists were found.")
            }
            return
        }

        let shownLimit = 6
        var lines = Array(warnings.prefix(shownLimit))
        if warnings.count > shownLimit {
            lines.append("…and \(warnings.count - shownLimit) more.")
        }

        presentAlert(
            title: importedAnything ? "Some Items Could Not Be Imported" : "Import Failed",
            message: lines.joined(separator: "\n")
        )
    }

    func presentAlert(title: String, message: String) {
        DebugLog.log("PlaylistStore presenting alert '\(title)': \(message)")
        alert = PlaylistAlert(title: title, message: message)
    }

    /// Appends tracks, skipping any that are already in the playlist (same file
    /// and same cue range). Returns one row per input track, in input order,
    /// without repeats: the new row, or the existing one for a duplicate.
    @discardableResult
    func append(_ newTracks: [AudioTrack]) -> [AudioTrack] {
        guard !newTracks.isEmpty else {
            DebugLog.log("PlaylistStore append skipped because no tracks were imported")
            return []
        }

        var rowsByKey: [DuplicateKey: AudioTrack] = [:]
        for track in tracks {
            rowsByKey[DuplicateKey(track)] = rowsByKey[DuplicateKey(track)] ?? track
        }

        var added: [AudioTrack] = []
        var rows: [AudioTrack] = []
        var returnedIDs = Set<AudioTrack.ID>()
        for track in newTracks {
            let key = DuplicateKey(track)
            let row: AudioTrack
            if let existing = rowsByKey[key] {
                row = existing
            } else {
                row = track
                rowsByKey[key] = track
                added.append(track)
            }

            if returnedIDs.insert(row.id).inserted {
                rows.append(row)
            }
        }

        if !added.isEmpty {
            tracks.append(contentsOf: added)
        }
        DebugLog.log(
            "PlaylistStore now has \(tracks.count) track(s); added \(added.count), " +
            "\(newTracks.count - added.count) already present"
        )
        if selectedTrackID == nil {
            selectedTrackID = rows.first?.id
            if let firstTrack = rows.first {
                DebugLog.log("PlaylistStore initial selection: \(trackDebugDescription(firstTrack))")
            }
        }
        return rows
    }

    private struct DuplicateKey: Hashable {
        var url: URL
        var cueStartMilliseconds: Int?
        var cueEndMilliseconds: Int?

        init(_ track: AudioTrack) {
            url = track.url.isFileURL ? track.url.standardizedFileURL : track.url
            // Millisecond precision survives an XSPF round trip.
            cueStartMilliseconds = track.cueStart.map { Int(($0 * 1000).rounded()) }
            cueEndMilliseconds = track.cueEnd.map { Int(($0 * 1000).rounded()) }
        }
    }

    func clear() {
        DebugLog.log(
            "PlaylistStore clearing playlist: count=\(tracks.count) " +
            "selected=\(idLabel(selectedTrackID)) active=\(idLabel(activeTrackID))"
        )
        tracks.removeAll()
        selectedTrackID = nil
        activeTrackID = nil
        alert = nil
    }

    func removeSelected() {
        guard let selectedTrackID else {
            DebugLog.log("PlaylistStore removeSelected ignored because no track is selected")
            return
        }

        remove(ids: [selectedTrackID])
    }

    /// Removes the given rows. When the selected row is among them, selection
    /// moves to the row that takes its place in the visible list (or the one
    /// before it at the end), never back to the top.
    func remove(ids: Set<AudioTrack.ID>) {
        let removedIDs = ids.filter { indexByID[$0] != nil }
        guard !removedIDs.isEmpty else {
            DebugLog.log("PlaylistStore remove ignored because no matching track exists")
            return
        }

        DebugLog.log(
            "PlaylistStore removing \(removedIDs.count) track(s): selectedBefore=\(idLabel(selectedTrackID)) " +
            "activeBefore=\(idLabel(activeTrackID)) countBefore=\(tracks.count)"
        )

        var replacementSelection = selectedTrackID
        if let selectedTrackID, removedIDs.contains(selectedTrackID) {
            let order = visibleTracks.contains { $0.id == selectedTrackID } ? visibleTracks : tracks
            let selectedIndex = order.firstIndex { $0.id == selectedTrackID } ?? 0
            let following = order[selectedIndex...].first { !removedIDs.contains($0.id) }
            let preceding = order[..<selectedIndex].last { !removedIDs.contains($0.id) }
            replacementSelection = (following ?? preceding)?.id
        }

        tracks.removeAll { removedIDs.contains($0.id) }
        if let activeTrackID, removedIDs.contains(activeTrackID) {
            self.activeTrackID = nil
        }
        selectedTrackID = replacementSelection
        DebugLog.log(
            "PlaylistStore remove finished: count=\(tracks.count) " +
            "selectedNow=\(idLabel(selectedTrackID)) activeNow=\(idLabel(activeTrackID))"
        )
    }

    func track(with id: AudioTrack.ID) -> AudioTrack? {
        indexByID[id].map { tracks[$0] }
    }

    func select(_ track: AudioTrack) {
        DebugLog.log(
            "PlaylistStore selecting track: from=\(idLabel(selectedTrackID)) " +
            "to=\(trackDebugDescription(track))"
        )
        selectedTrackID = track.id
    }

    func activate(_ track: AudioTrack) {
        DebugLog.log(
            "PlaylistStore activating track: selectedBefore=\(idLabel(selectedTrackID)) " +
            "activeBefore=\(idLabel(activeTrackID)) target=\(trackDebugDescription(track))"
        )
        selectedTrackID = track.id
        activeTrackID = track.id
        DebugLog.log(
            "PlaylistStore active track set: selectedNow=\(idLabel(selectedTrackID)) " +
            "activeNow=\(idLabel(activeTrackID))"
        )
    }

    func updateDuration(for id: AudioTrack.ID, duration: TimeInterval?) {
        guard let duration, duration.isFinite, duration > 0 else {
            return
        }

        guard let index = indexByID[id] else {
            return
        }

        let previousDuration = tracks[index].duration
        if let previousDuration, abs(previousDuration - duration) < 0.01 {
            return
        }

        var updatedTracks = tracks
        updatedTracks[index].duration = duration
        tracks = updatedTracks
        DebugLog.log(
            "PlaylistStore updated duration: id=\(idLabel(id)) " +
            "title='\(tracks[index].title)' old=\(display(previousDuration)) new=\(display(duration))"
        )
    }

    /// The order Next / Previous / auto-advance walk: the visible (filtered and
    /// searched) list when the reference track is in it, so playback never
    /// jumps to a hidden row; the whole playlist otherwise.
    private func navigationOrder(
        around id: AudioTrack.ID?,
        liveFFmpegTrackID: AudioTrack.ID?
    ) -> [AudioTrack] {
        let visible = visibleTracks(includingLiveFFmpegTrackID: liveFFmpegTrackID)
        guard let id else {
            return visible.isEmpty ? tracks : visible
        }

        if visible.contains(where: { $0.id == id }) {
            return visible
        }

        if indexByID[id] != nil {
            return tracks
        }

        return visible.isEmpty ? tracks : visible
    }

    func nextTrack(after id: AudioTrack.ID?, liveFFmpegTrackID: AudioTrack.ID? = nil) -> AudioTrack? {
        let order = navigationOrder(around: id, liveFFmpegTrackID: liveFFmpegTrackID)
        guard let firstTrack = order.first else {
            DebugLog.log("PlaylistStore nextTrack requested on empty playlist")
            return nil
        }

        guard let id, let index = order.firstIndex(where: { $0.id == id }) else {
            DebugLog.log(
                "PlaylistStore nextTrack falling back to first: after=\(idLabel(id)) " +
                "first=\(trackDebugDescription(firstTrack))"
            )
            return firstTrack
        }

        let nextIndex = order.index(after: index)
        guard nextIndex < order.endIndex else {
            DebugLog.log("PlaylistStore nextTrack reached end after id=\(idLabel(id)) index=\(index + 1)/\(order.count)")
            return nil
        }

        DebugLog.log("PlaylistStore nextTrack: fromIndex=\(index + 1)/\(order.count) to=\(trackDebugDescription(order[nextIndex]))")
        return order[nextIndex]
    }

    func previousTrack(before id: AudioTrack.ID?, liveFFmpegTrackID: AudioTrack.ID? = nil) -> AudioTrack? {
        let order = navigationOrder(around: id, liveFFmpegTrackID: liveFFmpegTrackID)
        guard let firstTrack = order.first else {
            DebugLog.log("PlaylistStore previousTrack requested on empty playlist")
            return nil
        }

        guard let id, let index = order.firstIndex(where: { $0.id == id }) else {
            DebugLog.log(
                "PlaylistStore previousTrack falling back to first: before=\(idLabel(id)) " +
                "first=\(trackDebugDescription(firstTrack))"
            )
            return firstTrack
        }

        guard index > order.startIndex else {
            DebugLog.log("PlaylistStore previousTrack already at first track id=\(idLabel(id))")
            return firstTrack
        }

        let previousIndex = order.index(before: index)
        DebugLog.log(
            "PlaylistStore previousTrack: fromIndex=\(index + 1)/\(order.count) " +
            "to=\(trackDebugDescription(order[previousIndex]))"
        )
        return order[previousIndex]
    }

    func count(for filter: LibraryFilter) -> Int {
        count(for: filter, liveFFmpegTrackID: nil)
    }

    func count(for filter: LibraryFilter, liveFFmpegTrackID: AudioTrack.ID?) -> Int {
        switch filter {
        case .all:
            return tracks.count
        case .files:
            return sourceCounts[.file, default: 0]
        case .playlists:
            return sourceCounts[.playlist, default: 0]
        case .cues:
            return sourceCounts[.cue, default: 0]
        case .ffmpegLikely:
            let liveTrack = liveFFmpegTrackID.flatMap(track(with:))
            let countsLiveTrack = liveTrack.map { !$0.isFFmpegLikely } ?? false
            return ffmpegLikelyCount + (countsLiveTrack ? 1 : 0)
        }
    }

    private func trackDebugDescription(_ track: AudioTrack) -> String {
        "id=\(idLabel(track.id)) index=\(indexDescription(for: track.id)) " +
        "title='\(track.title)' source=\(track.source.rawValue) file='\(track.url.lastPathComponent)' " +
        "cueStart=\(display(track.cueStart)) cueEnd=\(display(track.cueEnd))"
    }

    private func indexDescription(for id: AudioTrack.ID) -> String {
        guard let index = indexByID[id] else {
            return "<missing>/\(tracks.count)"
        }

        return "\(index + 1)/\(tracks.count)"
    }

    private func idLabel(_ id: AudioTrack.ID?) -> String {
        guard let id else {
            return "nil"
        }

        return String(id.uuidString.prefix(8))
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
