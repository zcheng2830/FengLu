import Foundation

struct LyricsDocument: Equatable, Sendable {
    var sourceURL: URL?
    var sourceDescription: String
    var lines: [LyricsLine]
    var plainText: String
    var isSynchronized: Bool

    static let empty = LyricsDocument(
        sourceURL: nil,
        sourceDescription: "",
        lines: [],
        plainText: "",
        isSynchronized: false
    )

    var isEmpty: Bool {
        lines.isEmpty
    }

    var displayKind: String {
        if sourceDescription == "Playing item description" {
            return "Info"
        }

        return isSynchronized ? "LRC" : "Text"
    }

    func activeLineID(at time: TimeInterval) -> LyricsLine.ID? {
        guard isSynchronized else {
            return nil
        }

        return lines.last { line in
            guard let lineTime = line.time else {
                return false
            }

            return lineTime <= time + 0.15
        }?.id
    }
}

struct LyricsLine: Identifiable, Equatable, Sendable {
    let id: Int
    var time: TimeInterval?
    var text: String
}
