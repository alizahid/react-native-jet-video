import AVFoundation
import Foundation
import UIKit

enum AutoplayOverride {
  case none
  /// User explicitly paused: the coordinator never force-resumes this view.
  /// Cleared when the view scrolls fully off screen, plays, or changes source.
  case userPaused
  /// User explicitly played: this view wins the election unconditionally while
  /// it stays above the visibility threshold.
  case userPlaying
}

/// Tracks the visibility of every mounted video in a group and, from that:
/// - elects the single most-prominent `whenVisible` video and keeps it playing
///   while pausing all others (fully native: works with any scroll container
///   with no JS wiring), and
/// - leases a pooled player for every video that's even slightly on screen,
///   so it's loaded and prerolled before it's elected. Off-screen videos keep
///   theirs until the pool's LRU eviction needs the slot (`PlayerPool`).
/// Main-thread only.
final class PlaybackCoordinator {
  /// Global eligibility threshold — a view must be at least this visible to
  /// be elected (and stops playing below it). Overridable per view via the
  /// `minVisibleFraction` prop.
  static var minVisibleFraction: Double = 0.2
  static var hysteresis: Double = 0.10
  static let debounceTicks = 2
  /// How many times a visible errored video is rebuilt before giving up.
  /// Covers transient failures (decoder pressure, flaky network); reset on
  /// source change.
  static let maxErrorRetries = 2

  private static var groups: [String: PlaybackCoordinator] = [:]

  static func coordinator(forGroup group: String?) -> PlaybackCoordinator {
    let key = group ?? "default"
    if let existing = groups[key] {
      return existing
    }
    let coordinator = PlaybackCoordinator()
    groups[key] = coordinator
    return coordinator
  }

  private struct Tracking {
    var rect: CGRect = .null
    var fraction: Double = -1
    var offscreenTicks = 0
    var retries = 0
  }

  private struct Info {
    let view: HybridVideoView
    /// How much of the view (as its layout shows it) is on screen: eligibility.
    let fraction: Double
    /// How much of the screen the view's visible part covers.
    let prominence: Double
    /// Ranking: screen coverage discounted by how much of the video is cut
    /// off. Coverage alone let a tall video half-hidden under a transparent
    /// header keep playing over a short one fully in view below it (both
    /// covered ~25% of the screen); fraction alone let a short video fully in
    /// view beat a taller one that fills most of the screen.
    var score: Double { prominence * fraction }
    let rect: CGRect
    var coordinated: Bool { view.autoplayMode == .whenvisible }

    /// Reading order: topmost first, then leftmost — swapped for horizontal
    /// lists. Among comparably visible videos this decides who plays (the
    /// first one, like every major feed) and who stays warm.
    func precedes(_ other: Info) -> Bool {
      let horizontal = view.visibilityAxis == .horizontal
      let (a1, a2) = horizontal ? (rect.minX, rect.minY) : (rect.minY, rect.minX)
      let (b1, b2) = horizontal ? (other.rect.minX, other.rect.minY) : (other.rect.minY, other.rect.minX)
      return a1 != b1 ? a1 < b1 : a2 < b2
    }
  }

  private let members = NSHashTable<HybridVideoView>.weakObjects()
  private var displayLink: CADisplayLink?
  private weak var winner: HybridVideoView?
  private var challengerId: ObjectIdentifier?
  private var challengerTicks = 0
  private var tracking: [ObjectIdentifier: Tracking] = [:]
  private var dirty = true
  private var backgrounded = false
  private var observers: [NSObjectProtocol] = []

  init() {
    let center = NotificationCenter.default
    observers.append(center.addObserver(
      forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main
    ) { [weak self] _ in
      guard let self else { return }
      backgrounded = true
      for view in members.allObjects where view.autoplayMode == .whenvisible && !view.isInPictureInPicture {
        pauseIfPlaying(view)
      }
      displayLink?.isPaused = true
    })
    observers.append(center.addObserver(
      forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main
    ) { [weak self] _ in
      guard let self else { return }
      backgrounded = false
      dirty = true
      displayLink?.isPaused = false
    })
    // A phone call or Siri pauses the player behind our back; once it ends,
    // re-run the election so the winner resumes instead of sitting paused.
    observers.append(center.addObserver(
      forName: AVAudioSession.interruptionNotification, object: AVAudioSession.sharedInstance(), queue: .main
    ) { [weak self] note in
      guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
            AVAudioSession.InterruptionType(rawValue: raw) == .ended else { return }
      self?.dirty = true
    })
  }

  deinit {
    for observer in observers {
      NotificationCenter.default.removeObserver(observer)
    }
    displayLink?.invalidate()
  }

  // MARK: - Membership

