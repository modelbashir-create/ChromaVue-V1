import SwiftUI

extension View {
    /// Convenience helper so HUD elements can use a consistent Liquid Glass capsule style.
    /// This is just a thin wrapper over the native glassEffect API.
    func liquidGlassCapsule() -> some View {
        glassEffect(.regular, in: Capsule())
    }
}
