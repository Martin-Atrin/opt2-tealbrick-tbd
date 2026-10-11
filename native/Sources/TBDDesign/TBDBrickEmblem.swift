import SwiftUI

/// Shared empty-state emblem: three bricks in running bond, each a single real
/// brick cropped from the Agents wall render (AgentWallRed / AgentWallTeal in the
/// host app's asset catalog, resolved from Bundle.main at runtime).
public struct TBDBrickEmblem: View {
    // Wall tile geometry in metres (companion/design/agent-wall/wall-layout.json).
    private static let tileSize = CGSize(width: 1.8, height: 0.6)
    private static let brick = CGSize(width: 0.215, height: 0.065)
    private static let width: CGFloat = 56
    private static var scale: CGFloat { width / brick.width }
    private static var height: CGFloat { brick.height * scale }
    private static let mortar: CGFloat = 4

    public init() {}

    public var body: some View {
        VStack(alignment: .leading, spacing: Self.mortar) {
            brick("AgentWallTeal", x: 0.7925, top: 0.305)
                .offset(x: (Self.width + Self.mortar) / 2)
            HStack(spacing: Self.mortar) {
                brick("AgentWallRed", x: 0.455, top: 0.380)
                brick("AgentWallRed", x: 1.130, top: 0.230)
            }
        }
        .frame(width: Self.width * 2 + Self.mortar, height: Self.height * 2 + Self.mortar, alignment: .topLeading)
        // The offset wall images extend far outside their clip; clipping hides them but
        // does not stop hit-testing, so they swallowed clicks on the rail. Decorative only.
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    /// One brick: the whole tile scaled so a brick is `width` wide, shifted to that brick.
    private func brick(_ name: String, x: CGFloat, top: CGFloat) -> some View {
        Image(name)
            .resizable()
            .frame(width: Self.tileSize.width * Self.scale, height: Self.tileSize.height * Self.scale)
            .offset(x: -x * Self.scale, y: -top * Self.scale)
            .frame(width: Self.width, height: Self.height, alignment: .topLeading)
            .clipShape(RoundedRectangle(cornerRadius: 2))
            .contentShape(Rectangle())
            .shadow(color: .black.opacity(0.18), radius: 0, x: 1.5, y: 1.5)
    }
}
