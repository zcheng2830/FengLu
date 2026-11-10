import SwiftUI

struct LyricsCommands: Commands {
    @ObservedObject var windowState: LyricsWindowState
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some Commands {
        CommandGroup(after: .windowArrangement) {
            Button(windowState.isPresented ? "Hide Lyrics" : "Show Lyrics") {
                windowState.isPresented.toggle()
                DebugLog.log(windowState.isPresented ? "Lyrics menu command: show window" : "Lyrics menu command: hide window")
                if windowState.isPresented {
                    openWindow(id: LyricsWindowState.windowID)
                } else {
                    dismissWindow(id: LyricsWindowState.windowID)
                }
            }
            .keyboardShortcut("l", modifiers: [.command, .shift])
        }
    }
}
