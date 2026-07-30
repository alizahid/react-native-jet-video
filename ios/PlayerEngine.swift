import AVFoundation
import Foundation

protocol PlayerEngineDelegate: AnyObject {
  func engine(_ engine: PlayerEngine, didChangeStatus status: PlaybackStatus, reason: PlaybackChangeReason)
  func engine(_ engine: PlayerEngine, didLoad event: LoadEvent)
  func engine(_ engine: PlayerEngine, didProgress event: ProgressEvent)
  func engineDidPlayToEnd(_ engine: PlayerEngine)
  func engine(_ engine: PlayerEngine, didFail error: VideoErrorEvent)
}

/// Owns an AVPlayer + AVPlayerItem and all their observers, and reduces their
/// combined state into a single `PlaybackStatus` stream. Decoupled from the
/// view so fullscreen/PiP can retain playback across cell recycling.
final class PlayerEngine {
  let player = AVPlayer()
  weak var delegate: PlayerEngineDelegate?

  private(set) var status: PlaybackStatus = .idle
  private(set) var sourceUri: String?
  /// True while the item is torn down because the view is detached from any
  /// window (covered screen in a navigation stack). The source and resume
  /// position are kept so `wake()` can rebuild transparently.
  private(set) var isHibernated = false

  private var currentSource: VideoSource?
  private var resumeTime: Double = 0
  // Set when the loaded item reports an indefinite duration. A live stream
  // must never be resumed at a wall-clock position after hibernation — the
  // old offset points into a sliding window that has since moved.
  private var isLiveStream = false

  var loop = false
  var isMuted: Bool {
    get { player.isMuted }
    set { player.isMuted = newValue }
  }
  var volume: Double {
    get { Double(player.volume) }
    set { player.volume = Float(newValue) }
  }
  var currentTime: Double {
    if isHibernated {
      return resumeTime
    }
    let time = player.currentTime()
    return time.isValid ? max(0, time.seconds) : 0
  }
  var progressIntervalMs: Double = 500 {
    didSet {
      guard progressIntervalMs != oldValue else { return }
      rebuildTimeObserver()
    }
  }

  /// A player that isn't actively playing keeps only a small forward buffer:
  /// warm enough for an instant start, without buffering the whole feed. The
  /// playing player gets the system default. Applied on every
  /// timeControlStatus change and item attach.
  private func applyBufferPolicy() {
    let active = player.timeControlStatus != .paused
    player.currentItem?.preferredForwardBufferDuration = active ? 0 : 2
  }

  /// Invoked right before playback starts. Receives a `proceed` continuation:
  /// the owner configures the audio session (possibly asynchronously, off the
  /// main thread) and calls `proceed` once it's safe to render audio.
  var willPlay: ((@escaping () -> Void) -> Void)?

  /// Monotonic token for in-flight play intents: a pause or source change
  /// after play() was called must win over the (possibly async) session
  /// configuration completing.
  private var playIntent = 0

  /// While set, an externally-initiated pause is immediately reverted — AVKit
  /// implicitly pauses the player during fullscreen present/dismiss, which
  /// otherwise freezes the video and gaps the audio for the length of the
  /// animation. Cleared by any explicit pause.
  private var transitionHold = false

  func beginTransitionPlaybackHold() {
    guard status == .playing || status == .buffering else { return }
    transitionHold = true
  }

  func endTransitionPlaybackHold() {
    transitionHold = false
  }

  // The reason attached to the next play/pause-driven status transition.
  private var pendingReason: PlaybackChangeReason = .system
  private var reachedEnd = false
  private var didEmitLoad = false

  private var itemStatusObservation: NSKeyValueObservation?
  private var timeControlObservation: NSKeyValueObservation?
  private var timeObserverToken: Any?
  private var endObserver: NSObjectProtocol?
  // Strong: the asset's resourceLoader delegate is weakly referenced by AVFoundation.
  private var resourceLoader: CachingResourceLoader?

  init() {
    player.automaticallyWaitsToMinimizeStalling = true
    timeControlObservation = player.observe(\.timeControlStatus) { [weak self] _, _ in
      DispatchQueue.main.async {
        guard let self else { return }
        if self.transitionHold, !self.reachedEnd, self.player.timeControlStatus == .paused {
          self.player.play()
        }
        self.applyBufferPolicy()
        self.recomputeStatus()
      }
    }
    rebuildTimeObserver()
  }

  deinit {
    if let token = timeObserverToken {
      player.removeTimeObserver(token)
    }
    detachItemObservers()
    resourceLoader?.invalidate()
  }

  // MARK: - Source

