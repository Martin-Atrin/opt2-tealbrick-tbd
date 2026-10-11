//
//  SupportChatWebView.swift
//  Dayflow
//
//  In-app support chat backed by PostHog Support ("conversations"). The Swift
//  PostHog SDK has no conversations API, so we host a small local HTML page in
//  a WKWebView that loads posthog-js and drives `posthog.conversations`
//  directly. The page is identified with the native SDK's distinct ID so every
//  ticket lands on the same PostHog person as the app's analytics.
//
//  Bridge:
//    JS → native:  window.webkit.messageHandlers.support.postMessage({event, ...})
//                  events: ready, unavailable, sent, requestDebugLog, openExternal
//    native → JS:  window.__dayflowSupport.receiveDebugLog(text)
//                  window.__dayflowSupport.applyPalette(palette)
//
//  Tickets are keyed by this install's widget session, so the page asks for an
//  email before the first message so we can still reply if the app is closed.
//

import AppKit
import SwiftUI
import WebKit

// MARK: - Palette

/// The handful of colors the chat page needs, as CSS color strings.
struct SupportChatPalette: Equatable {
  let values: [String: String]

  /// Light-mode colors, matching the rest of the app's hard-coded palette.
  static let light = SupportChatPalette(values: [
    "textPrimary": css(Color(hex: "333333")),
    "textSecondary": css(Color(hex: "707070")),
    "textMuted": css(Color(hex: "979797")),
    "accent": css(Color(hex: "F3854B")),
    "userBubbleFill": css(Color(hex: "FFD2B9")),
    "userBubbleBorder": css(Color(hex: "EAD5CD")),
    "userBubbleText": css(Color(hex: "606060")),
    "teamBubbleFill": css(Color.white.opacity(0.9)),
    "teamBubbleBorder": css(Color(hex: "D0D0D0")),
    "inputFill": css(Color.white.opacity(0.9)),
    "inputBorder": css(Color(hex: "E1E1E1")),
    "sendFill": css(Color(hex: "FF9F6F")),
    "sendBorder": css(Color(hex: "F4C8B1")),
    "sendText": css(Color.white),
    "chipFill": css(Color.white.opacity(0.9)),
    "chipBorder": css(Color(hex: "E1E1E1")),
    "chipText": css(Color(hex: "333333")),
    "divider": css(Color(hex: "E7E5E3")),
    "colorScheme": "light",
  ])

  private static func css(_ color: Color) -> String {
    guard let rgb = NSColor(color).usingColorSpace(.sRGB) else { return "rgba(0,0,0,1)" }
    let r = Int((rgb.redComponent * 255).rounded())
    let g = Int((rgb.greenComponent * 255).rounded())
    let b = Int((rgb.blueComponent * 255).rounded())
    let a = String(format: "%.3f", rgb.alphaComponent)
    return "rgba(\(r),\(g),\(b),\(a))"
  }
}

/// Retains the widget session so replies are checked even when Support is closed.
@MainActor
final class SupportChatSession {
  static let shared = SupportChatSession()
  let coordinator = SupportChatWebView.Coordinator(onEvent: { _ in })
  lazy var webView = SupportChatWebView.makeWebView(coordinator: coordinator)
  private var timer: Timer?
  private var supportVisible = false
  private var ready = false
  private let defaults = UserDefaults.standard

  func start() {
    // Private build: no background support widget or PostHog web SDK.
  }

  func setVisible(_ visible: Bool) {
    supportVisible = visible
    updateReading()
  }

  func didBecomeReady() {
    ready = true
    updateReading()
  }

  func didBecomeUnavailable() {
    ready = false
  }

  private func updateReading() {
    let windowVisible = webView.window.map { $0.isVisible && !$0.isMiniaturized } ?? false
    coordinator.send("setReading", supportVisible && NSApp.isActive && windowVisible)
  }

