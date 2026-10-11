// Agent wall: TBD's native view of agent sessions (replaces the AgentPlayback vinyl UI).
// Data comes from the AgentPlayback scanner's day files; the scanner's web UI is not shown.
// Design language: TBD/docs/design-language.md ("brick").
import AppKit
import TBDDesign
import SwiftUI

// MARK: - Data

struct AgentWallThread: Decodable, Identifiable {
  enum CodingKeys: String, CodingKey { case id, category, provider, start, end, lane, state, title, summary, usd, segments, blockedRanges }
  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    start = try c.decode(Double.self, forKey: .start)
    end = (try? c.decode(Double.self, forKey: .end)) ?? start
    id = (try? c.decode(String.self, forKey: .id)) ?? "\(start)-\(end)"
    category = (try? c.decode(String.self, forKey: .category)) ?? "Other"
    provider = (try? c.decode(String.self, forKey: .provider)) ?? ""
    lane = (try? c.decode(Int.self, forKey: .lane)) ?? 0
    state = (try? c.decode(String.self, forKey: .state)) ?? "done"
    title = try? c.decode(String.self, forKey: .title)
    summary = try? c.decode(String.self, forKey: .summary)
    usd = try? c.decode(Double.self, forKey: .usd)
    segments = try? c.decode([[Double]].self, forKey: .segments)
    blockedRanges = try? c.decode([[Double]].self, forKey: .blockedRanges)
  }
  let id: String
  let category: String
  let provider: String
  let start: Double
  let end: Double
  let lane: Int
  let state: String
  let title: String?
  let summary: String?
  let usd: Double?
  let segments: [[Double]]?
  let blockedRanges: [[Double]]?

  /// Working spans in hours-of-day; falls back to the whole thread.
  var spans: [ClosedRange<Double>] {
    let raw = (segments?.isEmpty == false) ? segments! : [[start, end]]
    return raw.compactMap { $0.count >= 2 && $0[1] >= $0[0] ? $0[0]...$0[1] : nil }
  }
  var waits: [ClosedRange<Double>] {
    (blockedRanges ?? []).compactMap { $0.count >= 2 && $0[1] >= $0[0] ? $0[0]...$0[1] : nil }
  }
  var workingHours: Double { spans.reduce(0) { $0 + ($1.upperBound - $1.lowerBound) } }
  var waitingHours: Double { waits.reduce(0) { $0 + ($1.upperBound - $1.lowerBound) } }
  var isActive: Bool { state == "active" }
}

struct AgentWallDay: Decodable {
  struct Stats: Decodable { let peakConcurrent: Int? }
  struct Hours: Decodable { let category: String; let hours: Double }
  struct Code: Decodable { let category: String; let add: Int; let del: Int }
  struct Tokens: Decodable {
    struct Category: Decodable {
      let category: String
      let openai: Double?
      let claude: Double?
      let openaiCost: Double?
      let claudeCost: Double?
      var tokens: Double { (openai ?? 0) + (claude ?? 0) }
      var cost: Double { (openaiCost ?? 0) + (claudeCost ?? 0) }
    }
    struct Cost: Decodable { let openai: Double?; let claude: Double?; let priced: Bool? }
    let openai: Double?
    let claude: Double?
    let cost: Cost?
    let byCategory: [Category]?
  }
  struct Meta: Decodable { let dayStart: Double?; let dayEnd: Double? }
  /// Skips a malformed entry instead of failing the whole day.
  private struct Lossy<T: Decodable>: Decodable {
    let value: T?
    init(from decoder: Decoder) throws { value = try? T(from: decoder) }
  }
  enum CodingKeys: String, CodingKey { case date, stats, threads, donut, codeTotals, tokens, meta }
  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    date = (try? c.decode(String.self, forKey: .date)) ?? ""
    stats = try? c.decode(Stats.self, forKey: .stats)
    threads = ((try? c.decode([Lossy<AgentWallThread>].self, forKey: .threads)) ?? []).compactMap(\.value)
    donut = try? c.decode([Hours].self, forKey: .donut)
    codeTotals = try? c.decode([Code].self, forKey: .codeTotals)
    tokens = try? c.decode(Tokens.self, forKey: .tokens)
    meta = try? c.decode(Meta.self, forKey: .meta)
  }
  var date: String
  let stats: Stats?
  let threads: [AgentWallThread]
  let donut: [Hours]?
  let codeTotals: [Code]?
  let tokens: Tokens?
  let meta: Meta?
}

@MainActor
final class AgentWallStore: ObservableObject {
  static let shared = AgentWallStore()
  @Published private(set) var days: [String] = []
  @Published private(set) var day: AgentWallDay?
  @Published private(set) var history: [String: AgentWallDay] = [:]
  @Published var selectedDate: String?
  private var timer: Timer?
  private var loadedStamp: Date?

  let directory: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    .appendingPathComponent("TBD/Companion/agents/data", isDirectory: true)

  private init() {
    reload()
    timer = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { _ in
      Task { @MainActor in AgentWallStore.shared.reload() }
    }
  }

  var hasData: Bool { !days.isEmpty }

