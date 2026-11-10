import Foundation

@MainActor
final class LyricsWindowState: ObservableObject {
    static let windowID = "lyrics"

    @Published var isPresented = false
}
