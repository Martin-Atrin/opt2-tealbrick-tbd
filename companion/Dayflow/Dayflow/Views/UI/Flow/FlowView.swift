// Local demo harness around upstream Dayflow's native session/overlay engine.
// This is not the hosted Flow task manager. No vendor webview is instantiated.
import SwiftUI
import TBDDesign
struct FlowDemoView: View {
  @ObservedObject private var mirror = FlowSessionMirror.shared
  @State private var tasks = "[Demo] Review today's priorities\n[Demo] Draft the proposal\n[Demo] Take a short break"
  var body: some View {
    ZStack(alignment: .bottomLeading) {
      ScrollView {
        VStack(alignment: .leading, spacing: TBDTokens.Space.xxl) {
          TBDPageHeader("Nudge preview", label: "Flow · Local demo")
          Text("Try Tealbrick’s nudges and timers on your own screen. Nothing here detects real distraction or creates tasks.")
            .font(TBDTokens.Typography.body).foregroundStyle(TBDTokens.muted)
          HStack(alignment: .top, spacing: TBDTokens.Space.xl) {
            VStack(alignment: .leading, spacing: TBDTokens.Space.md) {
              HStack { TBDLabel("Demo session"); Spacer(); TBDChip(mirror.snapshot.phase.rawValue.capitalized, color: mirror.snapshot.phase == .idle ? TBDTokens.muted : TBDTokens.accent) }
              TextEditor(text: $tasks).font(.system(size: 13)).scrollContentBackground(.hidden).padding(8).frame(height: 110)
                .background(TBDTokens.canvas)
                .overlay(RoundedRectangle(cornerRadius: TBDTokens.Radius.base).strokeBorder(TBDTokens.border, lineWidth: TBDTokens.Stroke.hairline))
              Text("One demo task per line.").font(.system(size: 11)).foregroundStyle(TBDTokens.muted)
              HStack(spacing: TBDTokens.Space.sm) {
                Button("Start 1-minute demo") { startDemo() }.buttonStyle(TBDButtonStyle(.primary))
                Button("Stop") { mirror.apply(.idle); mirror.debugHideOverlay() }.buttonStyle(TBDButtonStyle(.secondary))
              }
            }.frame(maxWidth: .infinity, alignment: .leading).tbdCard(padding: TBDTokens.Space.xl)
            VStack(alignment: .leading, spacing: TBDTokens.Space.md) {
              TBDLabel("Show a nudge")
              LazyVGrid(columns: [GridItem(.flexible(), spacing: TBDTokens.Space.sm), GridItem(.flexible(), spacing: TBDTokens.Space.sm)], alignment: .leading, spacing: TBDTokens.Space.sm) {
                Button("Side nudge") { mirror.debugNudge(variant: .side) }
                Button("Top nudge") { mirror.debugNudge(variant: .top) }
                Button("Escalated") { mirror.debugNudge(variant: .side, escalated: true) }
                Button("Break") { mirror.debugBreak() }
                Button("Task reminder") { mirror.debugToast("Demo: switch focus to drafting the proposal.") }
                Button("Dismiss") { mirror.debugHideOverlay() }
              }.buttonStyle(TBDButtonStyle(.secondary))
            }.frame(width: 320, alignment: .leading).tbdCard(padding: TBDTokens.Space.xl)
          }
        }
        .padding(.horizontal, 32).padding(.vertical, 24)
        .frame(maxWidth: .infinity, alignment: .leading)
      }
      FlowDebugPanel()
    }
  }
  private func startDemo() {
    var s=FlowNativeSnapshot();s.phase = .active;s.alertStyle = .friendly
    s.sessionStartedAt=Int(Date().timeIntervalSince1970);s.sessionEndsAt=Int(Date().timeIntervalSince1970)+60
    s.goals=tasks.split(separator:"\n").map(String.init)
    s.goalTasks=s.goals?.enumerated().map { FlowGoalTask(id:"local-demo-\($0.offset)", title:$0.element) }
    mirror.apply(s)
  }
}