  func setSource(_ source: VideoSource?) {
    let uri = source?.uri
    guard uri != sourceUri else {
      // Same uri re-set (list re-render): keep playback/hibernation state,
      // just refresh the stored source so headers/cache flags stay current.
      if source != nil { currentSource = source }
      return
    }
    sourceUri = uri
    currentSource = source
    isHibernated = false
    resumeTime = 0
    isLiveStream = false
    playIntent += 1

    // replaceCurrentItem preserves the player's rate: a recycled cell whose
    // engine was playing would silently start the NEW source the moment it
    // loads — at any visibility, without any play() call. A source change
    // always starts paused; autoplay/coordinator decide from there.
    player.pause()

    detachItem()
    reachedEnd = false
    didEmitLoad = false

    guard let source, let url = URL(string: source.uri) else {
      transition(to: .idle, reason: .system)
      if source != nil {
        delegate?.engine(self, didFail: VideoErrorEvent(code: "invalid-source", message: "Could not parse source URI"))
      }
      return
    }

    attachItem(source: source, url: url)
    transition(to: .loading, reason: .system)
  }

  // MARK: - Hibernation

  /// Tears down the AVPlayerItem (buffers, resource loader, decoder claims)
  /// while keeping the source and playhead so `wake()` can rebuild. Called
  /// when the view leaves the window — a covered screen costs ~nothing.
  func hibernate() {
    guard !isHibernated, player.currentItem != nil else { return }
    resumeTime = isLiveStream ? 0 : currentTime
    isHibernated = true
    detachItem()
  }

  /// Rebuilds the item after hibernation and restores the playhead. The disk
  /// cache makes this cheap: previously streamed ranges re-serve from disk.
  func wake() {
    guard isHibernated else { return }
    isHibernated = false
    guard let source = currentSource, let url = URL(string: source.uri) else { return }
    attachItem(source: source, url: url)
    if resumeTime > 0.1 {
      player.seek(to: CMTime(seconds: resumeTime, preferredTimescale: 600))
    }
    resumeTime = 0
    // An engine that hibernated in .error has a fresh item now — report it as
    // loading so readiness can transition normally (and the coordinator
    // doesn't burn a retry on an already-rebuilt item).
    if status == .error {
      transition(to: .loading, reason: .system)
    }
  }

  /// Rebuilds a failed item from scratch. Transient failures (decoder
  /// pressure, flaky network) are recoverable; without this an errored view
  /// stayed black until its cell recycled.
  func retry() {
    guard status == .error, let source = currentSource, let url = URL(string: source.uri) else { return }
    isHibernated = false
    resumeTime = 0
    detachItem()
    reachedEnd = false
    didEmitLoad = false
    attachItem(source: source, url: url)
    transition(to: .loading, reason: .system)
  }

  private func detachItem() {
    detachItemObservers()
    player.replaceCurrentItem(with: nil)
    resourceLoader?.invalidate()
    resourceLoader = nil
  }

  private func attachItem(source: VideoSource, url: URL) {
    let asset: AVURLAsset
    if source.cache ?? true, let assetURL = CachingResourceLoader.assetURL(for: url) {
      let loader = CachingResourceLoader(originalURL: url, headers: source.headers ?? [:])
      asset = AVURLAsset(url: assetURL)
      asset.resourceLoader.setDelegate(loader, queue: loader.queue)
      resourceLoader = loader
    } else {
      var options: [String: Any] = [:]
      if let headers = source.headers, !headers.isEmpty {
        options["AVURLAssetHTTPHeaderFieldsKey"] = headers
      }
      asset = AVURLAsset(url: url, options: options)
    }
    let item = AVPlayerItem(asset: asset)
    attachObservers(to: item)
    player.replaceCurrentItem(with: item)
    applyBufferPolicy()
  }

  // MARK: - Controls

