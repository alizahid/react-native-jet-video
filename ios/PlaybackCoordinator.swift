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

/// Elects, per group, the single most-visible `whenVisible` video and keeps it
/// playing while pausing all others. Fully native: works with any scroll
/// container (FlashList, ScrollView, nested scrolls) with no JS wiring.
/// Main-thread only.
final class PlaybackCoordinator {
  static var minVisibleFraction: Double = 0.5
  static var hysteresis: Double = 0.10
  static let debounceTicks = 2

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

  private let members = NSHashTable<HybridVideoView>.weakObjects()
  private var displayLink: CADisplayLink?
  private weak var winner: HybridVideoView?
  private var challengerId: ObjectIdentifier?
  private var challengerTicks = 0
  private var lastRects: [ObjectIdentifier: CGRect] = [:]
  private var lastFractions: [ObjectIdentifier: Double] = [:]
  private var offscreenTicks: [ObjectIdentifier: Int] = [:]
  private var dirty = true
  private var backgrounded = false
  private var lifecycleObservers: [NSObjectProtocol] = []

  init() {
    lifecycleObservers.append(
      NotificationCenter.default.addObserver(
        forName: UIApplication.didEnterBackgroundNotification,
        object: nil,
        queue: .main
      ) { [weak self] _ in
        guard let self else { return }
        backgrounded = true
        for view in members.allObjects where !view.isInPictureInPicture {
          pauseIfPlaying(view)
        }
        displayLink?.isPaused = true
      }
    )
    lifecycleObservers.append(
      NotificationCenter.default.addObserver(
        forName: UIApplication.didBecomeActiveNotification,
        object: nil,
        queue: .main
      ) { [weak self] _ in
        guard let self else { return }
        backgrounded = false
        dirty = true
        displayLink?.isPaused = false
      }
    )
  }

  deinit {
    for observer in lifecycleObservers {
      NotificationCenter.default.removeObserver(observer)
    }
    displayLink?.invalidate()
  }

  // MARK: - Membership

  func register(_ view: HybridVideoView) {
    guard !members.contains(view) else { return }
    members.add(view)
    view.engine.warmBufferOnly = true
    dirty = true
    startDisplayLinkIfNeeded()
  }

  func unregister(_ view: HybridVideoView) {
    guard members.contains(view) else { return }
    members.remove(view)
    view.engine.warmBufferOnly = false
    let id = ObjectIdentifier(view)
    lastRects[id] = nil
    lastFractions[id] = nil
    offscreenTicks[id] = nil
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
    view.autoplayOverride = .userPaused
    if winner === view {
      winner = nil
    }
    dirty = true
  }

  func noteSourceChanged(_ view: HybridVideoView) {
    view.autoplayOverride = .none
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
    lastRects.removeAll()
    lastFractions.removeAll()
    offscreenTicks.removeAll()
    challengerId = nil
    challengerTicks = 0
  }

  // MARK: - Election

  @objc private func handleTick() {
    guard !backgrounded else { return }
    let active = members.allObjects
    guard !active.isEmpty else {
      stopDisplayLink()
      return
    }

    var rectsChanged = false
    var infos: [(view: HybridVideoView, fraction: Double, rect: CGRect)] = []
    infos.reserveCapacity(active.count)

    for view in active {
      let id = ObjectIdentifier(view)
      let (fraction, rect) = VisibilityTracker.visibleFraction(of: view.view)

      if lastRects[id] != rect {
        lastRects[id] = rect
        rectsChanged = true
      }
      if abs((lastFractions[id] ?? -1) - fraction) > 0.01 {
        lastFractions[id] = fraction
        view.onVisibilityChange?(fraction)
      }

      // A user-paused video that scrolls fully away gets a fresh start: coming
      // back on screen re-enables autoplay, matching familiar feed behavior.
      if fraction <= 0.001 {
        offscreenTicks[id, default: 0] += 1
        if offscreenTicks[id, default: 0] >= 2, view.autoplayOverride == .userPaused {
          view.autoplayOverride = .none
          dirty = true
        }
      } else {
        offscreenTicks[id] = 0
      }

      // A user-played video that drops below the threshold loses its override:
      // audio must never continue for an offscreen video (outside PiP).
      if view.autoplayOverride == .userPlaying, fraction < Self.minVisibleFraction {
        view.autoplayOverride = .none
        pauseIfPlaying(view)
        if winner === view {
          winner = nil
        }
        dirty = true
      }

      infos.append((view, fraction, rect))
    }

    guard rectsChanged || dirty else { return }
    dirty = false

    // A video in PiP suspends elections for its whole group: nothing else in
    // the group may play alongside it.
    if active.contains(where: { $0.isInPictureInPicture }) {
      for view in active where !view.isInPictureInPicture {
        pauseIfPlaying(view)
      }
      winner = nil
      challengerId = nil
      challengerTicks = 0
      return
    }

    if let forced = active.first(where: { $0.autoplayOverride == .userPlaying }) {
      challengerId = nil
      challengerTicks = 0
      crown(forced)
      return
    }

    let eligible = infos.filter { info in
      info.fraction >= Self.minVisibleFraction
        && info.view.autoplayOverride != .userPaused
        && info.view.engine.sourceUri != nil
        && info.view.engine.status != .error
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

    // Best candidate: highest fraction, ties broken topmost then leftmost.
    let best = eligible.max { a, b in
      if a.fraction != b.fraction { return a.fraction < b.fraction }
      if a.rect.minY != b.rect.minY { return a.rect.minY > b.rect.minY }
      return a.rect.minX > b.rect.minX
    }!

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

    // Hysteresis + debounce: a challenger must beat the incumbent by a margin,
    // for consecutive ticks, before the election flips. Prevents flapping when
    // two videos are near 50/50 during scroll.
    if best.fraction > incumbent.fraction + Self.hysteresis {
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
      }
    } else {
      challengerId = nil
      challengerTicks = 0
      crown(incumbent.view)
    }
  }

  private func crown(_ view: HybridVideoView) {
    if winner !== view {
      if let old = winner {
        pauseIfPlaying(old)
        old.engine.warmBufferOnly = true
      }
      winner = view
    }
    view.engine.warmBufferOnly = false
    switch view.engine.status {
    case .playing, .buffering, .error:
      break
    default:
      view.engine.play(reason: .coordinator)
    }
  }

  private func pauseIfPlaying(_ view: HybridVideoView) {
    switch view.engine.status {
    case .playing, .buffering:
      view.engine.pause(reason: .coordinator)
    default:
      break
    }
  }
}