  func register(_ view: HybridVideoView) {
    guard !members.contains(view) else { return }
    members.add(view)
    // ObjectIdentifier is a raw pointer: a new view allocated at a dead
    // view's address must not inherit its stale tracking (a spent retry
    // budget would silently disable error recovery for the new view).
    tracking[ObjectIdentifier(view)] = nil
    dirty = true
    startDisplayLinkIfNeeded()
  }

  func unregister(_ view: HybridVideoView) {
    guard members.contains(view) else { return }
    members.remove(view)
    tracking[ObjectIdentifier(view)] = nil
    if winner === view {
      winner = nil
    }
    dirty = true
    if members.count == 0 {
      stopDisplayLink()
    }
  }

  // MARK: - User intent

  func noteUserPlay(_ view: HybridVideoView) {
    guard view.autoplayMode == .whenvisible else { return }
    view.autoplayOverride = .userPlaying
    if winner !== view {
      if let old = winner {
        pauseIfPlaying(old)
      }
      winner = view
    }
    dirty = true
  }

  func noteUserPause(_ view: HybridVideoView) {
    guard view.autoplayMode == .whenvisible else { return }
    view.autoplayOverride = .userPaused
    if winner === view {
      winner = nil
    }
    dirty = true
  }

  func noteSourceChanged(_ view: HybridVideoView) {
    view.autoplayOverride = .none
    tracking[ObjectIdentifier(view)]?.retries = 0
    dirty = true
  }

  func noteStateInvalidated() {
    dirty = true
  }

  // MARK: - Display link