  func reload() {
    let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
    days = names.compactMap { name -> String? in
      guard name.hasPrefix("day-"), name.hasSuffix(".json") else { return nil }
      return String(name.dropFirst(4).dropLast(5))
    }.sorted()
    let today = Self.key(Date())
    if selectedDate == nil { selectedDate = days.contains(today) ? today : (days.last(where: { $0 <= today }) ?? days.last) }
    loadSelected(force: false)
    loadHistory()
  }

  func select(_ key: String) { selectedDate = key; loadSelected(force: true); loadHistory() }

  /// Step by calendar day; days without agent activity show an empty wall.
  func shift(_ delta: Int) {
    guard let current = selectedDate.flatMap(Self.date),
          let next = Calendar.current.date(byAdding: .day, value: delta, to: current) else { return }
    select(Self.key(next))
  }

  var firstDay: Date? { days.first.flatMap(Self.date) }
  var canGoBack: Bool { guard let s = selectedDate, let first = days.first else { return false }; return s > first }
  var canGoForward: Bool { guard let s = selectedDate else { return false }; return s < Self.key(Date()) }

  private func url(_ key: String) -> URL { directory.appendingPathComponent("day-\(key).json") }

  private func read(_ key: String) -> AgentWallDay? {
    guard let data = try? Data(contentsOf: url(key)), var day = try? JSONDecoder().decode(AgentWallDay.self, from: data) else { return nil }
    if day.date.isEmpty { day.date = key }
    return day
  }

  private func loadSelected(force: Bool) {
    guard let key = selectedDate, days.contains(key) else { day = nil; loadedStamp = nil; return }
    let stamp = (try? FileManager.default.attributesOfItem(atPath: url(key).path)[.modificationDate]) as? Date
    guard force || stamp != loadedStamp || day?.date != key else { return }
    loadedStamp = stamp
    day = read(key)
  }

  private func loadHistory() {
    let recent = Array(days.suffix(14))
    var next: [String: AgentWallDay] = [:]
    for key in recent { next[key] = history[key] ?? read(key) }
    if let current = selectedDate, let fresh = day, recent.contains(current) { next[current] = fresh }
    history = next
  }

  nonisolated static func key(_ date: Date) -> String {
    let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.locale = Locale(identifier: "en_US_POSIX")
    return f.string(from: date)
  }
  nonisolated static func date(_ key: String) -> Date? {
    let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.locale = Locale(identifier: "en_US_POSIX")
    return f.date(from: key)
  }
}


// MARK: - Remote agents (Portal)

struct AgentWallRemoteSession: Identifiable {
  let id: String
  let agentName: String
  let title: String
  let at: Date
  /// Hours-of-day of the last message on its local calendar day.
  var hour: Double { Double(Calendar.current.component(.hour, from: at)) + Double(Calendar.current.component(.minute, from: at)) / 60 }
  var dayKey: String { AgentWallStore.key(at) }
}

/// Portal only keeps a directory of sessions (agent, title, last activity), never content
/// or working spans, so remote agents appear at their last-activity time.
@MainActor
final class AgentWallRemoteStore: ObservableObject {
  static let shared = AgentWallRemoteStore()
  @Published private(set) var sessions: [AgentWallRemoteSession] = []
  @Published private(set) var agentCount = 0
  @Published private(set) var status = ""
  private var lastFetch = Date.distantPast

  func refresh(force: Bool = false) {
    guard TBDAccountCoordinator.shared.signedIn else { sessions = []; status = ""; return }
    guard force || Date().timeIntervalSince(lastFetch) > 60 else { return }
    lastFetch = Date()
    Task {
      do {
        let agents = try await TBDChatRuntime.shared.accountCall("listAgents") as? [[String: Any]] ?? []
        let names = Dictionary(agents.compactMap { a -> (String, String)? in
          guard let id = a["id"] as? String else { return nil }
          return (id, a["name"] as? String ?? id)
        }, uniquingKeysWith: { a, _ in a })
        let rows = try await TBDChatRuntime.shared.accountCall("listSessions") as? [[String: Any]] ?? []
        let iso = ISO8601DateFormatter(); iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        sessions = rows.compactMap { r in
          guard let sid = r["sessionId"] as? String, let raw = r["lastMessageAt"] as? String,
                let at = iso.date(from: raw) ?? plain.date(from: raw) else { return nil }
          let agent = r["agent"] as? String ?? ""
          let title = (r["title"] as? String) ?? (r["label"] as? String) ?? "Conversation"
          return AgentWallRemoteSession(id: sid, agentName: names[agent] ?? agent, title: title, at: at)
        }
        agentCount = names.count
        status = "\(names.count) Portal agents"
      } catch { status = "Portal agents unavailable" }
    }
  }
}

// MARK: - Palette

