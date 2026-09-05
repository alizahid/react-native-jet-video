import Foundation

/// The process-wide set of player engines, keyed by `playerKey` (the source
/// uri unless the app sets one) and bounded to `maxPlayers`.
///
/// A view *leases* the engine for its key. The same key in two places — a
/// feed cell and the post screen it opens — is one engine, so navigating
/// between them continues playback at the same frame with no reload. When
/// the pool is full, the least recently used engine that nothing is
/// displaying is destroyed and its playhead remembered, so the video resumes
/// where it was should it come back. Main-thread only.
final class PlayerPool {
  static let shared = PlayerPool()
  static var maxPlayers = 10
  /// Remembered playheads for evicted engines.
  private static let maxPositions = 200

  private var engines: [String: PlayerEngine] = [:]
  private var positions: [String: Double] = [:]
  private var positionOrder: [String] = []

  func engine(for key: String) -> PlayerEngine? {
    engines[key]
  }

  func rememberedPosition(for key: String) -> Double {
    positions[key] ?? 0
  }

  /// Takes control of the engine for `key` on behalf of `view`, creating
  /// (and if needed evicting) as required. Returns nil when the engine is
  /// pinned to another view by fullscreen or PiP — the caller can still
  /// mirror it.
  func lease(key: String, source: VideoSource, for view: HybridVideoView) -> PlayerEngine? {
    if let engine = engines[key] {
      engine.lastUsed = Date()
      if let owner = engine.owner, owner !== view {
        guard !owner.isFullscreen, !owner.isInPictureInPicture else { return nil }
        owner.engineWasTaken(engine)
      }
      engine.owner = view
      engine.setSource(source)
      return engine
    }
    evictIfNeeded()
    let engine = PlayerEngine(key: key)
    engine.owner = view
    engine.setSource(source, resumeAt: positions[key] ?? 0)
    engines[key] = engine
    return engine
  }

  /// Gives up control without leaving the pool: the engine idles (playhead
  /// intact) for whoever leases the key next. Playback stops right away
  /// unless another view is still mirroring it — the mirror is about to take
  /// over (a screen pop) and must not see a gap.
  func release(_ engine: PlayerEngine, from view: HybridVideoView) {
    guard engine.owner === view else { return }
    engine.owner = nil
    engine.lastUsed = Date()
    if engine.mirrorCount == 0 {
      engine.pause(reason: .system)
    }
    // Idle after a grace, unless re-leased: the feed cell under a popped
    // screen re-leases within a tick and expects the live item.
    DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
      guard engine.owner == nil else { return }
      engine.pause(reason: .system)
      engine.hibernate()
    }
  }

  private func evictIfNeeded() {
    while engines.count >= Self.maxPlayers, let victim = evictionCandidate() {
      destroy(victim)
    }
  }

  /// Oldest engine nothing depends on: unowned first, then owned but not
  /// displayed. Fullscreen/PiP/visible engines are never evicted — the pool
  /// grows past its cap rather than blanking something on screen.
  private func evictionCandidate() -> PlayerEngine? {
    let byAge = engines.values.sorted { $0.lastUsed < $1.lastUsed }
    if let unowned = byAge.first(where: { $0.owner == nil && !FullscreenPresenter.shared.isPresenting(engine: $0) }) {
      return unowned
    }
    return byAge.first { engine in
      guard let owner = engine.owner else { return false }
      return !owner.isDisplayed && !owner.isFullscreen && !owner.isInPictureInPicture
    }
  }

  private func destroy(_ engine: PlayerEngine) {
    remember(engine.currentTime, for: engine.key)
    engine.pause(reason: .system)
    engines[engine.key] = nil
    engine.owner?.engineEvicted(engine)
  }

  private func remember(_ position: Double, for key: String) {
    guard position > 0.1 else {
      positions[key] = nil
      return
    }
    if positions[key] == nil {
      positionOrder.append(key)
      if positionOrder.count > Self.maxPositions {
        positions[positionOrder.removeFirst()] = nil
      }
    }
    positions[key] = position
  }
}