// Shared task storage/API supplied by the local Tasklist service. No vendor calls.
import AppKit
struct CompanionTask: Identifiable {
  let id: String
  let title: String
  let day: String
  let status: String
  let start: String
  let end: String
  let minutes: Int
  let notes: String
  let subtasks: [String]
}
@MainActor final class CompanionPlanner: ObservableObject {
  static let shared = CompanionPlanner()
  @Published var tasks: [CompanionTask] = []
  @Published var alerts: [[String: Any]] = []
  @Published var focus: [String: Any] = [:]
  @Published var clock = Date()
  @Published var connection = "Connecting to local task service…"
  private var timer: Timer?
  private var ownedSession = false
  private var lastNudge: [String: Date] = [:]
  private init() {
    refresh()
    timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { _ in
      Task { @MainActor in CompanionPlanner.shared.refresh() }
    }
  }
  func request(_ path: String, method: String = "GET", body: [String: Any]? = nil) async throws -> Any {
    let tokenURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Tasklist/api-token")
    let token = try String(contentsOf: tokenURL, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
    var req = URLRequest(url: URL(string: "http://127.0.0.1:18770/api" + path)!)
    req.httpMethod = method; req.timeoutInterval = 100
    req.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
    if let body { req.httpBody = try JSONSerialization.data(withJSONObject: body) }
    let (data, response) = try await URLSession.shared.data(for: req)
    let value = try JSONSerialization.jsonObject(with: data)
    guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode) else {
      throw NSError(domain: "Task service", code: 1, userInfo: [NSLocalizedDescriptionKey: (value as? [String: Any])?["error"] as? String ?? "Task service failed"])
    }
    return value
  }
  func refresh() {
    Task {
      do {
        guard let state = try await request("/state") as? [String: Any] else { return }
        tasks = (state["tasks"] as? [[String: Any]] ?? []).map { t in
          CompanionTask(id: t["id"] as? String ?? "", title: t["title"] as? String ?? "", day: t["day"] as? String ?? "", status: t["status"] as? String ?? "todo", start: t["start_at"] as? String ?? "", end: t["due_at"] as? String ?? "", minutes: t["duration_minutes"] as? Int ?? 0, notes: t["notes"] as? String ?? "", subtasks: (t["subtasks"] as? [[String: Any]] ?? []).map { $0["title"] as? String ?? "" })
        }
        focus = state["focus"] as? [String: Any] ?? [:]
        clock = Date()
        syncObservation()
        let now = Date(); let iso = ISO8601DateFormatter(); iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        alerts = (state["alerts"] as? [[String: Any]] ?? []).filter { a in
          guard a["acknowledged_at"] is NSNull else { return false }
          if let s = a["snoozed_until"] as? String, let until = iso.date(from: s), until > now { return false }
          return true
        }
        let settings = state["settings"] as? [String: Any] ?? [:]
        // New reminders cannot be starved by an older unacknowledged one.
        let eligible = alerts.filter { now.timeIntervalSince(lastNudge[$0["id"] as? String ?? ""] ?? .distantPast) >= Double(settings["repeat_seconds"] as? Int ?? 60) }
          .sorted { (lastNudge[$0["id"] as? String ?? ""] ?? .distantPast) < (lastNudge[$1["id"] as? String ?? ""] ?? .distantPast) }
        if let alert = eligible.first, let id = alert["id"] as? String {
          lastNudge[id] = now
          if settings["overlay"] as? Bool != false { FlowSessionMirror.shared.debugToast(alert["title"] as? String ?? "Task reminder") }
          if settings["sound"] as? Bool != false { NSSound(named: "Ping")?.play() }
        }
        connection = "Local task service · connected"
      } catch { connection = "Task service unavailable: \(error.localizedDescription)" }
    }
  }
  func syncObservation() {
    let mirror=FlowSessionMirror.shared
    guard UserDefaults.standard.object(forKey:"companionObservationEnabled") as? Bool ?? true else {
      if ownedSession { mirror.apply(.idle);ownedSession=false };return
    }
    let now=Date();let calendar=Calendar.current
    let today=tasks.filter { t in guard let d=Self.date(t.start) else { return false };return calendar.isDate(d,inSameDayAs:now) && t.status != "cancelled" }
    let scheduledBreak=today.first { t in
      ["Lunch / screen break","Short break"].contains(t.title) && (Self.date(t.start) ?? .distantFuture)<=now && now<(Self.date(t.end) ?? .distantPast)
    }
    let timerBreak=focus["mode"] as? String == "break" && focus["status"] as? String == "running"
    let goals=today.filter { $0.status != "done" && !["Lunch / screen break","Short break"].contains($0.title) && (Self.date($0.start) ?? .distantFuture)<=now }.sorted { $0.start < $1.start }
    guard let end=today.compactMap({Self.date($0.end)}).max(),end>now,!goals.isEmpty else {
      if ownedSession { mirror.apply(.idle);ownedSession=false };return
    }
    // Start active once before a break so upstream pause/resume owns a live observer.
    var snapshot=FlowNativeSnapshot()
    snapshot.phase = .active;snapshot.alertStyle = .friendly
    snapshot.sessionStartedAt = ownedSession ? mirror.snapshot.sessionStartedAt : Int(now.timeIntervalSince1970)
    snapshot.sessionEndsAt=Int(end.timeIntervalSince1970)
    snapshot.goalTasks=goals.map { FlowGoalTask(id:$0.id,title:$0.title + ($0.subtasks.isEmpty ? "" : " — Required steps: " + $0.subtasks.joined(separator:"; ")) + ($0.notes.isEmpty ? "" : " — " + $0.notes)) }
    snapshot.goals=snapshot.goalTasks?.map(\.title)
    if !ownedSession { mirror.apply(snapshot);ownedSession=true }
    if scheduledBreak != nil || timerBreak {
      snapshot.phase = .onBreak
      snapshot.breakEndsAt=Int((timerBreak ? Self.date(focus["ends_at"] as? String ?? "") ?? now : Self.date(scheduledBreak!.end) ?? now).timeIntervalSince1970)
    }
    if snapshot != mirror.snapshot { mirror.apply(snapshot) }
  }
  func detectedCompletion(_ goals: [FlowGoalTask]) {
    Task {
      for goal in goals {
        guard tasks.contains(where:{$0.id==goal.id && $0.status != "done" && $0.status != "cancelled"}) else { continue }
        do { _ = try await request("/tasks/"+goal.id,method:"PATCH",body:["status":"done"]) }
        catch { connection="Could not save detected completion: \(error.localizedDescription)" }
      }
      refresh()
    }
  }
  static func date(_ value: String) -> Date? {
    let f=ISO8601DateFormatter();f.formatOptions=[.withInternetDateTime,.withFractionalSeconds]
    if let d=f.date(from:value) { return d };f.formatOptions=[.withInternetDateTime];return f.date(from:value)
  }
  func command(_ path: String, body: [String: Any] = [:]) {
    Task { do { _ = try await request(path, method:"POST",body:body);refresh() } catch { connection=error.localizedDescription } }
  }
  func startFocus(_ task: CompanionTask) {
    var minutes=25.0
    if let end=Self.date(task.end) { minutes=min(minutes,end.timeIntervalSinceNow/60) }
    if minutes <= 0 { connection="This timebox has ended. Replan it before starting focus.";return }
    command("/focus/start",body:["task_id":task.id,"mode":"focus","minutes":minutes])
  }
  func complete(_ task: CompanionTask) {
    Task { do { _ = try await request("/tasks/" + task.id, method: "PATCH", body: ["status": task.status == "done" ? "todo" : "done"]);refresh() } catch { connection = error.localizedDescription } }
  }
  func acknowledge(_ id: String) {
    Task { do { _ = try await request("/alerts/" + id + "/ack", method: "POST", body: [:]);refresh() } catch { connection = error.localizedDescription } }
  }
}
struct CompanionTasksView: View {
  @ObservedObject private var model = CompanionPlanner.shared
  @ObservedObject private var observer = FlowDistractionAgent.shared
  @AppStorage("companionObservationEnabled") private var observing = true
  @State private var day = Date()
  @State private var text = ""
  @State private var preview: [[String: Any]] = []
  @State private var status = ""
  @State private var busy = false
  @State private var importID = UUID().uuidString
  private var dayString: String { let f=DateFormatter();f.dateFormat="yyyy-MM-dd";return f.string(from:day) }
  private var todayTasks: [CompanionTask] { model.tasks.filter { $0.day == dayString && !["done","cancelled"].contains($0.status) }.sorted { $0.start < $1.start } }
  private var current: CompanionTask? { todayTasks.first { t in
    guard let start=CompanionPlanner.date(t.start),let end=CompanionPlanner.date(t.end) else { return false }
    return start<=model.clock && model.clock<end
  } }
  private var next: CompanionTask? { todayTasks.first { (CompanionPlanner.date($0.start) ?? .distantPast)>model.clock } }
  private var timerActive: Bool { ["running","paused"].contains(model.focus["status"] as? String ?? "") }
  private var remaining: String {
    let seconds=model.focus["status"] as? String == "paused" ? model.focus["remaining_seconds"] as? Double ?? 0 : (CompanionPlanner.date(model.focus["ends_at"] as? String ?? "")?.timeIntervalSince(model.clock) ?? 0)
    let n=max(0,Int(seconds.rounded(.up)));return String(format:"%02d:%02d",n/60,n%60)
  }
  private var allDayTasks: [CompanionTask] { model.tasks.filter { $0.day == dayString && $0.status != "cancelled" }.sorted { $0.start < $1.start } }
  private var isToday: Bool { Calendar.current.isDateInToday(day) }
  private var dayTitle: String { isToday ? "Today" : day.formatted(.dateTime.weekday(.wide)) }
  private var daySubtitle: String { day.formatted(.dateTime.day().month(.wide).year()) }
  @State private var showAgentEndpoint = false