enum AgentWallPalette {
  /// Clay: the unbuilt/idle wall.
  static func clay(_ seed: Int, dark: Bool) -> Color {
    let v = noise(seed)
    let base: (Double, Double, Double) = dark ? (0.50, 0.23, 0.18) : (0.69, 0.33, 0.25)
    let k = 0.90 + 0.18 * v
    return Color(red: base.0 * k, green: base.1 * k, blue: base.2 * k)
  }
  /// Teal: agents working. Deeper with more agents at once.
  static func teal(_ agents: Int, seed: Int) -> Color {
    let v = 0.94 + 0.10 * noise(seed &+ 7)
    let base: (Double, Double, Double) = agents >= 3 ? (0.09, 0.40, 0.37) : agents == 2 ? (0.15, 0.50, 0.46) : (0.24, 0.60, 0.55)
    return Color(red: base.0 * v, green: base.1 * v, blue: base.2 * v)
  }
  static let waiting = Color(red: 0.87, green: 0.66, blue: 0.27)
  static func noise(_ seed: Int) -> Double {
    var x = UInt64(bitPattern: Int64(seed)) &* 0x9E3779B97F4A7C15
    x ^= x >> 31; x &*= 0xBF58476D1CE4E5B9; x ^= x >> 29
    return Double(x % 10_000) / 10_000
  }
}

// MARK: - Formatting

private func hoursLabel(_ hours: Double) -> String {
  let minutes = Int((hours * 60).rounded())
  return minutes >= 60 ? "\(minutes / 60)h \(String(format: "%02d", minutes % 60))m" : "\(minutes)m"
}
private func clockLabel(_ hour: Double) -> String {
  let total = Int((hour * 60).rounded()); return String(format: "%02d:%02d", (total / 60) % 24, total % 60)
}
private func money(_ usd: Double) -> String { usd.formatted(.currency(code: "USD").precision(.fractionLength(2))) }
private func compact(_ n: Double) -> String { n.formatted(.number.notation(.compactName).precision(.fractionLength(0...1))) }

// MARK: - Rendered wall tile (companion/design/agent-wall, Blender, metres)

enum AgentWallTile {
  static let bricksPerCourse = 8, courses = 8
  static let pitch = 0.225, course = 0.075, brickW = 0.215, brickH = 0.065, width = 1.8, height = 0.6
  static let aspect = CGFloat(width / height)
  /// Sessions fill the middle courses first.
  static let courseOrder = [4, 3, 5, 2, 6, 1, 7, 0]
  /// Left edge (metres) of brick `k` in course `r`, within one tile.
  static func brickX(course r: Int, index k: Int) -> Double { Double(k) * pitch + (r % 2 == 1 ? pitch / 2 : 0) + (pitch - brickW) / 2 }
  /// Top edge (metres from the top of the tile) of course `r`, course 0 at the bottom.
  static func brickTop(course r: Int) -> Double { height - (Double(r) * course + course / 2 + brickH / 2) }
}

enum AgentBrickTone { case teal, deep, amber }

/// One recoloured brick on the endless wall, in wall metres.
struct AgentWallBrick {
  let course: Int
  let x: Double
  let tone: AgentBrickTone
  let threadID: String?
  let remoteID: String?
}

struct AgentWallCallout {
  let id: String
  let course: Int
  let x: Double
  let title: String
  let meta: String
}

struct AgentWallPlan {
  let lo: Double, hi: Double
  let loopWidth: Double  // metres
  let bricks: [AgentWallBrick]
  let callouts: [AgentWallCallout]

  /// Lay the day across one loop of the wall; one brick is ten minutes.
  init(day: AgentWallDay, remotes: [AgentWallRemoteSession], selected: String?, highlightWaiting: Bool) {
    let hours = day.threads.flatMap { $0.spans.flatMap { [$0.lowerBound, $0.upperBound] } } + remotes.map(\.hour)
    var lo = floor(hours.min() ?? 9) - 0.5, hi = ceil(hours.max() ?? 17) + 0.5
    if hi - lo < 6 { hi = lo + 6 }
    lo = max(0, lo); hi = min(24.5, hi)
    self.lo = lo; self.hi = hi
    let bricksPerHour = 6.0
    let tiles = max(3, Int(ceil((hi - lo) * bricksPerHour / Double(AgentWallTile.bricksPerCourse))))
    loopWidth = Double(tiles) * AgentWallTile.width
    let span = hi - lo, loop = loopWidth
    func time(_ x: Double) -> Double { lo + x / loop * span }
    func xOf(_ hour: Double) -> Double { (hour - lo) / span * loop }

    var bricks: [AgentWallBrick] = []
    var callouts: [AgentWallCallout] = []
    let total = tiles * AgentWallTile.bricksPerCourse
    for thread in day.threads.sorted(by: { $0.start < $1.start }) {
      let course = AgentWallTile.courseOrder[thread.lane % AgentWallTile.courseOrder.count]
      var first: Double?
      for g in 0..<total {
        let x0 = Double(g / AgentWallTile.bricksPerCourse) * AgentWallTile.width + AgentWallTile.brickX(course: course, index: g % AgentWallTile.bricksPerCourse)
        let range = time(x0)...time(x0 + AgentWallTile.brickW)
        let working = thread.spans.contains { $0.overlaps(range) }
        let waiting = highlightWaiting && thread.waits.contains { $0.overlaps(range) }
        guard working || waiting else { continue }
        let tone: AgentBrickTone = waiting && !working ? .amber : (selected == thread.id || thread.isActive ? .deep : .teal)
        bricks.append(AgentWallBrick(course: course, x: x0, tone: tone, threadID: thread.id, remoteID: nil))
        if first == nil { first = x0 }
      }
      if let first {
        let provider = thread.provider.lowercased().contains("claude") ? "Claude Code" : thread.provider.lowercased().contains("openai") || thread.provider.lowercased().contains("codex") ? "Codex" : thread.provider.capitalized
        let meta = [thread.category, provider, hoursLabelShort(thread.workingHours), thread.isActive ? "running" : nil].compactMap { $0 }.joined(separator: " · ")
        callouts.append(AgentWallCallout(id: thread.id, course: course, x: first + AgentWallTile.brickW / 2, title: thread.title ?? thread.category, meta: meta))
      }
    }
    for remote in remotes {
      let course = 7
      let target = xOf(remote.hour)
      let g = Int((target / AgentWallTile.pitch).rounded(.down))
      let x0 = Double(g / AgentWallTile.bricksPerCourse) * AgentWallTile.width + AgentWallTile.brickX(course: course, index: g % AgentWallTile.bricksPerCourse)
      bricks.append(AgentWallBrick(course: course, x: x0, tone: .teal, threadID: nil, remoteID: remote.id))
      callouts.append(AgentWallCallout(id: remote.id, course: course, x: x0 + AgentWallTile.brickW / 2, title: remote.title, meta: "Portal · \(remote.agentName) · \(remote.at.formatted(date: .omitted, time: .shortened))"))
    }
    self.bricks = bricks
    self.callouts = callouts
  }

