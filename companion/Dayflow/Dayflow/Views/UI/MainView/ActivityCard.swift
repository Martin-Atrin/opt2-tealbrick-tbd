import AppKit
import Foundation
import ImageIO
import TBDDesign
import QuartzCore
import SwiftUI

struct ActivityCard: View {
  let activity: TimelineActivity?
  var maxHeight: CGFloat? = nil
  var scrollSummary: Bool = false
  var hasAnyActivities: Bool = true
  var onCategoryChange: ((TimelineCategory, TimelineActivity) -> Void)? = nil
  var onTitleChange: ((String, TimelineActivity) -> Void)? = nil
  var onNavigateToCategoryEditor: (() -> Void)? = nil
  var onRetryBatchCompleted: ((Int64) -> Void)? = nil
  @EnvironmentObject private var appState: AppState
  @EnvironmentObject private var categoryStore: CategoryStore
  @EnvironmentObject private var retryCoordinator: RetryCoordinator
  @AppStorage(TimelapsePreferences.saveAllTimelapsesToDiskKey) private var saveAllTimelapsesToDisk =
    false

  @State private var showCategoryPicker = false
  @State private var isEditingTitle = false
  @State private var draftTitle = ""
  @State private var isHoveringTitle = false
  @FocusState private var titleFieldFocused: Bool
  @State private var isPreparingSlideshow = false
  @State private var slideshowError: String?
  @State private var slideshowRequestID = 0
  @State private var timelapsePreviewThumbnail: NSImage?
  @State private var timelapsePreviewRequestID = 0
  @State private var showSlideshowPlayer = false
  @State private var slideshowScreenshots: [Screenshot] = []
  @State private var slideshowTitle: String?
  @State private var slideshowStartTime: Date?
  @State private var slideshowEndTime: Date?