  var body: some View {
    GeometryReader { geo in
      ScrollView {
        VStack(alignment: .leading, spacing: TBDTokens.Space.xxl) {
          header
          if geo.size.width >= 920 {
            HStack(alignment: .top, spacing: TBDTokens.Space.xxl) {
              mainColumn.frame(maxWidth: .infinity, alignment: .leading)
              sideColumn.frame(width: 320)
            }
          } else {
            VStack(alignment: .leading, spacing: TBDTokens.Space.xxl) { mainColumn; sideColumn }
          }
        }
        .padding(.horizontal, 32).padding(.vertical, 24)
        .frame(maxWidth: .infinity, alignment: .leading)
      }
    }
    .onChange(of: text) { preview=[];importID=UUID().uuidString;status="" }
    .onChange(of: day) { preview=[];importID=UUID().uuidString;status="" }
  }

  // MARK: Header
  private var header: some View {
    TBDPageHeader(dayTitle, label: "Flow · " + daySubtitle) {
      HStack(spacing: TBDTokens.Space.sm) {
        Button { shiftDay(-1) } label: { Image(systemName: "chevron.left") }.buttonStyle(TBDButtonStyle(.icon)).help("Previous day")
        if !isToday { Button("Today") { day = Date() }.buttonStyle(TBDButtonStyle(.secondary)) }
        Button { shiftDay(1) } label: { Image(systemName: "chevron.right") }.buttonStyle(TBDButtonStyle(.icon)).help("Next day")
      }
    }
  }
  private func shiftDay(_ delta: Int) { day = Calendar.current.date(byAdding: .day, value: delta, to: day) ?? day }

