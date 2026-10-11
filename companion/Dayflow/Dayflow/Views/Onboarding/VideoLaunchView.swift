import SwiftUI
import AVKit

/// A native, silent brand reveal. Content behind it stays visible even if interrupted.
struct VideoLaunchView: View {
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var revealed = false
  @State private var shine = false
  @State private var hasCompleted = false
  private var onComplete: (() -> Void)?

  func onVideoComplete(_ completion: @escaping () -> Void) -> VideoLaunchView {
    var view = self
    view.onComplete = completion
    return view
  }

  var body: some View {
    GeometryReader { geometry in
      ZStack {
        Color(hex: "F3F1E9")
        Ellipse().fill(Color(hex: "059393").opacity(0.32))
          .frame(width: geometry.size.width * 0.8, height: 300)
          .blur(radius: 80).offset(x: revealed ? 120 : -180, y: -90)
        Ellipse().fill(Color(hex: "A94944").opacity(0.18))
          .frame(width: 420, height: 240).blur(radius: 85)
          .offset(x: revealed ? -140 : 120, y: 110)
        VStack(spacing: 12) {
          ZStack {
            Circle().fill(.white.opacity(0.3))
              .overlay(Circle().strokeBorder(.white.opacity(0.7), lineWidth: 1))
              .shadow(color: Color(hex: "034A4A").opacity(0.12), radius: 16, y: 8)
            Image("TealbrickLogo").resizable().scaledToFit().padding(22)
            Circle().fill(LinearGradient(colors: [.clear, .white.opacity(0.65), .clear], startPoint: .topLeading, endPoint: .bottomTrailing))
              .offset(x: shine ? 210 : -210).mask(Circle())
          }.frame(width: 172, height: 172)
            .rotation3DEffect(.degrees(reduceMotion ? 0 : (revealed ? 0 : -30)), axis: (x: 0, y: 1, z: 0))
          Text("Tealbrick").font(.custom("Switzer-Medium", size: 58)).tracking(-2)
            .foregroundStyle(Color(hex: "173F3C"))
          Text("companion").font(.custom("Switzer-Regular", size: 16))
            .foregroundStyle(Color(hex: "526560"))
        }
        .opacity(revealed ? 1 : 0)
        .scaleEffect(reduceMotion ? 1 : (revealed ? 1 : 0.88))
      }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    .ignoresSafeArea()
    .accessibilityLabel("Tealbrick companion")
    .task {
      withAnimation(.easeOut(duration: reduceMotion ? 0.1 : 0.7)) { revealed = true }
      withAnimation(.easeInOut(duration: 1.2).delay(0.25)) { shine = true }
      do { try await Task.sleep(for: .seconds(reduceMotion ? 0.25 : 1.65)) } catch { return }
      guard !hasCompleted else { return }
      hasCompleted = true
      onComplete?()
    }
  }
}

// Custom AVPlayer view without controls
struct AVPlayerControllerRepresented: NSViewRepresentable {
  let player: AVPlayer

  func makeNSView(context: Context) -> NonInteractiveAVPlayerView {
    let view = NonInteractiveAVPlayerView()
    view.player = player
    view.controlsStyle = .none
    view.videoGravity = .resizeAspectFill  // Fill the screen
    view.showsFullScreenToggleButton = false
    view.allowsPictureInPicturePlayback = false

    // Disable all user interactions
    view.isHidden = false
    view.wantsLayer = true

    return view
  }

  func updateNSView(_ nsView: NonInteractiveAVPlayerView, context: Context) {}
}

// Custom AVPlayerView that prevents all user interactions
class NonInteractiveAVPlayerView: AVPlayerView {
  override func hitTest(_ point: NSPoint) -> NSView? {
    // Prevent all mouse interactions
    return nil
  }

  override func keyDown(with event: NSEvent) {
    // Ignore all keyboard events (including spacebar)
    // Don't call super to prevent default behavior
  }

  override func mouseDown(with event: NSEvent) {
    // Ignore mouse clicks
    // Don't call super to prevent default behavior
  }

  override func rightMouseDown(with event: NSEvent) {
    // Ignore right clicks
    // Don't call super to prevent default behavior
  }

  override var acceptsFirstResponder: Bool {
    // Don't accept keyboard focus
    return false
  }
}
