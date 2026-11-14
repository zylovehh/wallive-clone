import SwiftUI

/// Small pill button that reuses the glass look of StatusView buttons.
struct GlassIconButton: View {
    let title: String
    let systemImage: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: systemImage)
                Text(title)
            }
            .font(.subheadline.weight(.medium))
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
        }
        .buttonStyle(.bordered)
    }
}