  // MARK: Main column
  private var mainColumn: some View {
    VStack(alignment: .leading, spacing: TBDTokens.Space.xl) {
      nowCard
      ForEach(model.alerts.indices, id: \.self) { i in alertRow(model.alerts[i]) }
      scheduleSection
    }
  }

  private var nowCard: some View {
    VStack(alignment: .leading, spacing: TBDTokens.Space.md) {
      HStack { TBDLabel("Now"); Spacer(); if timerActive { TBDChip((model.focus["mode"] as? String ?? "focus").capitalized, color: TBDTokens.accent) } }
      if timerActive {
        let focusTitle = model.tasks.first { $0.id == model.focus["task_id"] as? String }?.title ?? ""
        Text(remaining).font(.system(size: 44, weight: .medium, design: .monospaced)).monospacedDigit().foregroundStyle(TBDTokens.ink)
        if !focusTitle.isEmpty { Text(focusTitle).font(TBDTokens.Typography.title).foregroundStyle(TBDTokens.ink) }
        HStack(spacing: TBDTokens.Space.sm) {
          Button(model.focus["status"] as? String == "paused" ? "Resume" : "Pause") { model.command(model.focus["status"] as? String == "paused" ? "/focus/resume" : "/focus/pause") }.buttonStyle(TBDButtonStyle(.primary))
          Button("Stop") { model.command("/focus/stop") }.buttonStyle(TBDButtonStyle(.secondary))
        }
      } else if let current {
        Text(current.title).font(TBDTokens.Typography.display).tracking(TBDTokens.Typography.displayTracking).foregroundStyle(TBDTokens.ink)
        Text(timeRange(current)).font(.system(size: 12, design: .monospaced)).foregroundStyle(TBDTokens.muted)
        Button("Start focus · up to 25 min") { model.startFocus(current) }.buttonStyle(TBDButtonStyle(.primary))
      } else {
        Text(isToday ? "Nothing scheduled right now" : "No task at this moment").font(TBDTokens.Typography.display).tracking(TBDTokens.Typography.displayTracking).foregroundStyle(TBDTokens.ink)
        Text(allDayTasks.isEmpty ? "Plan your day on the right, or send a schedule from your agent." : "Your next timebox starts later.").font(TBDTokens.Typography.body).foregroundStyle(TBDTokens.muted)
      }
      Rectangle().fill(TBDTokens.border).frame(height: TBDTokens.Stroke.hairline).padding(.vertical, 2)
      HStack(spacing: TBDTokens.Space.sm) {
        TBDLabel("Next")
        Text(next.map { localTime($0.start) + " · " + $0.title } ?? "No later task scheduled").font(TBDTokens.Typography.body).foregroundStyle(TBDTokens.ink).lineLimit(1)
      }
    }
    .tbdCard(padding: TBDTokens.Space.xl)
  }

