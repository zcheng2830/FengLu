import AppKit
import SwiftUI

/// Keyboard commands of the main window that have no menu item.
enum PlayerKeyCommand: Equatable, Sendable {
    case togglePlayback
    case removeSelection
    case previous
    case next

    /// Maps a key press to a command. Returns `nil` while text is being edited,
    /// so Space, Delete and Command-arrows keep their meaning in the search field.
    static func command(
        keyCode: UInt16,
        modifiers: NSEvent.ModifierFlags,
        isEditingText: Bool
    ) -> PlayerKeyCommand? {
        guard !isEditingText else {
            return nil
        }

        // Arrow and forward-delete keys also carry `.function` / `.numericPad`.
        let modifiers = modifiers.intersection([.command, .option, .control, .shift])
        switch keyCode {
        case KeyCode.space where modifiers.isEmpty:
            return .togglePlayback
        case KeyCode.delete where modifiers.isEmpty, KeyCode.forwardDelete where modifiers.isEmpty:
            return .removeSelection
        case KeyCode.leftArrow where modifiers == .command:
            return .previous
        case KeyCode.rightArrow where modifiers == .command:
            return .next
        default:
            return nil
        }
    }

    private enum KeyCode {
        static let space: UInt16 = 49
        static let delete: UInt16 = 51
        static let forwardDelete: UInt16 = 117
        static let leftArrow: UInt16 = 123
        static let rightArrow: UInt16 = 124
    }
}

/// Installs a key-down monitor scoped to the window that hosts this view.
///
/// `.keyboardShortcut` on a button fires no matter what has keyboard focus, so
/// a plain Space or Delete would act on the playlist while the user types in
/// the search field. The monitor checks the first responder instead.
struct PlayerKeyCommands: NSViewRepresentable {
    var onCommand: (PlayerKeyCommand) -> Void

    func makeNSView(context: Context) -> MonitorView {
        let view = MonitorView(frame: .zero)
        view.onCommand = onCommand
        return view
    }

    func updateNSView(_ nsView: MonitorView, context: Context) {
        nsView.onCommand = onCommand
    }

    static func dismantleNSView(_ nsView: MonitorView, coordinator: ()) {
        nsView.removeMonitor()
    }

    final class MonitorView: NSView {
        var onCommand: ((PlayerKeyCommand) -> Void)?
        private var monitor: Any?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            removeMonitor()
            guard window != nil else {
                return
            }

            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                // Local monitors are always called on the main thread.
                let handled = MainActor.assumeIsolated {
                    self?.handle(keyCode: event.keyCode, modifiers: event.modifierFlags, eventWindow: event.window) ?? false
                }
                return handled ? nil : event
            }
        }

        func removeMonitor() {
            if let monitor {
                NSEvent.removeMonitor(monitor)
            }
            monitor = nil
        }

        private func handle(keyCode: UInt16, modifiers: NSEvent.ModifierFlags, eventWindow: NSWindow?) -> Bool {
            // Sheets, alerts and the lyrics window are other windows: leave their keys alone.
            guard let window, eventWindow === window, window.attachedSheet == nil else {
                return false
            }

            // While a text field is edited the first responder is its field editor.
            let isEditingText = window.firstResponder is NSText
            guard let command = PlayerKeyCommand.command(
                keyCode: keyCode,
                modifiers: modifiers,
                isEditingText: isEditingText
            ) else {
                return false
            }

            onCommand?(command)
            return true
        }
    }
}