  func x(forHour hour: Double) -> Double { (hour - lo) / (hi - lo) * loopWidth }
}

private func positiveMod(_ value: Double, _ modulus: Double) -> Double {
  guard modulus > 0 else { return 0 }
  let r = value.truncatingRemainder(dividingBy: modulus)
  return r < 0 ? r + modulus : r
}

private func hoursLabelShort(_ hours: Double) -> String {
  let minutes = Int((hours * 60).rounded())
  return minutes >= 60 ? "\(minutes / 60)h \(minutes % 60)m" : "\(minutes)m"
}

// MARK: - Agent wall

struct AgentWallView: View {
  @ObservedObject private var store = AgentWallStore.shared
  @ObservedObject private var remote = AgentWallRemoteStore.shared
  @ObservedObject private var account = TBDAccountCoordinator.shared
  @AppStorage("agentWallHighlightWaiting") private var highlightWaiting = true
  @AppStorage("agentWallShowRemote") private var showRemote = true
  @State private var selectedThread: String?
  @State private var hoverPoint: CGPoint?
  // Endless scroll: shift = base + (now - resumedAt) * speed, frozen while hovering.
  @State private var baseShift: Double = 0
  @State private var resumedAt = Date()
  @State private var paused = false
  @State private var showCalendar = false
  @State private var dragStart: Double?
  @State private var hovering = false
  private let speed: Double = 16  // points per second, left to right

