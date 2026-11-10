import SwiftUI

struct PlayerToolbarView: View {
    var onImport: () -> Void
    var onRemove: () -> Void
    var onClear: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            IconButton(systemName: "plus", help: "Add files or playlists", action: onImport)

            IconButton(systemName: "minus", help: "Remove selected track (Delete)", action: onRemove)

            IconButton(systemName: "trash", help: "Clear all tracks", action: onClear)

            Divider()
                .frame(height: 22)

            Text("Fenglu Player")
                .font(.headline)

            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
    }
}