  func receiveReplies(_ body: [String: Any]) {
    let unread = max(0, body["unread"] as? Int ?? 0)
    NotificationBadgeManager.shared.setSupportUnreadCount(unread)
    guard unread > 0, let latestID = body["latestID"] as? String, !latestID.isEmpty else {
      if unread == 0 { NotificationService.shared.clearSupportReplyNotification() }
      return
    }
    let key = "support.lastNotifiedReply"
    guard defaults.string(forKey: key) != latestID else { return }
    defaults.set(latestID, forKey: key)
    NotificationService.shared.notifySupportReply()
  }
}

// MARK: - View

struct SupportChatWebView: NSViewRepresentable {
  enum Event {
    case ready
    case unavailable(reason: String)
  }

  let palette: SupportChatPalette
  let onEvent: (Event) -> Void

  func makeCoordinator() -> Coordinator {
    SupportChatSession.shared.coordinator.onEvent = onEvent
    return SupportChatSession.shared.coordinator
  }

  func makeNSView(context: Context) -> WKWebView {
    SupportChatSession.shared.webView
  }

  static func makeWebView(coordinator: Coordinator) -> WKWebView {
    let configuration = WKWebViewConfiguration()
    configuration.userContentController.add(coordinator, name: "support")
    configuration.userContentController.addUserScript(
      WKUserScript(
        source: Self.configScript(palette: .light),
        injectionTime: .atDocumentStart,
        forMainFrameOnly: true
      )
    )

    let webView = WKWebView(frame: .zero, configuration: configuration)
    webView.navigationDelegate = coordinator
    webView.uiDelegate = coordinator
    webView.setValue(false, forKey: "drawsBackground")
    #if DEBUG
      webView.isInspectable = true
    #endif

    coordinator.webView = webView
    coordinator.lastPalette = .light
    // A real https origin so posthog-js gets working localStorage for ticket persistence.
    webView.loadHTMLString(
      SupportChatPage.html, baseURL: nil)
    return webView
  }

  func updateNSView(_ nsView: WKWebView, context: Context) {
    guard context.coordinator.lastPalette != palette else { return }
    context.coordinator.lastPalette = palette
    context.coordinator.send("applyPalette", palette.values)
  }

  static func dismantleNSView(_ nsView: WKWebView, coordinator: Coordinator) {
    coordinator.onEvent = { _ in }
  }

  /// Everything the page needs before posthog-js loads: keys, distinct ID, and theme.
  private static func configScript(palette: SupportChatPalette) -> String {
    let info = Bundle.main.infoDictionary
    var config: [String: Any] = [
      "token": info?["PHPostHogApiKey"] as? String ?? "",
      "apiHost": info?["PHPostHogHost"] as? String ?? "https://us.i.posthog.com",
      "appVersion": info?["CFBundleShortVersionString"] as? String ?? "",
      "palette": palette.values,
      "language": Bundle.main.preferredLocalizations.first ?? "en",
      "strings": [
        "email": String(localized: "Your email"),
        "emailPlaceholder": String(localized: "so we can reply if you close the app"),
        "messagePlaceholder": String(
          localized: "What's going on? Bugs, ideas, confusion — all welcome."),
        "debug": String(localized: "Attach debug logs"),
        "send": String(localized: "Send"),
        "you": String(localized: "You"),
        "greeting": String(
          localized:
            "Hey there! Found a bug, have an idea, or just confused about something? Drop it here and a real person on the Tealbrick team will get back to you in this chat."
        ),
        "emailRequired": String(localized: "Add your email so we can reply."),
        "unavailable": String(localized: "Support is not available right now."),
        "sent": String(localized: "Sent. Replies show up here and in your inbox."),
        "sendFailed": String(localized: "Couldn't send. Try again."),
        "rateLimited": String(localized: "Slow down a little — try again in a minute."),
      ],
    ]
    if let distinctId = AnalyticsService.shared.currentDistinctId() {
      config["distinctId"] = distinctId
    }
    guard let data = try? JSONSerialization.data(withJSONObject: config),
      let json = String(data: data, encoding: .utf8)
    else { return "" }
    return "window.__dayflowSupportConfig = \(json);"
  }

  // MARK: Coordinator