  var body: some View {
    GeometryReader { geo in
      // Everything fits one screen: the wall takes what's left after header, callouts, ruler and cards.
      let cardsHeight: CGFloat = min(210, max(170, geo.size.height * 0.24))
      let chrome: CGFloat = 16 + 72 + cardsHeight + 2 * TBDTokens.Space.lg + 16
      let wallHeight = min(360, max(150, geo.size.height - chrome - 2 * Self.calloutZone - Self.rulerHeight))
      VStack(alignment: .leading, spacing: TBDTokens.Space.lg) {
        header.padding(.horizontal, 32)
        if let day = store.day {
          wallBand(day, width: geo.size.width, wallHeight: wallHeight)
          HStack(alignment: .top, spacing: TBDTokens.Space.lg) {
            summary(day).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            sessions(day).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            controls.frame(width: 250).frame(maxHeight: .infinity, alignment: .topLeading)
          }
          .frame(height: cardsHeight)
          .padding(.horizontal, 32)
        } else {
          empty.padding(.horizontal, 32)
          Spacer(minLength: 0)
        }
      }
      .padding(.vertical, 16)
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
    .onAppear { store.reload(); remote.refresh(force: true) }
    .onReceive(Timer.publish(every: 30, on: .main, in: .common).autoconnect()) { _ in remote.refresh() }
  }

  // MARK: Header
  private var dayDate: Date? { store.selectedDate.flatMap(AgentWallStore.date) }
  private var isToday: Bool { store.selectedDate == AgentWallStore.key(Date()) }
  private var header: some View {
    let title = isToday ? "Today" : (dayDate?.formatted(.dateTime.weekday(.wide)) ?? "Agents")
    let label = "Agents · " + (dayDate?.formatted(.dateTime.day().month(.wide).year()) ?? "No data yet")
    return TBDPageHeader(title, label: label) {
      HStack(spacing: TBDTokens.Space.sm) {
        Button { store.shift(-1); selectedThread = nil } label: { Image(systemName: "chevron.left") }
          .buttonStyle(TBDButtonStyle(.icon)).disabled(!store.canGoBack).help("Previous day")
        Button { showCalendar.toggle() } label: { Image(systemName: "calendar") }
          .buttonStyle(TBDButtonStyle(.icon)).help("Choose a day")
          .popover(isPresented: $showCalendar, arrowEdge: .bottom) { calendarPopover }
        if !isToday {
          Button("Today") { store.select(AgentWallStore.key(Date())); selectedThread = nil }.buttonStyle(TBDButtonStyle(.secondary))
        }
        Button { store.shift(1); selectedThread = nil } label: { Image(systemName: "chevron.right") }
          .buttonStyle(TBDButtonStyle(.icon)).disabled(!store.canGoForward).help("Next day")
      }
    }
  }

  private var calendarPopover: some View {
    let selection = Binding<Date>(
      get: { dayDate ?? Date() },
      set: { store.select(AgentWallStore.key($0)); selectedThread = nil; showCalendar = false })
    let lower = store.firstDay ?? Calendar.current.date(byAdding: .year, value: -1, to: Date())!
    return VStack(alignment: .leading, spacing: TBDTokens.Space.sm) {
      TBDLabel("Choose a day")
      DatePicker("", selection: selection, in: lower...Date(), displayedComponents: .date)
        .datePickerStyle(.graphical).labelsHidden().tint(TBDTokens.fill)
      Text("\(store.days.count) days with agent activity").font(.system(size: 10, design: .monospaced)).foregroundStyle(TBDTokens.muted)
    }
    .padding(TBDTokens.Space.lg)
    .frame(width: 280)
  }

  private func remoteToday(_ day: AgentWallDay) -> [AgentWallRemoteSession] {
    guard showRemote && account.signedIn else { return [] }
    return remote.sessions.filter { $0.dayKey == day.date }
  }

  private func currentShift(_ now: Date) -> Double { paused ? baseShift : baseShift + now.timeIntervalSince(resumedAt) * speed }

  // MARK: Wall band (hero)
  private static let calloutZone: CGFloat = 56
  private static let rulerHeight: CGFloat = 24

  private func wallBand(_ day: AgentWallDay, width: CGFloat, wallHeight: CGFloat) -> some View {
    let plan = AgentWallPlan(day: day, remotes: remoteToday(day), selected: selectedThread, highlightWaiting: highlightWaiting)
    let total = Self.calloutZone * 2 + wallHeight + Self.rulerHeight
    return TimelineView(.animation(paused: paused)) { timeline in
      let shift = currentShift(timeline.date)
      Canvas { context, size in
        drawBand(context: &context, size: size, plan: plan, wallHeight: wallHeight, shift: shift)
      }
      .mask(LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.05),
                                   .init(color: .black, location: 0.95), .init(color: .clear, location: 1)],
                           startPoint: .leading, endPoint: .trailing))
      .overlay(alignment: .topLeading) {
        if let p = hoverPoint, let card = hoverCard(plan: plan, day: day, point: p, wallHeight: wallHeight, shift: shift, width: width) {
          card.offset(x: min(p.x + 16, width - 280), y: max(0, p.y - 110)).allowsHitTesting(false)
        }
      }
      .contentShape(Rectangle())
      .onContinuousHover { phase in
        switch phase {
        case .active(let p):
          hovering = true
          if !paused { baseShift = currentShift(Date()); paused = true }
          hoverPoint = dragStart == nil ? p : nil
        case .ended:
          hovering = false
          hoverPoint = nil
          if paused && dragStart == nil { resumedAt = Date(); paused = false }
        }
      }
      .gesture(
        DragGesture(minimumDistance: 4)
          .onChanged { value in
            if dragStart == nil { dragStart = currentShift(Date()); paused = true; hoverPoint = nil }
            baseShift = (dragStart ?? 0) + value.translation.width
          }
          .onEnded { _ in
            dragStart = nil
            if !hovering { resumedAt = Date(); paused = false }
          })
      .onTapGesture { location in
        let hit = brickAt(location, plan: plan, wallHeight: wallHeight, shift: currentShift(Date()), width: width)
        selectedThread = hit?.threadID == selectedThread ? nil : hit?.threadID
      }
    }
    .frame(height: total)
  }

  private func tileSize(_ wallHeight: CGFloat) -> CGSize { CGSize(width: wallHeight * AgentWallTile.aspect, height: wallHeight) }
  private func metresToPoints(_ wallHeight: CGFloat) -> CGFloat { wallHeight / CGFloat(AgentWallTile.height) }

  /// Screen rects for a brick, including its repeats around the loop.
  private func screenRects(_ brick: AgentWallBrick, plan: AgentWallPlan, wallHeight: CGFloat, shift: Double, width: CGFloat) -> [CGRect] {
    let k = metresToPoints(wallHeight), loop = plan.loopWidth * Double(k)
    let y = Self.calloutZone + CGFloat(AgentWallTile.brickTop(course: brick.course)) * k
    var base = brick.x * Double(k) + positiveMod(shift, loop)
    while base > Double(width) { base -= loop }
    var rects: [CGRect] = []
    var x = base
    while x > -loop { x -= loop }
    while x < Double(width) + loop {
      let r = CGRect(x: x, y: y, width: AgentWallTile.brickW * Double(k), height: AgentWallTile.brickH * Double(k))
      if r.maxX > -20 && r.minX < width + 20 { rects.append(r) }
      x += loop
    }
    return rects
  }

  private func brickAt(_ p: CGPoint, plan: AgentWallPlan, wallHeight: CGFloat, shift: Double, width: CGFloat) -> AgentWallBrick? {
    plan.bricks.first { b in screenRects(b, plan: plan, wallHeight: wallHeight, shift: shift, width: width).contains { $0.insetBy(dx: -2, dy: -2).contains(p) } }
  }

  private func drawBand(context: inout GraphicsContext, size: CGSize, plan: AgentWallPlan, wallHeight: CGFloat, shift: Double) {
    let tile = tileSize(wallHeight)
    let wallTop = Self.calloutZone
    let red = context.resolve(Image("AgentWallRed"))
    let tones: [AgentBrickTone: GraphicsContext.ResolvedImage] = [
      .teal: context.resolve(Image("AgentWallTeal")), .deep: context.resolve(Image("AgentWallTealdeep")), .amber: context.resolve(Image("AgentWallAmber"))]
    // Soft contact shadow under the wall.
    context.fill(Path(CGRect(x: 0, y: wallTop + wallHeight, width: size.width, height: 10)),
                 with: .linearGradient(Gradient(colors: [.black.opacity(0.18), .clear]), startPoint: CGPoint(x: 0, y: wallTop + wallHeight), endPoint: CGPoint(x: 0, y: wallTop + wallHeight + 10)))
    // Endless red wall.
    let offset = positiveMod(shift, Double(tile.width))
    var x = CGFloat(offset) - tile.width
    while x < size.width {
      context.draw(red, in: CGRect(x: x, y: wallTop, width: tile.width, height: tile.height))
      x += tile.width
    }
    // Session bricks: the same brick, cut from the recoloured render.
    let k = metresToPoints(wallHeight)
    for brick in plan.bricks {
      for rect in screenRects(brick, plan: plan, wallHeight: wallHeight, shift: shift, width: size.width) {
        guard let image = tones[brick.tone] else { continue }
        context.drawLayer { layer in
          layer.clip(to: Path(roundedRect: rect.insetBy(dx: -1.5, dy: -1.5), cornerRadius: 3))
          // Tile origin aligned with the red wall so shading matches exactly.
          var tx = CGFloat(offset) - tile.width
          while tx + tile.width < rect.minX - 2 { tx += tile.width }
          layer.draw(image, in: CGRect(x: tx, y: wallTop, width: tile.width, height: tile.height))
          layer.draw(image, in: CGRect(x: tx + tile.width, y: wallTop, width: tile.width, height: tile.height))
        }
        if brick.remoteID != nil {
          context.fill(Path(CGRect(x: rect.maxX - 9, y: rect.minY + 5, width: 5, height: 5)), with: .color(.white.opacity(0.9)))
        }
      }
    }
    _ = k
    // Time ruler, scrolling with the wall.
    let rulerY = wallTop + wallHeight + 8
    let loop = plan.loopWidth * Double(k)
    for h in stride(from: ceil(plan.lo), through: floor(plan.hi), by: 1) {
      var hx = plan.x(forHour: h) * Double(k) + positiveMod(shift, loop)
      while hx > Double(size.width) { hx -= loop }
      while hx < -loop { hx += loop }
      var px = hx
      while px < Double(size.width) + 40 {
        if px > -40 {
          context.fill(Path(CGRect(x: px, y: rulerY - 6, width: 1, height: 6)), with: .color(TBDTokens.muted.opacity(0.6)))
          context.draw(Text(String(format: "%02d:00", Int(h) % 24)).font(.system(size: 10, design: .monospaced)).foregroundStyle(TBDTokens.muted),
                       at: CGPoint(x: px, y: rulerY + 6), anchor: .top)
        }
        px += loop
      }
    }
    // Callouts: thin leaders to two-line labels, above for upper courses, below for lower.
    var placed: [(side: Int, x: CGFloat)] = []
    for callout in plan.callouts.sorted(by: { $0.x < $1.x }) {
      let anchorBrick = AgentWallBrick(course: callout.course, x: callout.x - AgentWallTile.brickW / 2, tone: .teal, threadID: nil, remoteID: nil)
      for rect in screenRects(anchorBrick, plan: plan, wallHeight: wallHeight, shift: shift, width: size.width) where rect.midX > size.width * 0.07 && rect.midX + 240 < size.width * 0.95 {
        let above = callout.course >= 4
        let side = above ? 0 : 1
        let crowded = placed.contains { $0.side == side && abs($0.x - rect.midX) < 190 }
        if crowded { continue }
        placed.append((side, rect.midX))
        let labelY: CGFloat = above ? 4 : wallTop + wallHeight + Self.rulerHeight + 6
        let leaderStart = CGPoint(x: rect.midX, y: above ? rect.minY + 4 : rect.maxY - 4)
        let leaderEnd = CGPoint(x: rect.midX, y: above ? labelY + 33 : labelY - 3)
        var leader = Path(); leader.move(to: leaderStart); leader.addLine(to: leaderEnd)
        context.stroke(leader, with: .color(TBDTokens.ink.opacity(0.55)), lineWidth: 1)
        context.fill(Path(ellipseIn: CGRect(x: leaderStart.x - 2.5, y: leaderStart.y - 2.5, width: 5, height: 5)), with: .color(.white))
        context.stroke(Path(ellipseIn: CGRect(x: leaderStart.x - 2.5, y: leaderStart.y - 2.5, width: 5, height: 5)), with: .color(TBDTokens.ink.opacity(0.7)), lineWidth: 1)
        let title = callout.title.count > 34 ? String(callout.title.prefix(33)) + "…" : callout.title
        context.draw(Text(title).font(.custom("Switzer", size: 13).weight(.semibold)).foregroundStyle(TBDTokens.ink),
                     at: CGPoint(x: rect.midX + 6, y: labelY), anchor: .topLeading)
        context.draw(Text(callout.meta).font(.system(size: 10, design: .monospaced)).foregroundStyle(TBDTokens.muted),
                     at: CGPoint(x: rect.midX + 6, y: labelY + 18), anchor: .topLeading)
      }
    }
  }

  private func hoverCard(plan: AgentWallPlan, day: AgentWallDay, point: CGPoint, wallHeight: CGFloat, shift: Double, width: CGFloat) -> AnyView? {
    guard let brick = brickAt(point, plan: plan, wallHeight: wallHeight, shift: shift, width: width) else { return nil }
    if let id = brick.threadID, let t = day.threads.first(where: { $0.id == id }) {
      return AnyView(VStack(alignment: .leading, spacing: 5) {
        Text(t.title ?? t.category).font(.custom("Switzer", size: 13).weight(.semibold)).foregroundStyle(TBDTokens.ink).lineLimit(2)
        Text("\(t.category) · \(clockLabel(t.start))–\(clockLabel(t.end))").font(.system(size: 10, design: .monospaced)).foregroundStyle(TBDTokens.muted)
        Text("Worked \(hoursLabel(t.workingHours))" + (t.waitingHours > 0 ? " · waited \(hoursLabel(t.waitingHours))" : "") + ((t.usd ?? 0) > 0 ? " · \(money(t.usd ?? 0))" : ""))
          .font(.system(size: 11)).foregroundStyle(TBDTokens.ink)
        if brick.tone == .amber { Text("Waiting on you here").font(.system(size: 11, weight: .medium)).foregroundStyle(AgentWallPalette.waiting) }
        Text("Click to highlight").font(.system(size: 10)).foregroundStyle(TBDTokens.muted)
      }.padding(12).frame(width: 260, alignment: .leading).tbdFloating())
    }
    if let id = brick.remoteID, let r = remoteToday(day).first(where: { $0.id == id }) {
      return AnyView(VStack(alignment: .leading, spacing: 5) {
        Text(r.title).font(.custom("Switzer", size: 13).weight(.semibold)).foregroundStyle(TBDTokens.ink).lineLimit(2)
        Text("Portal · \(r.agentName) · last active \(r.at.formatted(date: .omitted, time: .shortened))").font(.system(size: 10, design: .monospaced)).foregroundStyle(TBDTokens.muted)
      }.padding(12).frame(width: 260, alignment: .leading).tbdFloating())
    }
    return nil
  }

  // MARK: Summary
  private func summary(_ day: AgentWallDay) -> some View {
    let working = day.threads.reduce(0) { $0 + $1.workingHours }
    let waiting = day.threads.reduce(0) { $0 + $1.waitingHours }
    let tokenRows = day.tokens?.byCategory ?? []
    let tokens = tokenRows.reduce(0) { $0 + $1.tokens }, cost = tokenRows.reduce(0) { $0 + $1.cost }
    let add = (day.codeTotals ?? []).reduce(0) { $0 + $1.add }, del = (day.codeTotals ?? []).reduce(0) { $0 + $1.del }
    return VStack(alignment: .leading, spacing: TBDTokens.Space.sm) {
      TBDLabel("Total hours worked by agents")
      Text(hoursLabel(working)).font(.custom("Georgia", size: 34)).tracking(-1).foregroundStyle(TBDTokens.ink)
      HStack(spacing: TBDTokens.Space.xl) {
        metric("\(day.threads.count)", "sessions")
        metric("\(Set(day.threads.map(\.category)).count)", "projects")
        metric("\(day.stats?.peakConcurrent ?? 0)", "at once")
        metric(hoursLabel(waiting), "waiting on you", color: waiting > 0 ? AgentWallPalette.waiting : nil)
      }
      Rectangle().fill(TBDTokens.border).frame(height: 1)
      HStack(spacing: TBDTokens.Space.xl) {
        metric(compact(tokens), cost > 0 ? "tokens · \(money(cost))" : "tokens")
        metric("+\(add.formatted())", "lines added", color: TBDTokens.fill)
        if del > 0 { metric("−\(del.formatted())", "removed", color: TBDTokens.alert) }
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .tbdCard(padding: TBDTokens.Space.lg)
  }
  private func metric(_ value: String, _ label: String, color: Color? = nil) -> some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(value).font(.system(size: 16, weight: .medium, design: .monospaced)).foregroundStyle(color ?? TBDTokens.ink)
      Text(label).font(.system(size: 11)).foregroundStyle(TBDTokens.muted)
    }
  }

  // MARK: Sessions
  private func sessions(_ day: AgentWallDay) -> some View {
    let local = day.threads.sorted { $0.start < $1.start }
    let remotes = remoteToday(day).sorted { $0.at < $1.at }
    return VStack(alignment: .leading, spacing: TBDTokens.Space.sm) {
      HStack { TBDLabel("Sessions"); Spacer(); if selectedThread != nil { Button("Clear") { selectedThread = nil }.buttonStyle(TBDButtonStyle(.quiet)) } }
      if local.isEmpty && remotes.isEmpty { Text("No sessions on this day.").font(.system(size: 12)).foregroundStyle(TBDTokens.muted) }
      ScrollView { VStack(alignment: .leading, spacing: 2) {
      ForEach(local) { t in
        let on = selectedThread == t.id
        Button { selectedThread = on ? nil : t.id } label: {
          HStack(alignment: .top, spacing: 10) {
            Image(on ? "AgentWallTealdeep" : "AgentWallTeal").resizable().scaledToFill().frame(width: 22, height: 8).clipShape(RoundedRectangle(cornerRadius: 1.5)).padding(.top, 4)
            VStack(alignment: .leading, spacing: 2) {
              Text(t.title ?? t.category).font(.system(size: 12, weight: on ? .semibold : .regular)).foregroundStyle(TBDTokens.ink).lineLimit(on ? 3 : 1)
              Text("\(t.category) · \(clockLabel(t.start))–\(clockLabel(t.end)) · \(hoursLabel(t.workingHours))" + (t.isActive ? " · running" : ""))
                .font(.system(size: 10, design: .monospaced)).foregroundStyle(TBDTokens.muted).lineLimit(1)
              if on, let summary = t.summary, !summary.isEmpty {
                Text(summary).font(.system(size: 11)).foregroundStyle(TBDTokens.ink).fixedSize(horizontal: false, vertical: true).padding(.top, 2)
              }
            }
            Spacer(minLength: 0)
          }
          .padding(6)
          .background(on ? TBDTokens.selected : .clear, in: RoundedRectangle(cornerRadius: TBDTokens.Radius.base))
          .contentShape(Rectangle())
        }.buttonStyle(.plain)
      }
      if !remotes.isEmpty {
        Rectangle().fill(TBDTokens.border).frame(height: 1).padding(.vertical, 4)
        TBDLabel("Portal agents")
        ForEach(remotes) { r in
          VStack(alignment: .leading, spacing: 2) {
            Text(r.title).font(.system(size: 12)).foregroundStyle(TBDTokens.ink).lineLimit(1)
            Text("\(r.agentName) · last active \(r.at.formatted(date: .omitted, time: .shortened))").font(.system(size: 10, design: .monospaced)).foregroundStyle(TBDTokens.muted)
          }.padding(.horizontal, 6)
        }
      }
      } }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .tbdCard(padding: TBDTokens.Space.lg)
  }

  // MARK: Controls
  private var controls: some View {
    VStack(alignment: .leading, spacing: 6) {
      TBDLabel("One brick · ten minutes")
      legendRow("AgentWallRed", "The wall")
      legendRow("AgentWallTeal", "Agent working")
      legendRow("AgentWallTealdeep", "Running now · selected")
      legendRow("AgentWallAmber", "Waiting on you")
      Toggle("Highlight waiting", isOn: $highlightWaiting).toggleStyle(.switch).tint(TBDTokens.fill).controlSize(.small).font(.system(size: 12))
      if account.signedIn {
        Toggle("Include Portal agents", isOn: $showRemote).toggleStyle(.switch).tint(TBDTokens.fill).controlSize(.small).font(.system(size: 12))
          .onChange(of: showRemote) { if showRemote { remote.refresh(force: true) } }
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .tbdCard(padding: TBDTokens.Space.lg)
  }
  private func legendRow(_ image: String, _ label: String) -> some View {
    HStack(spacing: 10) {
      Image(image).resizable().scaledToFill().frame(width: 26, height: 10).clipShape(RoundedRectangle(cornerRadius: 1.5))
      Text(label).font(.system(size: 12)).foregroundStyle(TBDTokens.ink)
    }
  }

  // MARK: Empty
  private var empty: some View {
    VStack(alignment: .leading, spacing: TBDTokens.Space.md) {
      Text(AgentPlaybackHost.shared.error != nil ? "Agents couldn’t start" : store.hasData ? "No agent sessions on this day" : "Laying the first bricks…")
        .font(TBDTokens.Typography.display).tracking(TBDTokens.Typography.displayTracking).foregroundStyle(TBDTokens.ink)
      Text(AgentPlaybackHost.shared.error ?? (store.hasData ? "Pick another day, or run a task in Codex or Claude Code." : "TBD reads your Codex and Claude Code session logs on this Mac. Run a task in either and it appears here."))
        .font(TBDTokens.Typography.body).foregroundStyle(TBDTokens.muted).textSelection(.enabled)
      if AgentPlaybackHost.shared.error != nil {
        Button("Try again") { AgentPlaybackHost.shared.start() }.buttonStyle(TBDButtonStyle(.primary))
      } else if !store.hasData {
        ProgressView().controlSize(.small)
      }
    }
    .frame(maxWidth: 560, alignment: .leading)
    .tbdCard(padding: TBDTokens.Space.xxl)
  }
}
