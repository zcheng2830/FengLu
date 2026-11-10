import AppKit
import Foundation
import Testing
@testable import FengluPlayer

@MainActor
struct PlaylistStoreTests {
    private func track(_ name: String, source: TrackSource = .file, cue: (TimeInterval, TimeInterval)? = nil) -> AudioTrack {
        AudioTrack(
            url: URL(fileURLWithPath: "/music/\(name).mp3"),
            title: name,
            cueStart: cue?.0,
            cueEnd: cue?.1,
            source: source
        )
    }

    private func store(_ names: [String]) -> (PlaylistStore, [AudioTrack]) {
        let store = PlaylistStore()
        let tracks = names.map { track($0) }
        store.append(tracks)
        return (store, tracks)
    }

    @Test
    func removingTheSelectedRowSelectsItsReplacement() {
        let (store, tracks) = store(["a", "b", "c", "d"])

        store.selectedTrackID = tracks[1].id
        store.removeSelected()
        #expect(store.tracks.map(\.title) == ["a", "c", "d"])
        #expect(store.selectedTrackID == tracks[2].id)

        store.selectedTrackID = tracks[3].id
        store.removeSelected()
        #expect(store.selectedTrackID == tracks[2].id)

        store.remove(ids: [tracks[0].id, tracks[2].id])
        #expect(store.tracks.isEmpty)
        #expect(store.selectedTrackID == nil)
    }

    @Test
    func removingOtherRowsKeepsSelectionAndClearsTheActiveRow() {
        let (store, tracks) = store(["a", "b", "c"])
        store.selectedTrackID = tracks[0].id
        store.activeTrackID = tracks[2].id

        store.remove(ids: [tracks[2].id])

        #expect(store.tracks.map(\.title) == ["a", "b"])
        #expect(store.selectedTrackID == tracks[0].id)
        #expect(store.activeTrackID == nil)
    }

    @Test
    func removalUnderAFilterSelectsTheNextVisibleRow() {
        let (store, tracks) = store(["rock one", "jazz one", "rock two", "jazz two", "rock three"])
        store.searchText = "rock"
        store.selectedTrackID = tracks[2].id

        store.removeSelected()

        #expect(store.selectedTrackID == tracks[4].id)
    }

    @Test
    func nextAndPreviousFollowTheVisibleOrder() {
        let (store, tracks) = store(["rock one", "jazz one", "rock two", "jazz two"])

        #expect(store.nextTrack(after: tracks[0].id)?.id == tracks[1].id)
        #expect(store.nextTrack(after: tracks[3].id) == nil)
        #expect(store.previousTrack(before: tracks[0].id)?.id == tracks[0].id)
        #expect(store.nextTrack(after: nil)?.id == tracks[0].id)

        store.searchText = "rock"
        #expect(store.nextTrack(after: tracks[0].id)?.id == tracks[2].id)
        #expect(store.previousTrack(before: tracks[2].id)?.id == tracks[0].id)
        #expect(store.nextTrack(after: tracks[2].id) == nil)
        // A playing track hidden by the search still advances through the full list.
        #expect(store.nextTrack(after: tracks[1].id)?.id == tracks[2].id)
        #expect(store.nextTrack(after: nil)?.id == tracks[0].id)
    }

    @Test
    func filtersAndCountsStayInStepWithTheTrackList() {
        let store = PlaylistStore()
        store.append([
            track("file"),
            track("list", source: .playlist),
            track("cue1", source: .cue, cue: (0, 10)),
            track("cue2", source: .cue, cue: (10, 20))
        ])

        #expect(store.count(for: .all) == 4)
        #expect(store.count(for: .files) == 1)
        #expect(store.count(for: .playlists) == 1)
        #expect(store.count(for: .cues) == 2)

        store.filter = .cues
        #expect(store.visibleTracks.map(\.title) == ["cue1", "cue2"])
        store.remove(ids: [store.tracks[2].id])
        #expect(store.visibleTracks.map(\.title) == ["cue2"])
        #expect(store.count(for: .cues) == 1)
        store.filter = .all
        store.searchText = "  LIST "
        #expect(store.visibleTracks.map(\.title) == ["list"])
    }