  private let timeFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.timeStyle = .short
    return formatter
  }()

  var body: some View {
    if let activity = activity {
      ZStack(alignment: .top) {
        activityDetails(for: activity)
          .padding(16)
          .allowsHitTesting(!showCategoryPicker)
          .id(activity.id)
          .transition(
            .blurReplace.animation(
              TBDMotion.quick
            )
          )

        if showCategoryPicker && !isFailedCard(activity) {
          CategoryPickerOverlay(
            categories: categoryStore.categories,
            currentCategoryName: activity.category,
            onSelect: { selectedCategory in
              commitCategorySelection(selectedCategory, for: activity)
            },
            onNavigateToEditor: {
              withAnimation(TBDMotion.spring) {
                showCategoryPicker = false
              }
              onNavigateToCategoryEditor?()
            },
            onDismiss: {
              withAnimation(TBDMotion.spring) {
                showCategoryPicker = false
              }
            }
          )
          .transition(
            .asymmetric(
              insertion: .move(edge: .top).combined(with: .opacity)
                .animation(TBDMotion.spring),
              removal: .move(edge: .top).combined(with: .opacity)
                .animation(TBDMotion.standard)
            )
          )
          .zIndex(1)
        }
      }
      .if(maxHeight != nil) { view in
        view.frame(maxHeight: maxHeight!)
      }
      .onChange(of: activity.id) {
        showCategoryPicker = false
        isEditingTitle = false
        isHoveringTitle = false
        isPreparingSlideshow = false
        slideshowError = nil
        slideshowRequestID &+= 1
        timelapsePreviewThumbnail = nil
        timelapsePreviewRequestID &+= 1
        slideshowScreenshots = []
        slideshowTitle = nil
        slideshowStartTime = nil
        slideshowEndTime = nil
        showSlideshowPlayer = false
      }
      .sheet(
        isPresented: $showSlideshowPlayer,
        onDismiss: {
          slideshowScreenshots = []
          slideshowTitle = nil
          slideshowStartTime = nil
          slideshowEndTime = nil
        }
      ) {
        if !slideshowScreenshots.isEmpty {
          ScreenshotSlideshowModal(
            screenshots: slideshowScreenshots,
            title: slideshowTitle,
            startTime: slideshowStartTime,
            endTime: slideshowEndTime
          )
        }
      }
    } else {
      // Empty state
      VStack(spacing: 10) {
        Spacer()
        if hasAnyActivities {
          Text("Select an activity to view details")
            .font(TBDFonts.nunito(TBDKit.textLabel, TBDKit.weightBody))
            .foregroundStyle(TBDColor.muted)
        } else {
          if appState.isRecording {
            VStack(spacing: 6) {
              Text("No cards yet")
                .font(TBDFonts.nunito(TBDKit.textControl, TBDKit.weightNav))
                .foregroundStyle(TBDColor.inkSoft)
              Text(
                "Cards are generated about every 15 minutes. If Tealbrick is on and no cards show up within 30 minutes, please report a bug."
              )
              .font(TBDFonts.nunito(TBDKit.textHint, TBDKit.weightBody))
              .foregroundStyle(TBDColor.muted)
              .multilineTextAlignment(.center)
              .padding(.horizontal, 16)
            }
          } else {
            VStack(spacing: 6) {
              Text("Recording is off")
                .font(TBDFonts.nunito(TBDKit.textControl, TBDKit.weightNav))
                .foregroundStyle(TBDColor.inkSoft)
              Text("Tealbrick recording is currently turned off, so cards aren’t being produced.")
                .font(TBDFonts.nunito(TBDKit.textHint, TBDKit.weightBody))
                .foregroundStyle(TBDColor.muted)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 16)
            }
          }
        }
        Spacer()
      }
      .padding(16)
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .if(maxHeight != nil) { view in
        view.frame(maxHeight: maxHeight!)
      }
    }
  }

  @ViewBuilder
  private func activityDetails(for activity: TimelineActivity) -> some View {
    VStack(alignment: .leading, spacing: 16) {
      // Header
      HStack(alignment: .center) {
        VStack(alignment: .leading, spacing: 6) {
          titleView(for: activity)

          HStack(alignment: .center, spacing: 6) {
            Text(
              "\(timeFormatter.string(from: activity.startTime)) - \(timeFormatter.string(from: activity.endTime))"
            )
            .font(
              TBDFonts.nunito(TBDKit.textHint, TBDKit.weightBody)
            )
            .foregroundStyle(TBDColor.inkSoft)
            .lineLimit(1)
            .padding(.horizontal, TBDKit.s2)
            .padding(.vertical, TBDKit.s1)
            .background(TBDColor.tile, in: TBDBrickShape())
            .overlay(TBDBrickShape().strokeBorder(TBDColor.line, lineWidth: TBDKit.hair))

            Spacer(minLength: 6)

            HStack(spacing: 6) {
              if let badge = categoryBadge(for: activity.category) {
                HStack(spacing: 6) {
                  Circle()
                    .fill(badge.indicator)
                    .frame(width: 6, height: 6)

                  Text(badge.name)
                    .font(TBDFonts.nunito(TBDKit.textHint, TBDKit.weightBody))
                    .foregroundStyle(TBDColor.inkSoft)
                    .lineLimit(1)
                }
                .padding(.horizontal, TBDKit.s2)
                .padding(.vertical, TBDKit.s1)
                .background(TBDColor.tile, in: Capsule())
                .tbdPillEdge(TBDColor.line)
              }

              if !isFailedCard(activity) {
                CategoryEditCircleButton(
                  action: {
                    withAnimation(TBDMotion.spring) {
                      showCategoryPicker.toggle()
                    }
                  },
                  diameter: 24,
                  accessibilityLabel: String(localized: "Change category")
                )
              }
            }
          }
        }

        Spacer()

        // Retry button centered between title and time (only for failed cards)
        if isFailedCard(activity) {
          retryButtonInline(for: activity)
        }
      }

      // Error message (if retry failed)
      if isFailedCard(activity), let statusLine = retryCoordinator.statusLine(for: activity.batchId)
      {
        Text(statusLine)
          .font(TBDFonts.nunito(11, TBDKit.weightBody))
          .foregroundStyle(TBDColor.muted)
          .lineLimit(1)
      }

      if !isFailedCard(activity) {
        if saveAllTimelapsesToDisk, let videoURL = activity.videoSummaryURL {
          VideoThumbnailView(
            videoURL: videoURL,
            title: activity.title,
            startTime: activity.startTime,
            endTime: activity.endTime
          )
          .id(videoURL)
          .frame(height: 200)
        } else {
          // Timelapse thumbnail (slideshow pipeline)
          timelapsePreviewView(for: activity)
        }
      }

      // Summary section (scrolls internally when constrained)
      Group {
        if scrollSummary {
          ScrollView(.vertical, showsIndicators: false) {
            summaryContent(for: activity)
              .frame(maxWidth: .infinity, alignment: .topLeading)
              .onScrollStart(panelName: "activity_card") { direction in
              }
          }
          .id(activity.id)  // Reset scroll position whenever the selected activity changes
          .frame(maxWidth: .infinity)
          .frame(maxHeight: .infinity, alignment: .topLeading)
        } else {
          summaryContent(for: activity)
        }
      }
    }
  }

  @ViewBuilder
  private func titleView(for activity: TimelineActivity) -> some View {
    if isEditingTitle {
      TextField("Title", text: $draftTitle)
        .textFieldStyle(.plain)
        .font(
          TBDFonts.nunito(TBDKit.textBody, TBDKit.weightNav)
        )
        .foregroundStyle(TBDColor.ink)
        .focused($titleFieldFocused)
        .onSubmit { commitTitleEdit(for: activity) }
        .onExitCommand { isEditingTitle = false }
        .onChange(of: titleFieldFocused) {
          // Losing focus commits, matching Finder's rename behavior.
          if !titleFieldFocused && isEditingTitle {
            commitTitleEdit(for: activity)
          }
        }
    } else {
      HStack(alignment: .center, spacing: 6) {
        Text(isFailedCard(activity) ? String(localized: "Processing failed") : activity.title)
          .font(
            TBDFonts.nunito(TBDKit.textBody, TBDKit.weightNav)
          )
          .foregroundStyle(TBDColor.ink)
          .onTapGesture { startTitleEdit(for: activity) }

        if isHoveringTitle && !isFailedCard(activity) {
          CategoryEditCircleButton(
            action: { startTitleEdit(for: activity) },
            diameter: 24,
            accessibilityLabel: String(localized: "Edit title")
          )
        }
      }
      .onHover { hovering in
        isHoveringTitle = hovering
      }
    }
  }

  private func startTitleEdit(for activity: TimelineActivity) {
    guard !isFailedCard(activity) else { return }
    draftTitle = activity.title
    isEditingTitle = true
    titleFieldFocused = true
  }

  private func commitTitleEdit(for activity: TimelineActivity) {
    isEditingTitle = false
    let trimmed = draftTitle.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, trimmed != activity.title else { return }
    onTitleChange?(trimmed, activity)
  }

  @ViewBuilder
  private func summaryContent(for activity: TimelineActivity) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      VStack(alignment: .leading, spacing: 3) {
        Text("Summary")
          .font(
            TBDFonts.nunito(TBDKit.textHint, TBDKit.weightNav)
          )
          .foregroundStyle(TBDColor.muted)

        renderMarkdownText(activity.summary)
          .font(
            TBDFonts.nunito(TBDKit.textHint, TBDKit.weightBody)
          )
          .foregroundStyle(TBDColor.ink)
          .lineLimit(nil)
          .fixedSize(horizontal: false, vertical: true)
          .textSelection(.enabled)
      }

      if !activity.detailedSummary.isEmpty && activity.detailedSummary != activity.summary {
        VStack(alignment: .leading, spacing: 3) {
          Text("Detailed summary")
            .font(
              TBDFonts.nunito(TBDKit.textHint, TBDKit.weightNav)
            )
            .foregroundStyle(TBDColor.muted)

          renderMarkdownText(formattedDetailedSummary(activity.detailedSummary))
            .font(
              TBDFonts.nunito(TBDKit.textHint, TBDKit.weightBody)
            )
            .foregroundStyle(TBDColor.ink)
            .lineLimit(nil)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
        }
      }
    }
  }

  private func renderMarkdownText(_ content: String) -> Text {
    let options = AttributedString.MarkdownParsingOptions(
      interpretedSyntax: .inlineOnlyPreservingWhitespace
    )
    if let parsed = try? AttributedString(markdown: content, options: options) {
      return Text(parsed)
    }
    return Text(content)
  }

  private func formattedDetailedSummary(_ content: String) -> String {
    if content.contains("\n") || content.contains("\r") {
      return content
    }

    let pattern = #"\b\d{1,2}:\d{2}\s?(?:AM|PM)\s*-\s*\d{1,2}:\d{2}\s?(?:AM|PM)\b"#
    guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
      return content
    }

    let range = NSRange(content.startIndex..., in: content)
    let matches = regex.matches(in: content, range: range)
    guard matches.count > 1 else {
      return content
    }

    let mutable = NSMutableString(string: content)
    for idx in stride(from: matches.count - 1, through: 1, by: -1) {
      mutable.insert("\n", at: matches[idx].range.location)
    }
    return mutable as String
  }

  private func categoryBadge(for raw: String) -> (name: String, indicator: Color)? {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }

    let normalized = trimmed.lowercased()
    let categories = categoryStore.categories
    let matched = categories.first {
      $0.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == normalized
    }

    let category =
      matched
      ?? CategoryPersistence.defaultCategories.first {
        $0.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == normalized
      }

    guard let resolvedCategory = category else { return nil }

    let nsColor = NSColor(hex: resolvedCategory.colorHex) ?? NSColor(TBDColor.toneTeal)
    return (name: resolvedCategory.name, indicator: Color(nsColor: nsColor))
  }

  // MARK: - Retry Functionality

  private func isFailedCard(_ activity: TimelineActivity) -> Bool {
    return activity.title == "Processing failed"
  }

  @ViewBuilder
  private func retryButtonInline(for activity: TimelineActivity) -> some View {
    let isProcessing = retryCoordinator.isActive(batchId: activity.batchId)
    let isDisabled = retryCoordinator.isRunning

    if isProcessing {
      // Processing state - beige pill with spinner
      HStack(alignment: .center, spacing: 4) {
        ProgressView()
          .scaleEffect(0.7)
          .frame(width: 16, height: 16)

        Text("Processing")
          .font(TBDFonts.nunito(TBDKit.textHint, TBDKit.weightBody))
          .foregroundStyle(TBDColor.inkSoft)
          .lineLimit(1)
      }
      .padding(.horizontal, TBDKit.s3)
      .padding(.vertical, TBDKit.s2)
      .background(TBDColor.plate, in: TBDBrickShape())
      .overlay(TBDBrickShape().strokeBorder(TBDColor.line, lineWidth: TBDKit.hair))
    } else {
      // Retry button - square brick primary button, matching the "Resume" CTA
      Button(action: { handleRetry(for: activity) }) {
        HStack(alignment: .center, spacing: 4) {
          Text("Retry")
            .font(TBDFonts.nunito(TBDKit.textHint, TBDKit.weightNav))
          Image(systemName: "arrow.clockwise")
            .font(TBDFonts.symbol(13, TBDKit.weightNav))
        }
      }
      .buttonStyle(TBDButtonStyle(.primary))
      .disabled(isDisabled)
      .opacity(isDisabled ? 0.6 : 1)
    }
  }

  private func handleRetry(for activity: TimelineActivity) {
    let dayString = activity.startTime.getDayInfoFor4AMBoundary().dayString
    retryCoordinator.startRetry(for: dayString) { batchId in
      onRetryBatchCompleted?(batchId)
    }
  }

  private func commitCategorySelection(_ category: TimelineCategory, for activity: TimelineActivity)
  {
    let normalizedCurrent = activity.category.trimmingCharacters(in: .whitespacesAndNewlines)
      .lowercased()
    let normalizedNew = category.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

    withAnimation(TBDMotion.spring) {
      showCategoryPicker = false
    }

    guard normalizedCurrent != normalizedNew else { return }
    onCategoryChange?(category, activity)
  }

  @ViewBuilder
  private func timelapsePreviewView(for activity: TimelineActivity) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      GeometryReader { geometry in
        ZStack {
          if let thumbnail = timelapsePreviewThumbnail {
            Image(nsImage: thumbnail)
              .resizable()
              .aspectRatio(contentMode: .fill)
              .scaleEffect(1.3)
              .frame(width: geometry.size.width, height: geometry.size.height)
              .clipped()
          } else {
            TBDBrickShape()
              .fill(TBDColor.plate)
              .overlay(
                Image(systemName: "photo")
                  .font(TBDFonts.symbol(18, TBDKit.weightNav))
                  .foregroundStyle(TBDColor.inkSoft)
              )
          }

          if isPreparingSlideshow {
            ZStack {
              TBDBrickShape()
                .fill(TBDColor.overlayFill.opacity(0.55))

              HStack(spacing: 8) {
                ProgressView()
                  .scaleEffect(0.8)
                Text("Preparing timelapse...")
                  .font(TBDFonts.nunito(TBDKit.textHint, TBDKit.weightNav))
                  .foregroundStyle(TBDColor.overlayOn)
              }
            }
          } else {
            ZStack {
              Circle()
                .strokeBorder(TBDColor.overlayOn.opacity(0.9), lineWidth: 2)
                .frame(width: 64, height: 64)
                .background(Circle().fill(TBDColor.overlayFill.opacity(0.6)))
              Image(systemName: "play.fill")
                .foregroundStyle(TBDColor.overlayOn)
                .font(TBDFonts.symbol(24, TBDKit.weightLabel))
            }
          }
        }
        .contentShape(Rectangle())
        .onTapGesture {
          guard let cardId = activity.recordId else {
            slideshowError = String(localized: "This activity cannot load a slideshow.")
            return
          }
          openSlideshow(for: activity, cardId: cardId)
        }
        .pointingHandCursorOnHover(reassertOnPressEnd: true)
        .id(activity.id)
        .onAppear {
          loadTimelapsePreviewThumbnail(for: activity, size: geometry.size)
        }
        .onChange(of: geometry.size.width) {
          loadTimelapsePreviewThumbnail(for: activity, size: geometry.size)
        }
      }
      .frame(height: 200)

      if let errorMessage = slideshowError {
        Text(errorMessage)
          .font(TBDFonts.nunito(11, TBDKit.weightBody))
          .foregroundStyle(TBDColor.brickInk)
      }
    }
  }

  private func openSlideshow(for activity: TimelineActivity, cardId: Int64) {
    guard !isPreparingSlideshow else { return }

    isPreparingSlideshow = true
    slideshowError = nil
    slideshowRequestID &+= 1
    let requestID = slideshowRequestID


    Task {
      do {
        let screenshots = try await ActivityCardTimelapseGenerator.shared.screenshots(
          forCardId: cardId)
        await MainActor.run {
          guard requestID == slideshowRequestID else { return }
          isPreparingSlideshow = false
          slideshowError = nil
          slideshowScreenshots = screenshots
          slideshowTitle = activity.title
          slideshowStartTime = activity.startTime
          slideshowEndTime = activity.endTime
          showSlideshowPlayer = true
        }

      } catch {
        await MainActor.run {
          guard requestID == slideshowRequestID else { return }
          isPreparingSlideshow = false
          slideshowError = error.localizedDescription
        }
      }
    }
  }

  private func loadTimelapsePreviewThumbnail(for activity: TimelineActivity, size: CGSize) {
    guard let cardId = activity.recordId else {
      timelapsePreviewThumbnail = nil
      return
    }

    timelapsePreviewRequestID &+= 1
    let requestID = timelapsePreviewRequestID
    let targetSize = CGSize(width: max(1, size.width), height: max(1, size.height))

    Task {
      let screenshot = await ActivityCardTimelapseGenerator.shared.middleScreenshot(
        forCardId: cardId)
      await MainActor.run {
        guard requestID == timelapsePreviewRequestID else { return }
        guard let screenshot else {
          timelapsePreviewThumbnail = nil
          return
        }

        ScreenshotThumbnailCache.shared.fetchThumbnail(
          screenshot: screenshot, targetSize: targetSize
        ) { image in
          guard requestID == timelapsePreviewRequestID else { return }
          timelapsePreviewThumbnail = image
        }
      }
    }
  }
}