  private func alertRow(_ alert: [String: Any]) -> some View {
    HStack(spacing: TBDTokens.Space.md) {
      Image(systemName: "bell").foregroundStyle(TBDTokens.alert)
      Text(alert["title"] as? String ?? "Reminder").font(TBDTokens.Typography.control).foregroundStyle(TBDTokens.ink)
      Spacer()
      Button("Snooze 5m") { model.command("/alerts/" + (alert["id"] as? String ?? "") + "/snooze", body: ["minutes": 5]) }.buttonStyle(TBDButtonStyle(.quiet))
      Button("Done") { model.acknowledge(alert["id"] as? String ?? "") }.buttonStyle(TBDButtonStyle(.secondary))
    }
    .padding(.horizontal, TBDTokens.Space.lg).padding(.vertical, TBDTokens.Space.md)
    .background(TBDTokens.alert.opacity(0.08))
    .overlay(RoundedRectangle(cornerRadius: TBDTokens.Radius.base).strokeBorder(TBDTokens.alert.opacity(0.3), lineWidth: TBDTokens.Stroke.hairline))
  }

  private var scheduleSection: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack {
        TBDLabel("Schedule")
        Spacer()
        let done = allDayTasks.filter { $0.status == "done" }.count
        if !allDayTasks.isEmpty { Text("\(done) of \(allDayTasks.count) done").font(.system(size: 11, design: .monospaced)).foregroundStyle(TBDTokens.muted) }
      }
      .padding(.bottom, TBDTokens.Space.sm)
      Rectangle().fill(TBDTokens.border).frame(height: TBDTokens.Stroke.hairline)
      if allDayTasks.isEmpty {
        VStack(alignment: .leading, spacing: 6) {
          Text("No tasks for this day").font(TBDTokens.Typography.control).foregroundStyle(TBDTokens.ink)
          Text("Paste a plan in “Plan your day”, or let an agent post one.").font(TBDTokens.Typography.body).foregroundStyle(TBDTokens.muted)
        }.padding(.vertical, TBDTokens.Space.xl)
      } else {
        ForEach(allDayTasks) { task in taskRow(task) }
      }
    }
  }

  private func taskRow(_ task: CompanionTask) -> some View {
    let done = task.status == "done"
    let expired = !done && (CompanionPlanner.date(task.end).map { $0 < model.clock } ?? false)
    let isNow = current?.id == task.id
    return VStack(spacing: 0) {
      HStack(alignment: .top, spacing: TBDTokens.Space.lg) {
        Button { model.complete(task) } label: {
          Image(systemName: done ? "checkmark.square.fill" : "square").font(.system(size: 16)).foregroundStyle(done ? TBDTokens.fill : TBDTokens.muted)
        }.buttonStyle(.plain).help(done ? "Mark as not done" : "Mark as done")
        Text(task.start.isEmpty ? "—" : localTime(task.start)).font(.system(size: 12, design: .monospaced)).foregroundStyle(TBDTokens.muted).frame(width: 64, alignment: .leading).padding(.top, 1)
        VStack(alignment: .leading, spacing: 4) {
          Text(task.title).font(TBDTokens.Typography.control).foregroundStyle(done ? TBDTokens.muted : TBDTokens.ink).strikethrough(done)
          HStack(spacing: TBDTokens.Space.sm) {
            if !task.start.isEmpty { Text(timeRange(task) + " · \(task.minutes) min").font(.system(size: 11)).foregroundStyle(TBDTokens.muted) }
            if isNow { TBDChip("Now", color: TBDTokens.accent) }
            if expired { TBDChip("Timebox ended", color: TBDTokens.alert) }
          }
          if !task.notes.isEmpty { Text(task.notes).font(TBDTokens.Typography.body).foregroundStyle(TBDTokens.muted) }
          ForEach(task.subtasks.indices, id: \.self) { i in
            HStack(alignment: .firstTextBaseline, spacing: 6) { Rectangle().fill(TBDTokens.muted).frame(width: 4, height: 4); Text(task.subtasks[i]).font(TBDTokens.Typography.body).foregroundStyle(TBDTokens.ink) }
          }
        }
        Spacer(minLength: TBDTokens.Space.md)
        if !done && !expired {
          Button { model.startFocus(task) } label: { Image(systemName: "timer") }.buttonStyle(TBDButtonStyle(.icon)).disabled(timerActive).help("Start 25-minute focus")
        }
      }
      .padding(.vertical, TBDTokens.Space.md)
      .padding(.horizontal, TBDTokens.Space.sm)
      .background(isNow ? TBDTokens.selected.opacity(0.5) : .clear)
      Rectangle().fill(TBDTokens.border).frame(height: TBDTokens.Stroke.hairline)
    }
  }

  // MARK: Side column
  private var sideColumn: some View {
    VStack(alignment: .leading, spacing: TBDTokens.Space.lg) {
      VStack(alignment: .leading, spacing: TBDTokens.Space.sm) {
        TBDLabel("Focus rhythm")
        Text("25 min focus · 5 min break").font(TBDTokens.Typography.control).foregroundStyle(TBDTokens.ink)
        Text("Start each interval yourself. Timeboxes follow the clock; unfinished tasks stay open.").font(TBDTokens.Typography.body).foregroundStyle(TBDTokens.muted).fixedSize(horizontal: false, vertical: true)
        Button("Start 5-minute break") { model.command("/focus/start", body: ["mode": "break", "minutes": 5]) }.buttonStyle(TBDButtonStyle(.secondary)).disabled(timerActive)
      }.frame(maxWidth: .infinity, alignment: .leading).tbdCard()

      VStack(alignment: .leading, spacing: TBDTokens.Space.sm) {
        HStack {
          TBDLabel("Observer")
          Spacer()
          Toggle("", isOn: $observing).labelsHidden().toggleStyle(.switch).tint(TBDTokens.fill).controlSize(.small)
            .onChange(of: observing) { model.syncObservation() }
        }
        Text("Nudge me when I drift from started tasks").font(TBDTokens.Typography.control).foregroundStyle(TBDTokens.ink)
        HStack(spacing: 6) {
          Rectangle().fill(observing ? TBDTokens.accent : TBDTokens.muted).frame(width: 6, height: 6)
          Text(observer.statusLine).font(.system(size: 11, design: .monospaced)).foregroundStyle(TBDTokens.muted)
        }
        Text("Scheduled breaks pause observation.").font(TBDTokens.Typography.body).foregroundStyle(TBDTokens.muted)
      }.frame(maxWidth: .infinity, alignment: .leading).tbdCard()

      VStack(alignment: .leading, spacing: TBDTokens.Space.sm) {
        TBDLabel("Plan your day")
        Text("One task per line: 09:00–10:00 Title, or TODO Title. Indent “- ” for subtasks, “> ” for notes.").font(TBDTokens.Typography.body).foregroundStyle(TBDTokens.muted).fixedSize(horizontal: false, vertical: true)
        TextEditor(text: $text).font(.system(size: 12, design: .monospaced)).scrollContentBackground(.hidden)
          .padding(8).frame(height: 120).background(TBDTokens.canvas)
          .overlay(RoundedRectangle(cornerRadius: TBDTokens.Radius.base).strokeBorder(TBDTokens.border, lineWidth: TBDTokens.Stroke.hairline))
        HStack(spacing: TBDTokens.Space.sm) {
          Button(busy ? "Working…" : "Preview tasks") { ingest(commit: false) }.buttonStyle(TBDButtonStyle(preview.isEmpty ? .primary : .secondary))
            .disabled(busy || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
          if !preview.isEmpty { Button("Save \(preview.count) tasks") { ingest(commit: true) }.buttonStyle(TBDButtonStyle(.primary)).disabled(busy) }
        }
        if !status.isEmpty { Text(status).font(TBDTokens.Typography.body).foregroundStyle(TBDTokens.muted).textSelection(.enabled) }
        ForEach(preview.indices, id: \.self) { i in
          Text("\(i+1). " + (preview[i]["title"] as? String ?? "")).font(TBDTokens.Typography.body).foregroundStyle(TBDTokens.ink)
        }
        Text("Times use \(TimeZone.current.identifier).").font(.system(size: 11)).foregroundStyle(TBDTokens.muted)
        DisclosureGroup(isExpanded: $showAgentEndpoint) {
          Text("POST http://127.0.0.1:18770/api/schedules · Bearer token").font(.system(size: 11, design: .monospaced)).foregroundStyle(TBDTokens.muted).textSelection(.enabled).padding(.top, 4)
        } label: { Text("For agents").font(.system(size: 11, weight: .medium)).foregroundStyle(TBDTokens.muted) }
      }.frame(maxWidth: .infinity, alignment: .leading).tbdCard()

      Text(model.connection).font(.system(size: 10, design: .monospaced)).foregroundStyle(TBDTokens.muted)
    }
  }

  private func timeRange(_ task: CompanionTask) -> String {
    localTime(task.start) + (task.end.isEmpty ? "" : "–" + localTime(task.end))
  }
  private func localTime(_ raw: String) -> String {
    return CompanionPlanner.date(raw)?.formatted(date:.omitted,time:.shortened) ?? raw
  }
  private func ingest(commit: Bool) {
    busy=true
    let submittedText=text;let submittedDay=dayString
    Task {
      defer { busy=false }
      do {
        let result=try await model.request("/schedules",method:"POST",body:["format":"agent-schedule-v1","text":submittedText,"day":submittedDay,"timezone":TimeZone.current.identifier,"mode":commit ? "commit" : "preview","idempotency_key":importID]) as? [String:Any] ?? [:]
        guard text == submittedText && dayString == submittedDay else { status="Input changed; parse the updated schedule.";model.refresh();return }
        let tasks=result["tasks"] as? [[String:Any]] ?? []
        status=(commit ? "Saved \(tasks.count) tasks." : "Drafted \(tasks.count) tasks.") + " " + ((result["warnings"] as? [String] ?? []).joined(separator:" "))
        preview=commit ? [] : tasks
        if commit { model.refresh() }
      } catch { status=error.localizedDescription }
    }
  }
}

struct FlowView: View {
  @State private var tab = 0
  private let tabs = ["Tasks", "Nudge preview"]
  var body: some View {
    VStack(spacing: 0) {
      HStack(spacing: TBDTokens.Space.xl) {
        ForEach(tabs.indices, id: \.self) { index in
          Button { tab = index } label: {
            Text(tabs[index])
              .font(.custom("Switzer", size: 13).weight(tab == index ? .semibold : .medium))
              .foregroundStyle(tab == index ? TBDTokens.ink : TBDTokens.muted)
              .padding(.vertical, TBDTokens.Space.md)
              .overlay(alignment: .bottom) {
                RoundedRectangle(cornerRadius: 1).fill(tab == index ? TBDTokens.accent : .clear).frame(height: 2)
              }
              .contentShape(Rectangle())
          }.buttonStyle(.plain)
        }
        Spacer()
      }
      .padding(.horizontal, 32)
      .frame(maxWidth: .infinity, alignment: .leading)
      .overlay(alignment: .bottom) { Rectangle().fill(TBDTokens.border).frame(height: TBDTokens.Stroke.hairline) }
      if tab == 0 { CompanionTasksView() } else { FlowDemoView() }
    }
  }
}