    @Test
    func importingTheSameTrackTwiceReusesTheExistingRow() {
        let store = PlaylistStore()
        let first = store.append([track("a"), track("img", source: .cue, cue: (0, 10))])
        let second = store.append([
            track("a"),
            track("img", source: .cue, cue: (0, 10)),
            track("img", source: .cue, cue: (10, 20)),
            track("b"),
            track("b")
        ])

        #expect(store.tracks.map(\.title) == ["a", "img", "img", "b"])
        #expect(second.prefix(2).map(\.id) == first.map(\.id))
        #expect(second.count == 4)
        #expect(Set(second.map(\.id)).isSubset(of: Set(store.tracks.map(\.id))))
    }

    @Test
    func repeatedIdenticalAlertsAreDistinct() {
        let store = PlaylistStore()
        store.presentAlert(title: "Import Failed", message: "same")
        let first = store.alert
        store.alert = nil
        store.presentAlert(title: "Import Failed", message: "same")

        #expect(store.alert != nil)
        #expect(store.alert != first)
    }

    @Test(arguments: [
        (UInt16(49), NSEvent.ModifierFlags([]), false, PlayerKeyCommand.togglePlayback as PlayerKeyCommand?),
        (UInt16(51), NSEvent.ModifierFlags([]), false, .removeSelection),
        (UInt16(117), NSEvent.ModifierFlags([.function]), false, .removeSelection),
        (UInt16(123), NSEvent.ModifierFlags([.command, .numericPad, .function]), false, .previous),
        (UInt16(124), NSEvent.ModifierFlags([.command]), false, .next),
        (UInt16(49), NSEvent.ModifierFlags([]), true, nil),
        (UInt16(51), NSEvent.ModifierFlags([]), true, nil),
        (UInt16(123), NSEvent.ModifierFlags([.command]), true, nil),
        (UInt16(123), NSEvent.ModifierFlags([]), false, nil),
        (UInt16(49), NSEvent.ModifierFlags([.command]), false, nil),
        (UInt16(51), NSEvent.ModifierFlags([.option]), false, nil)
    ])
    func keyCommandsAreSuppressedWhileEditingText(
        keyCode: UInt16,
        modifiers: NSEvent.ModifierFlags,
        isEditingText: Bool,
        expected: PlayerKeyCommand?
    ) {
        #expect(
            PlayerKeyCommand.command(keyCode: keyCode, modifiers: modifiers, isEditingText: isEditingText) == expected
        )
    }
}

struct PlaylistImportServiceTests {
    @Test
    func oneBrokenPlaylistDoesNotDiscardTheRest() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("fenglu-import-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: directory)
        }

        for name in ["01 - One.mp3", "02 - Two.mp3", "listed.mp3"] {
            try Data().write(to: directory.appendingPathComponent(name))
        }
        try Data("<playlist><trackList><track>".utf8).write(to: directory.appendingPathComponent("broken.xspf"))
        try Data("#EXTM3U\nlisted.mp3\nmissing.mp3\n".utf8).write(to: directory.appendingPathComponent("good.m3u"))
        let unsupported = directory.appendingPathComponent("video.wma")
        try Data().write(to: unsupported)

        let result = PlaylistImportService().importItems([directory, unsupported])

        #expect(result.tracks.map(\.url.lastPathComponent) == ["listed.mp3", "missing.mp3", "01 - One.mp3", "02 - Two.mp3"])
        #expect(result.warnings.count == 3)
        #expect(result.warnings.contains { $0.hasPrefix("broken.xspf:") })
        #expect(result.warnings.contains { $0.hasPrefix("good.m3u: 1 of 2") })
        #expect(result.warnings.contains { $0.hasPrefix("video.wma:") })
    }
}
