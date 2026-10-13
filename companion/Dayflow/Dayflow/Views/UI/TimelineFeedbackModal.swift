//
//  TimelineFeedbackModal.swift
//  Dayflow
//
//  Feedback card shown after rating a timeline summary.
//

import TBDDesign
import SwiftUI

enum TimelineFeedbackMode {
  case form
  case thanks
}

struct FeedbackModalContent {
  let accessibilityLabel: String
  let accessibilityHint: String
  let formTitle: String
  let formSubtitle: String
  let placeholder: String
  let shareLogsLabel: String
  let submitButtonTitle: String
  let thanksTitle: String
  let thanksBody: String?
  let illustrationImageName: String?
  let illustrationAccessibilityLabel: String?

  static let timeline = FeedbackModalContent(
    accessibilityLabel: String(localized: "Timeline feedback form"),
    accessibilityHint: String(localized: "Share more context after rating this summary."),
    formTitle: String(localized: "Thank you!"),
    formSubtitle: String(localized: "Tell us more about your feedback"),
    placeholder:
      String(
        localized:
          "I don't have access to your timeline (privacy first!), so your feedback here helps improve the quality of Tealbrick for everyone."
      ),
    shareLogsLabel: String(
      localized: "I'd like to share this log to the developer to help improve the product."),
    submitButtonTitle: String(localized: "Submit"),
    thanksTitle: String(localized: "Thank you for your feedback!"),
    thanksBody:
      String(
        localized:
          "If you find that your activities are summarized inaccurately, try editing the descriptions of your categories to improve Tealbrick's accuracy."
      ),
    illustrationImageName: "CategoryEditUI",
    illustrationAccessibilityLabel: String(localized: "Illustration showing how to edit categories")
  )

  static let chat = FeedbackModalContent(
    accessibilityLabel: String(localized: "Chat feedback form"),
    accessibilityHint: String(localized: "Share more context after rating this chat answer."),
    formTitle: String(localized: "Thanks for the report"),
    formSubtitle: String(localized: "Tell us what went wrong"),
    placeholder:
      String(
        localized:
          "What was wrong with this answer? If you're comfortable, include what you expected instead."
      ),
    shareLogsLabel:
      String(
        localized:
          "I'd like to share this answer and related logs with the developer to help improve the product."
      ),
    submitButtonTitle: String(localized: "Submit"),
    thanksTitle: String(localized: "Thank you for your feedback!"),
    thanksBody: String(localized: "Your note will help improve future Dashboard answers."),
    illustrationImageName: nil,
    illustrationAccessibilityLabel: nil
  )
}

struct TimelineFeedbackModal: View {
  @Binding var message: String
  @Binding var shareLogs: Bool
  let direction: TimelineRatingDirection
  let mode: TimelineFeedbackMode
  let content: FeedbackModalContent
  let onSubmit: () -> Void
  let onClose: () -> Void

  @FocusState private var isEditorFocused: Bool

  var body: some View {
    ZStack(alignment: .topTrailing) {
      modalCard

      Button(action: onClose) {
        Image(systemName: "xmark")
          .font(TBDFonts.symbol(12.5, TBDKit.weightNav))
      }
      .buttonStyle(TBDButtonStyle(.icon))
      .accessibilityLabel(Text("Close"))
      .pointingHandCursor()
      .offset(x: -4, y: 4)
    }
    .accessibilityElement(children: .contain)
    .accessibilityLabel(Text(content.accessibilityLabel))
    .accessibilityHint(Text(content.accessibilityHint))
  }

  @ViewBuilder
  private var modalCard: some View {
    VStack(spacing: mode == .form ? 20 : 24) {
      switch mode {
      case .form:
        formContent
      case .thanks:
        thanksContent
      }
    }
    .padding(24)
    .frame(width: 286)
    // Floating card: tile, hair ring and the one float shadow.
    .tbdFloating()
  }

  private var primaryText: Color { TBDColor.ink }

  private var formContent: some View {
    VStack(spacing: 16) {
      VStack(spacing: 12) {
        Text(content.formTitle)
          .font(TBDFonts.nunito(TBDKit.textLede, TBDKit.weightNav))
          .foregroundStyle(primaryText)
          .multilineTextAlignment(.center)

        Text(content.formSubtitle)
          .font(TBDFonts.nunito(TBDKit.textControl, TBDKit.weightBody))
          .foregroundStyle(primaryText)
          .multilineTextAlignment(.center)
      }

      VStack(spacing: 8) {
        ZStack(alignment: .topLeading) {
          TextEditor(text: $message)
            .font(TBDFonts.nunito(TBDKit.textHint, TBDKit.weightBody))
            .foregroundStyle(primaryText)
            .padding(.horizontal, 6)
            .padding(.vertical, 8)
            .background(TBDColor.fieldFill, in: TBDBrickShape())
            .frame(height: 90)
            .overlay(
              TBDBrickShape()
                .strokeBorder(TBDColor.fieldEdge, lineWidth: TBDKit.hair)
            )
            .tbdFocusRing(isEditorFocused, offset: TBDKit.focusOffsetTight)
            .background(ThinScrollerInstaller())
            .focused($isEditorFocused)
            .onAppear {
              DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                isEditorFocused = true
              }
            }
            .scrollContentBackground(.hidden)

          if message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            Text(content.placeholder)
              .font(TBDFonts.nunito(TBDKit.textHint, TBDKit.weightBody))
              .foregroundStyle(TBDColor.fieldPlaceholder)
              .padding(.horizontal, 12)
              .padding(.vertical, 12)
          }
        }

        Toggle(isOn: $shareLogs) {
          Text(content.shareLogsLabel)
            .font(TBDFonts.nunito(TBDKit.textHint, TBDKit.weightBody))
            .foregroundStyle(TBDColor.ink)
            .fixedSize(horizontal: false, vertical: true)
        }
        .toggleStyle(TBDSwitchStyle())
      }