  func play(reason: PlaybackChangeReason) {
    if isHibernated {
      wake()
    }
    if status == .error {
      retry()
    }
    playIntent += 1
    let intent = playIntent
    let start = { [weak self] in
      guard let self, playIntent == intent else { return }
      pendingReason = reason
      if reachedEnd {
        reachedEnd = false
        player.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .positiveInfinity)
      }
      player.play()
    }
    if let willPlay {
      willPlay(start)
    } else {
      start()
    }
  }

  func pause(reason: PlaybackChangeReason) {
    playIntent += 1
    transitionHold = false
    pendingReason = reason
    player.pause()
  }

  func seek(to seconds: Double, completion: @escaping () -> Void) {
    if isHibernated {
      // No item to seek — retarget the wake resume position instead.
      resumeTime = max(0, seconds)
      reachedEnd = false
      DispatchQueue.main.async { completion() }
      return
    }
    let time = CMTime(seconds: seconds, preferredTimescale: 600)
    reachedEnd = false
    player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero) { _ in
      DispatchQueue.main.async { completion() }
    }
  }

  // MARK: - Observation

  // Both observers guard against stale delivery: their blocks are enqueued to
  // main from AVFoundation's threads, so a block can still run after
  // setSource/hibernate replaced the item it was observing — acting on it
  // would corrupt the new item's state machine (or, with loop on, auto-play
  // the wrong source).
  private func attachObservers(to item: AVPlayerItem) {
    itemStatusObservation = item.observe(\.status) { [weak self, weak item] _, _ in
      DispatchQueue.main.async {
        guard let self, let item, item === self.player.currentItem else { return }
        self.itemStatusChanged(for: item)
      }
    }
    endObserver = NotificationCenter.default.addObserver(
      forName: AVPlayerItem.didPlayToEndTimeNotification,
      object: item,
      queue: .main
    ) { [weak self, weak item] _ in
      guard let self, let item, item === player.currentItem else { return }
      itemDidPlayToEnd()
    }
  }

  private func detachItemObservers() {
    itemStatusObservation?.invalidate()
    itemStatusObservation = nil
    if let endObserver {
      NotificationCenter.default.removeObserver(endObserver)
      self.endObserver = nil
    }
  }

  private func rebuildTimeObserver() {
    if let token = timeObserverToken {
      player.removeTimeObserver(token)
      timeObserverToken = nil
    }
    guard progressIntervalMs > 0 else { return }
    let interval = CMTime(seconds: progressIntervalMs / 1000, preferredTimescale: 600)
    timeObserverToken = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
      guard let self, self.player.currentItem != nil, time.isValid else { return }
      let currentTime = max(0, time.seconds)
      self.delegate?.engine(
        self,
        didProgress: ProgressEvent(
          currentTime: currentTime,
          bufferedPosition: max(currentTime, self.bufferedPosition())
        )
      )
    }
  }

  /// Absolute position up to which media is buffered contiguously from the
  /// playhead (the end of the loaded range containing it). Falls back to the
  /// playhead itself when nothing ahead is buffered.
  private func bufferedPosition() -> Double {
    guard let item = player.currentItem else { return 0 }
    let current = player.currentTime()
    for value in item.loadedTimeRanges {
      let range = value.timeRangeValue
      if range.containsTime(current) {
        let end = CMTimeAdd(range.start, range.duration).seconds
        return end.isFinite ? max(0, end) : 0
      }
    }
    return current.seconds.isFinite ? max(0, current.seconds) : 0
  }

  // MARK: - State machine

  private func itemStatusChanged(for item: AVPlayerItem) {
    switch item.status {
    case .readyToPlay:
      if !didEmitLoad {
        didEmitLoad = true
        let duration = item.duration
        let isLive = duration.isIndefinite
        isLiveStream = isLive
        delegate?.engine(
          self,
          didLoad: LoadEvent(
            duration: isLive ? -1 : duration.seconds,
            naturalWidth: Double(item.presentationSize.width),
            naturalHeight: Double(item.presentationSize.height),
            isLive: isLive
          )
        )
        if status == .loading {
          transition(to: .readytoplay, reason: .system)
        }
      }
    case .failed:
      let nsError = item.error as NSError?
      delegate?.engine(
        self,
        didFail: VideoErrorEvent(
          code: nsError.map { "\($0.domain):\($0.code)" } ?? "unknown",
          message: nsError?.localizedDescription ?? "Playback failed"
        )
      )
      transition(to: .error, reason: .system)
    default:
      break
    }
  }

  private func itemDidPlayToEnd() {
    if loop {
      pendingReason = .system
      player.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .positiveInfinity)
      player.play()
    } else {
      reachedEnd = true
      transition(to: .ended, reason: .system)
    }
    delegate?.engineDidPlayToEnd(self)
  }

  private func recomputeStatus() {
    guard let item = player.currentItem, item.status == .readyToPlay else { return }
    switch player.timeControlStatus {
    case .playing:
      transition(to: .playing, reason: pendingReason)
    case .waitingToPlayAtSpecifiedRate:
      transition(to: .buffering, reason: pendingReason)
    case .paused:
      // Keep readyToPlay/ended/error as-is; only report an actual pause of playback.
      if status == .playing || status == .buffering {
        transition(to: reachedEnd ? .ended : .paused, reason: pendingReason)
      }
    @unknown default:
      break
    }
  }

  private func transition(to newStatus: PlaybackStatus, reason: PlaybackChangeReason) {
    guard newStatus != status else { return }
    status = newStatus
    delegate?.engine(self, didChangeStatus: newStatus, reason: reason)
  }
}
