import AppKit
import Foundation
import SwiftUI
import TBDDesign

extension MainView {
  func handleCategoryChange(to category: TimelineCategory, for activity: TimelineActivity) {
    let newName = category.name.trimmingCharacters(in: .whitespacesAndNewlines)

    // Optimistically update the selected activity so the UI reflects the change immediately.
    selectedActivity = activity.withCategory(newName)

    // Ask the timeline list to refresh so other cards stay in sync.
    refreshActivitiesTrigger &+= 1

    guard let recordId = activity.recordId else { return }

    // Persist the change off the main actor to avoid blocking UI interactions.
    Task.detached(priority: .userInitiated) {
      StorageManager.shared.updateTimelineCardCategory(cardId: recordId, category: newName)
    }
  }

  func handleTitleChange(to newTitle: String, for activity: TimelineActivity) {
    let trimmed = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }

    // Optimistically update the selected activity so the UI reflects the change immediately.
    selectedActivity = activity.withTitle(trimmed)

    // Ask the timeline list to refresh so other cards stay in sync.
    refreshActivitiesTrigger &+= 1

    guard let recordId = activity.recordId else { return }

    // Persist the change off the main actor to avoid blocking UI interactions.
    Task.detached(priority: .userInitiated) {
      StorageManager.shared.updateTimelineCardTitle(cardId: recordId, title: trimmed)
    }
  }

  func handleTimelineRating(_ direction: TimelineRatingDirection) {
    guard let activity = selectedActivity else { return }

    feedbackActivitySnapshot = activity
    feedbackDirection = direction
    feedbackMessage = ""
    feedbackShareLogs = true
    feedbackMode = .form

    withAnimation(TBDMotion.spring) {
      feedbackModalVisible = true
    }

  }

  func handleFeedbackSubmit() {
    let trimmed = feedbackMessage.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let activity = feedbackActivitySnapshot,
      let direction = feedbackDirection
    else { return }

    feedbackMessage = ""
    withAnimation(TBDMotion.spring) {
      feedbackMode = .thanks
    }
  }

  func dismissFeedbackModal(animated: Bool = true) {
    guard feedbackModalVisible else { return }

    let reset = {
      feedbackModalVisible = false
      feedbackDirection = nil
      feedbackActivitySnapshot = nil
      feedbackMessage = ""
      feedbackMode = .form
    }

    if animated {
      withAnimation(TBDMotion.spring) {
        reset()
      }
    } else {
      reset()
    }
  }

  func loadWeeklyTrackedMinutes(trigger: String = "unspecified") {
    let requestedWeekRange = timelineWeekRange
    let requestedWeekStartDay = dayString(requestedWeekRange.weekStart)
    timelinePerfLog(
      "weeklyTrackedMinutes.schedule trigger=\(trigger) week=\(requestedWeekStartDay)"
    )

    Task.detached(priority: .userInitiated) {
      let fetchStart = CFAbsoluteTimeGetCurrent()
      let minutes = StorageManager.shared.fetchTotalMinutesTracked(
        from: requestedWeekRange.weekStart,
        to: requestedWeekRange.weekEnd
      )
      let fetchMs = Int((CFAbsoluteTimeGetCurrent() - fetchStart) * 1000)

      await MainActor.run {
        let currentWeekRange = timelineWeekRange
        guard currentWeekRange == requestedWeekRange else {
          let currentWeekStartDay = dayString(currentWeekRange.weekStart)
          timelinePerfLog(
            "weeklyTrackedMinutes.discardStale trigger=\(trigger) requestedWeek=\(requestedWeekStartDay) currentWeek=\(currentWeekStartDay) fetch_ms=\(fetchMs)"
          )
          return
        }

        let commitStart = CFAbsoluteTimeGetCurrent()
        weeklyTrackedMinutes = minutes
        let commitMs = Int((CFAbsoluteTimeGetCurrent() - commitStart) * 1000)
        timelinePerfLog(
          "weeklyTrackedMinutes.complete trigger=\(trigger) week=\(requestedWeekStartDay) minutes=\(Int(minutes.rounded())) fetch_ms=\(fetchMs) commit_ms=\(commitMs)"
        )
      }
    }
  }

  func updateCardsToReviewCount(trigger: String = "unspecified") {
    reviewCountTask?.cancel()
    let timelineDate = timelineDisplayDate(from: selectedDate, now: Date())
    let dayString = DateFormatter.yyyyMMdd.string(from: timelineDate)

    timelinePerfLog("reviewCount.schedule trigger=\(trigger) day=\(dayString)")

    reviewCountTask = Task.detached(priority: .userInitiated) {
      let fetchStart = CFAbsoluteTimeGetCurrent()
      let count = StorageManager.shared.fetchUnreviewedTimelineCardCount(
        forDay: dayString, coverageThreshold: 0.8)
      let hasAnyReviewRating = StorageManager.shared.hasAnyTimelineReviewRating()
      let hasRecentReviewRating = StorageManager.shared.hasReviewRatingInRecentTimelineDays(days: 7)
      let fetchMs = Int((CFAbsoluteTimeGetCurrent() - fetchStart) * 1000)

      guard !Task.isCancelled else { return }

      await MainActor.run {
        let currentDayString = DateFormatter.yyyyMMdd.string(
          from: timelineDisplayDate(from: selectedDate, now: Date())
        )
        guard currentDayString == dayString else {
          timelinePerfLog(
            "reviewCount.discardStale trigger=\(trigger) requestedDay=\(dayString) currentDay=\(currentDayString) fetch_ms=\(fetchMs)"
          )
          return
        }

        let commitStart = CFAbsoluteTimeGetCurrent()
        cardsToReviewCount = count
        hasAnyTimelineReviewRating = hasAnyReviewRating
        hasRecentTimelineReviewRating = hasRecentReviewRating
        let commitMs = Int((CFAbsoluteTimeGetCurrent() - commitStart) * 1000)
        timelinePerfLog(
          "reviewCount.complete trigger=\(trigger) day=\(dayString) count=\(count) hasAnyReviewRating=\(hasAnyReviewRating) hasRecentReviewRating=\(hasRecentReviewRating) fetch_ms=\(fetchMs) commit_ms=\(commitMs)"
        )
      }
    }
  }

  func copyTimelineToClipboard() {
    guard copyTimelineState != .copying else { return }

    copyTimelineTask?.cancel()

    withAnimation(TBDMotion.spring) {
      copyTimelineState = .copying
    }

    copyTimelineTask = Task {
      defer {
        Task { @MainActor in
          if copyTimelineState == .copying {
            withAnimation(TBDMotion.spring) {
              copyTimelineState = .idle
            }
          }
          copyTimelineTask = nil
        }
      }

      let clipboardText: String
      let analyticsProps: [String: Any]

      switch timelineMode {
      case .day:
        let timelineDate = timelineDisplayDate(from: selectedDate, now: Date())
        let day = dayString(timelineDate)
        let cards = StorageManager.shared.fetchTimelineCards(forDay: day)
        clipboardText = TimelineClipboardFormatter.makeClipboardText(
          for: timelineDate,
          cards: cards
        )
        analyticsProps = [
          "timeline_mode": timelineMode.rawValue,
          "timeline_day": day,
          "activity_count": cards.count,
        ]

      case .week:
        let weekRange = timelineWeekRange
        let cards = StorageManager.shared.fetchTimelineCardsByTimeRange(
          from: weekRange.weekStart,
          to: weekRange.weekEnd
        )
        clipboardText = TimelineClipboardFormatter.makeClipboardText(
          for: weekRange,
          cards: cards
        )
        analyticsProps = [
          "timeline_mode": timelineMode.rawValue,
          "week_start": dayString(weekRange.weekStart),
          "week_end": dayString(weekRange.weekEnd),
          "activity_count": cards.count,
        ]
      }

      guard !Task.isCancelled else { return }

      await MainActor.run {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(clipboardText, forType: .string)

        withAnimation(TBDMotion.spring) {
          copyTimelineState = .copied
        }
      }


      try? await Task.sleep(nanoseconds: 2_000_000_000)
      guard !Task.isCancelled else { return }

      await MainActor.run {
        withAnimation(TBDMotion.spring) {
          copyTimelineState = .idle
        }
      }
    }
  }

  func handleTimelineDelete() {
    guard let activity = selectedActivity,
      let recordId = activity.recordId
    else { return }

    deleteTimelineTask?.cancel()
    let selectedActivityId = activity.id
    let selectedDay = dayString(selectedDate)

    var requestedProps: [String: Any] = [
      "timeline_selected_day": selectedDay,
      "activity_record_id": Int(recordId),
      "activity_title": activity.title,
      "activity_has_video_summary": activity.videoSummaryURL != nil,
    ]
    if let batchId = activity.batchId {
      requestedProps["activity_batch_id"] = Int(batchId)
    }

    deleteTimelineTask = Task.detached(priority: .userInitiated) {
      defer {
        Task { @MainActor in
          deleteTimelineTask = nil
        }
      }

      let deletedVideoPath = StorageManager.shared.deleteTimelineCard(recordId: recordId)
      guard !Task.isCancelled else { return }

      if let deletedVideoPath {
        if let fileURL = URL(string: deletedVideoPath), fileURL.isFileURL {
          try? FileManager.default.removeItem(at: fileURL)
        } else {
          try? FileManager.default.removeItem(atPath: deletedVideoPath)
        }
      }

      await MainActor.run {
        if selectedActivity?.id == selectedActivityId {
          clearTimelineSelection()
        }
        refreshActivitiesTrigger &+= 1
      }

      if let batchId = activity.batchId {
      }
    }
  }

}