  @MainActor
  final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate, WKUIDelegate {
    var onEvent: (Event) -> Void
    weak var webView: WKWebView?
    var lastPalette: SupportChatPalette?

    init(onEvent: @escaping (Event) -> Void) {
      self.onEvent = onEvent
    }

    // MARK: JS → native

    nonisolated func userContentController(
      _ userContentController: WKUserContentController,
      didReceive message: WKScriptMessage
    ) {
      guard message.name == "support",
        let body = message.body as? [String: Any],
        let event = body["event"] as? String
      else { return }

      Task { @MainActor in
        self.handle(event: event, body: body)
      }
    }

    private func handle(event: String, body: [String: Any]) {
      switch event {
      case "ready":
        SupportChatSession.shared.didBecomeReady()
        onEvent(.ready)

      case "unavailable":
        SupportChatSession.shared.didBecomeUnavailable()
        let reason = body["reason"] as? String ?? "unknown"
        AnalyticsService.shared.capture("support_chat_unavailable", ["reason": reason])
        onEvent(.unavailable(reason: reason))

      case "replies":
        SupportChatSession.shared.receiveReplies(body)

      case "sent":
        Task { await NotificationService.shared.requestPermission() }
        AnalyticsService.shared.capture(
          "support_message_sent",
          [
            "has_debug_log": body["hasDebugLog"] as? Bool ?? false,
            "new_ticket": body["newTicket"] as? Bool ?? false,
          ]
        )

      case "requestDebugLog":
        Task.detached(priority: .userInitiated) {
          let snapshot = DebugLogSnapshot.makeCurrent()
          await MainActor.run {
            AnalyticsService.shared.capture(
              "support_debug_log_attached", snapshot.analyticsProperties)
            self.send("receiveDebugLog", snapshot.text)
          }
        }

      case "openExternal":
        if let urlString = body["url"] as? String, let url = URL(string: urlString),
          url.scheme == "https" || url.scheme == "http"
        {
          NSWorkspace.shared.open(url)
        }

      default:
        break
      }
    }

    // MARK: native → JS

    func send(_ function: String, _ argument: Any) {
      guard let webView,
        let data = try? JSONSerialization.data(
          withJSONObject: argument, options: [.fragmentsAllowed]),
        let json = String(data: data, encoding: .utf8)
      else { return }
      webView.evaluateJavaScript(
        "window.__dayflowSupport && window.__dayflowSupport.\(function)(\(json))",
        completionHandler: nil
      )
    }

    nonisolated func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
      Task { @MainActor in
        SupportChatSession.shared.didBecomeUnavailable()
      }
    }

    // MARK: Navigation

    // Any link inside the page opens in the real browser.
    nonisolated func webView(
      _ webView: WKWebView,
      decidePolicyFor navigationAction: WKNavigationAction,
      decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
      if navigationAction.navigationType == .linkActivated,
        let url = navigationAction.request.url
      {
        decisionHandler(.cancel)
        DispatchQueue.main.async {
          NSWorkspace.shared.open(url)
        }
        return
      }
      decisionHandler(.allow)
    }

    nonisolated func webView(
      _ webView: WKWebView,
      createWebViewWith configuration: WKWebViewConfiguration,
      for navigationAction: WKNavigationAction,
      windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
      if let url = navigationAction.request.url {
        DispatchQueue.main.async {
          NSWorkspace.shared.open(url)
        }
      }
      return nil
    }

    nonisolated func webView(
      _ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
      withError error: Error
    ) {
      Task { @MainActor in
        SupportChatSession.shared.didBecomeUnavailable()
        self.onEvent(.unavailable(reason: "load_failed"))
      }
    }

    nonisolated func webView(
      _ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error
    ) {
      Task { @MainActor in
        SupportChatSession.shared.didBecomeUnavailable()
        self.onEvent(.unavailable(reason: "load_failed"))
      }
    }
  }
}

// MARK: - Page

/// The chat page itself. Kept as one raw string so the JS needs no escaping.
private enum SupportChatPage {
  static let html = #"""
<html><body><p>Support chat is disabled in this local privacy build.</p></body></html>
"""#
}
