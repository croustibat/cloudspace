import SwiftUI

// Back-deployment shims. The app targets macOS 15 and uses macOS 26 styling (Liquid Glass) where it exists.

extension View {
    /// The window's primary action button: Liquid Glass on macOS 26, the standard prominent (accent-filled) button
    /// on earlier systems.
    @ViewBuilder
    func primaryActionButtonStyle() -> some View {
        if #available(macOS 26.0, *) {
            buttonStyle(.glassProminent)
        } else {
            buttonStyle(.borderedProminent)
        }
    }
}
