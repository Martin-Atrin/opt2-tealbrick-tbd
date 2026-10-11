import SwiftUI
import TBDDesign
import WebKit

/// The standalone miniapp owns its data and authentication; no native credentials are injected.
struct ReviewCardsView: View {
  @AppStorage("tealbrickReviewMiniappURL") private var savedURL = ""
  @Environment(\.dayflowTheme) private var theme
  @State private var input = ""
  @State private var error: String?
  @State private var reloadID = UUID()

  static func validatedURL(_ text: String) -> URL? {
    guard let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
      let host = url.host, !host.isEmpty, url.user == nil, url.password == nil,
      url.scheme == "https" || (url.scheme == "http" && ["localhost", "127.0.0.1", "[::1]", "::1"].contains(host))
    else { return nil }
    return url
  }

  var body: some View {
    VStack(alignment: .leading, spacing: TBDTokens.Space.lg) {
      TBDPageHeader("Review", label: "Companion · Review miniapp") {
        if let url = Self.validatedURL(savedURL) {
          HStack(spacing: TBDTokens.Space.sm) {
            Button { error = nil; reloadID = UUID() } label: { Image(systemName: "arrow.clockwise") }
              .buttonStyle(TBDButtonStyle(.icon)).help("Reload")
            Button("Open in browser") { NSWorkspace.shared.open(url) }.buttonStyle(TBDButtonStyle(.secondary))
            Button("Change URL") { input = savedURL; savedURL = ""; error = nil }.buttonStyle(TBDButtonStyle(.quiet))
          }
        }
      }
      if let url = Self.validatedURL(savedURL) {
        if let error { Text(error).foregroundStyle(TBDTokens.alert).textSelection(.enabled) }
        ReviewMiniappWebView(url: url, error: $error)
          .id(reloadID)
          .frame(maxWidth: .infinity, maxHeight: .infinity)
          .overlay(RoundedRectangle(cornerRadius: TBDTokens.Radius.base).strokeBorder(TBDTokens.border, lineWidth: TBDTokens.Stroke.hairline))
      } else {
        HStack(alignment: .top, spacing: TBDTokens.Space.xl) {
          VStack(alignment: .leading, spacing: TBDTokens.Space.md) {
            TBDLabel("Connect")
            Text("Connect your review miniapp")
              .font(TBDTokens.Typography.display).tracking(TBDTokens.Typography.displayTracking).foregroundStyle(TBDTokens.ink)
            Text("Paste the address of your Review miniapp. It runs on your own hosting and keeps its own data and sign-in.")
              .font(TBDTokens.Typography.body).foregroundStyle(TBDTokens.muted).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: TBDTokens.Space.sm) {
              TextField("https://your-miniapp.example", text: $input)
                .tbdField()
                .onSubmit(connect)
                .accessibilityLabel("Review miniapp URL")
              Button("Connect", action: connect).buttonStyle(TBDButtonStyle(.primary))
            }
            if let error { Text(error).font(TBDTokens.Typography.body).foregroundStyle(TBDTokens.alert) }
            Text("HTTPS, or HTTP on localhost. Nothing connects until you choose Connect.")
              .font(.system(size: 11)).foregroundStyle(TBDTokens.muted)
          }
          .frame(maxWidth: .infinity, alignment: .leading)
          .tbdCard(padding: TBDTokens.Space.xl)
          VStack(alignment: .leading, spacing: TBDTokens.Space.sm) {
            TBDLabel("Don't have one yet?")
            Text("Deploy the Review miniapp from Tealbrick Portal, then paste its address here.")
              .font(TBDTokens.Typography.body).foregroundStyle(TBDTokens.ink).fixedSize(horizontal: false, vertical: true)
            Link(destination: URL(string: "https://portal.tealbrick.com")!) {
              Text("Open Tealbrick Portal →").font(TBDTokens.Typography.control).foregroundStyle(TBDTokens.accent)
            }
          }
          .frame(width: 300, alignment: .leading)
          .tbdCard(padding: TBDTokens.Space.xl)
        }
        Spacer(minLength: 0)
      }
    }
    .padding(.horizontal, 32).padding(.vertical, 24)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
  }

  private func connect() {
    guard let url = Self.validatedURL(input) else {
      error = "Enter a valid HTTPS URL (or HTTP localhost), without embedded credentials."
      return
    }
    error = nil
    savedURL = url.absoluteString
    reloadID = UUID()
  }
}

private struct ReviewMiniappWebView: NSViewRepresentable {
  let url: URL
  @Binding var error: String?

  func makeCoordinator() -> Coordinator { Coordinator(url: url, error: $error) }
  func makeNSView(context: Context) -> WKWebView {
    let configuration = WKWebViewConfiguration()
    let view = WKWebView(frame: .zero, configuration: configuration)
    view.navigationDelegate = context.coordinator
    view.uiDelegate = context.coordinator
    view.load(URLRequest(url: url))
    return view
  }
  func updateNSView(_ view: WKWebView, context: Context) {}
  static func dismantleNSView(_ view: WKWebView, coordinator: Coordinator) {
    view.stopLoading()
    view.navigationDelegate = nil
    view.uiDelegate = nil
  }

  final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
    let url: URL
    var error: Binding<String?>
    init(url: URL, error: Binding<String?>) { self.url = url; self.error = error }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
      guard let target = action.request.url,
            ReviewCardsView.validatedURL(target.absoluteString) != nil else {
        decisionHandler(.cancel); return
      }
      let sameOrigin = target.scheme == url.scheme && target.host == url.host
        && (target.port ?? (target.scheme == "https" ? 443 : 80)) == (url.port ?? (url.scheme == "https" ? 443 : 80))
      if sameOrigin && action.targetFrame != nil { decisionHandler(.allow) }
      else {
        if action.navigationType == .linkActivated { NSWorkspace.shared.open(target) }
        else { error.wrappedValue = "Navigation left the configured miniapp. Open it in your browser to sign in, or check its URL." }
        decisionHandler(.cancel)
      }
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
      self.error.wrappedValue = "Could not load miniapp: \(error.localizedDescription)"
    }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
      self.error.wrappedValue = "Miniapp loading failed: \(error.localizedDescription)"
    }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
      error.wrappedValue = "Miniapp stopped responding. Choose Reload to reconnect."
    }
  }
}