private enum ActivityCardTimelapseError: LocalizedError {
  case timelineCardMissing
  case noScreenshots

  var errorDescription: String? {
    switch self {
    case .timelineCardMissing:
      return String(localized: "Could not find this activity in storage.")
    case .noScreenshots:
      return String(localized: "No screenshots are available for this activity range.")
    }
  }
}

private actor ActivityCardTimelapseGenerator {
  static let shared = ActivityCardTimelapseGenerator()

  private let storage: any StorageManaging

  init(
    storage: any StorageManaging = StorageManager.shared
  ) {
    self.storage = storage
  }

  func screenshots(forCardId cardId: Int64) throws -> [Screenshot] {
    guard let timelineCard = storage.fetchTimelineCard(byId: cardId) else {
      throw ActivityCardTimelapseError.timelineCardMissing
    }

    let screenshots = storage.fetchScreenshotsInTimeRange(
      startTs: timelineCard.startTs, endTs: timelineCard.endTs)
    guard !screenshots.isEmpty else {
      throw ActivityCardTimelapseError.noScreenshots
    }
    return screenshots
  }

  func middleScreenshot(forCardId cardId: Int64) -> Screenshot? {
    guard let screenshots = try? screenshots(forCardId: cardId), !screenshots.isEmpty else {
      return nil
    }
    return screenshots[screenshots.count / 2]
  }
}