  private func startDisplayLinkIfNeeded() {
    guard displayLink == nil else { return }
    let link = CADisplayLink(target: self, selector: #selector(handleTick))
    link.preferredFrameRateRange = CAFrameRateRange(minimum: 5, maximum: 10, preferred: 10)
    link.add(to: .main, forMode: .common)
    link.isPaused = backgrounded
    displayLink = link
  }

  private func stopDisplayLink() {
    displayLink?.invalidate()
    displayLink = nil
    tracking.removeAll()
    challengerId = nil
    challengerTicks = 0
  }

  // MARK: - Tick

  @objc private func handleTick() {
    guard !backgrounded else { return }
    let active = members.allObjects
    guard !active.isEmpty else {
      stopDisplayLink()
      return
    }
    if let current = winner, current.autoplayMode != .whenvisible {
      winner = nil
      dirty = true
    }
    // While one of ours is fullscreen, everything else keeps its natural
    // visibility: treating the feed as covered would pause and demote its
    // cells, and re-electing them all during the exit animation is the jank
    // we're avoiding.
    let ignorePresentation = active.contains { $0.isFullscreen }

    var rectsChanged = false
    var infos: [Info] = []
    infos.reserveCapacity(active.count)

    for view in active {
      let id = ObjectIdentifier(view)
      var track = tracking[id] ?? Tracking()
      let (fraction, prominence, rect) = VisibilityTracker.visibleFraction(
        of: view.view,
        axis: view.visibilityAxis,
        ignorePresentation: ignorePresentation
      )
      view.lastVisibleFraction = fraction

      if track.rect != rect {
        track.rect = rect
        rectsChanged = true
      }
      if abs(track.fraction - fraction) > 0.01 {
        track.fraction = fraction
        view.onVisibilityChange(fraction)
      }
      track.offscreenTicks = fraction <= 0.001 ? track.offscreenTicks + 1 : 0

      if view.autoplayMode == .whenvisible {
        // A user-paused video that scrolls fully away gets a fresh start:
        // coming back on screen re-enables autoplay, matching familiar feed
        // behavior.
        if track.offscreenTicks >= 2, view.autoplayOverride == .userPaused {
          view.autoplayOverride = .none
          dirty = true
        }

        // A visible errored video gets rebuilt (bounded retries): transient
        // failures like decoder-session pressure from a heavy feed must not
        // leave a black cell on screen.
        if view.engine?.status == .error, fraction >= Self.threshold(for: view),
           track.retries < Self.maxErrorRetries {
          track.retries += 1
          view.engine?.retry()
          dirty = true
        }

        // A user-played video that drops below the threshold loses its
        // override: audio must never continue for an offscreen video
        // (outside PiP).
        if view.autoplayOverride == .userPlaying, fraction < Self.threshold(for: view) {
          view.autoplayOverride = .none
          pauseIfPlaying(view)
          if winner === view {
            winner = nil
          }
          dirty = true
        }
      }

      tracking[id] = track
      infos.append(Info(view: view, fraction: fraction, prominence: prominence, rect: rect))
    }

    if rectsChanged || dirty {
      dirty = false
      runElection(infos: infos, active: active)

      // Safety net: nothing but the winner may ever play in a coordinated
      // group. Playback can start outside the election's control (state
      // races, system behaviors) — e.g. AVPlayer preserves its rate across
      // a source swap, so before this sweep a recycled playing cell would
      // restart its NEW source at any visibility, and the election would
      // never notice a playing non-winner.
      // A view whose engine the winner is mirroring IS the winner's video
      // (the post screen taking over from the feed cell mid-transition).
      for info in infos
      where info.coordinated
        && info.view !== winner
        && !(info.view.engine != nil && info.view.engine === winner?.mirroredEngine)
        && !info.view.isFullscreen
        && !info.view.isInPictureInPicture {
        pauseIfPlaying(info.view)
      }
    }

    leaseWanted(infos: infos)
  }

  // MARK: - Leasing

  /// Any visible video (and the winner, fullscreen, PiP) holds a pooled
  /// player so it's ready the instant it's elected. Nothing is taken away
  /// here — the pool evicts by LRU when it needs a slot.
  private func leaseWanted(infos: [Info]) {
    for info in infos where info.fraction > 0.001 || info.view === winner
      || info.view.isFullscreen || info.view.isInPictureInPicture {
      info.view.ensureEngine(force: false)
    }
  }

  // MARK: - Election

  private func runElection(infos: [Info], active: [HybridVideoView]) {
    let coordinated = active.filter { $0.autoplayMode == .whenvisible }

    // A video in PiP suspends elections for its whole group: nothing else in
    // the group may play alongside it.
    if coordinated.contains(where: { $0.isInPictureInPicture }) {
      for view in coordinated where !view.isInPictureInPicture {
        pauseIfPlaying(view)
      }
      winner = nil
      challengerId = nil
      challengerTicks = 0
      return
    }

    if let forced = coordinated.first(where: { $0.autoplayOverride == .userPlaying }) {
      challengerId = nil
      challengerTicks = 0
      crown(forced)
      return
    }

    // A fullscreen video stays eligible regardless of its inline rect (which
    // may be covered by the presentation itself).
    let eligible = infos.filter { info in
      info.coordinated
        && (info.view.isFullscreen || info.fraction >= Self.threshold(for: info.view))
        && info.view.autoplayOverride != .userPaused
        && info.view.source != nil
        && info.view.engine?.status != .error
    }

    guard !eligible.isEmpty else {
      if let current = winner {
        pauseIfPlaying(current)
        winner = nil
      }
      challengerId = nil
      challengerTicks = 0
      return
    }

    // Ranking: the decisively higher score wins; when scores are comparable
    // (within hysteresis — 10% of the screen), the first in reading order.
    func outranks(_ a: Info, _ b: Info) -> Bool {
      if a.score > b.score + Self.hysteresis { return true }
      if b.score > a.score + Self.hysteresis { return false }
      return a.precedes(b)
    }

    var best = eligible[0]
    for candidate in eligible.dropFirst() where outranks(candidate, best) {
      best = candidate
    }

    let incumbent = winner.flatMap { current in
      eligible.first { $0.view === current }
    }

    guard let incumbent else {
      // No incumbent (or it became ineligible): switch immediately.
      challengerId = nil
      challengerTicks = 0
      crown(best.view)
      return
    }

    if best.view === incumbent.view {
      challengerId = nil
      challengerTicks = 0
      crown(incumbent.view)
      return
    }

    // Dethroning must be sustained for consecutive ticks so two videos
    // trading places mid-scroll don't flap. (`best` already outranks the
    // incumbent: clearly more visible, or comparably visible and earlier in
    // reading order.)
    do {
      let id = ObjectIdentifier(best.view)
      if challengerId == id {
        challengerTicks += 1
      } else {
        challengerId = id
        challengerTicks = 1
      }
      if challengerTicks >= Self.debounceTicks {
        challengerId = nil
        challengerTicks = 0
        crown(best.view)
      } else {
        // Keep evaluating on the next tick even if nothing else changes — a
        // challenge begun on the last rect change of a scroll (or a state
        // invalidation) must still resolve in a now-static scene.
        dirty = true
      }
    }
  }

  private func crown(_ view: HybridVideoView) {
    if winner !== view {
      if let old = winner {
        pauseIfPlaying(old)
      }
      winner = view
    }
    switch view.engine?.status {
    case .playing, .buffering, .error:
      break
    default:
      view.coordinatorPlay()
    }
  }

  /// Per-view eligibility threshold: the view's `minVisibleFraction` prop
  /// when set (non-negative), else the global (configureAutoplay) value.
  private static func threshold(for view: HybridVideoView) -> Double {
    let fraction = view.minVisibleFraction
    return fraction >= 0 ? min(1, fraction) : minVisibleFraction
  }

  private func isPlaying(_ view: HybridVideoView) -> Bool {
    view.isPlaying
  }

  private func pauseIfPlaying(_ view: HybridVideoView) {
    if view.isPlaying {
      view.engine?.pause(reason: .coordinator)
    }
  }
}