      Button(action: onSubmit) {
        Text(content.submitButtonTitle)
          .frame(maxWidth: .infinity)
      }
      .buttonStyle(TBDButtonStyle(.primary))
      .pointingHandCursor()
    }
  }

  private var thanksContent: some View {
    VStack(spacing: 20) {
      Text(content.thanksTitle)
        .font(TBDFonts.nunito(TBDKit.textLede, TBDKit.weightNav))
        .foregroundStyle(primaryText)
        .multilineTextAlignment(.center)
        .padding(.bottom, 4)

      VStack(alignment: .leading, spacing: 12) {
        if let thanksBody = content.thanksBody {
          Text(thanksBody)
            .font(TBDFonts.nunito(TBDKit.textHint, TBDKit.weightBody))
            .foregroundStyle(primaryText)
            .multilineTextAlignment(.leading)
        }

        if let illustrationImageName = content.illustrationImageName {
          feedbackIllustration(
            imageName: illustrationImageName,
            accessibilityLabel: content.illustrationAccessibilityLabel
          )
        }
      }
    }
  }
}

extension TimelineFeedbackModal {
  private func feedbackIllustration(imageName: String, accessibilityLabel: String?) -> some View {
    Image(imageName)
      .resizable()
      .scaledToFit()
      .frame(maxWidth: .infinity)
      .frame(height: 140)
      .clipShape(TBDBrickShape())
      .overlay(
        TBDBrickShape()
          .strokeBorder(TBDColor.line, lineWidth: TBDKit.hair)
      )
      .accessibilityLabel(Text(accessibilityLabel ?? String(localized: "Feedback illustration")))
  }
}

// MARK: - Thin scroll bar for the feedback text editor

/// Draws the vertical scroller knob at half the standard width.
private final class ThinFeedbackScroller: NSScroller {
  override func drawKnobSlot(in slotRect: NSRect, highlight flag: Bool) {}

  override func drawKnob() {
    let knob = rect(for: .knob)
    guard knob.width > 0, knob.height > 0 else { return }
    let width = knob.width * 0.5
    let knobRect = NSRect(x: knob.midX - width / 2, y: knob.minY, width: width, height: knob.height)
    NSColor(TBDColor.scrollThumb).setFill()
    NSBezierPath(roundedRect: knobRect, xRadius: width / 2, yRadius: width / 2).fill()
  }
}

/// Finds the `TextEditor`'s enclosing scroll view and swaps in the thin scroller.
private struct ThinScrollerInstaller: NSViewRepresentable {
  func makeNSView(context: Context) -> NSView {
    let view = NSView()
    DispatchQueue.main.async { install(near: view) }
    return view
  }

  func updateNSView(_ nsView: NSView, context: Context) {
    DispatchQueue.main.async { install(near: nsView) }
  }

  private func install(near view: NSView) {
    var ancestor = view.superview
    var hops = 0
    while let current = ancestor, hops < 6 {
      if let scrollView = textEditorScrollView(in: current) {
        if !(scrollView.verticalScroller is ThinFeedbackScroller) {
          scrollView.verticalScroller = ThinFeedbackScroller()
        }
        return
      }
      ancestor = current.superview
      hops += 1
    }
  }

  private func textEditorScrollView(in view: NSView) -> NSScrollView? {
    if let scrollView = view as? NSScrollView, scrollView.documentView is NSTextView {
      return scrollView
    }
    for subview in view.subviews {
      if let found = textEditorScrollView(in: subview) { return found }
    }
    return nil
  }
}

#Preview {
  TimelineFeedbackModal(
    message: .constant(""),
    shareLogs: .constant(true),
    direction: .up,
    mode: .form,
    content: .timeline,
    onSubmit: {},
    onClose: {}
  )
  .padding()
  .background(TBDColor.paper)

  TimelineFeedbackModal(
    message: .constant(""),
    shareLogs: .constant(true),
    direction: .up,
    mode: .thanks,
    content: .timeline,
    onSubmit: {},
    onClose: {}
  )
  .padding()
  .background(TBDColor.paper)
}
