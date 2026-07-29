import AVKit
import Foundation
import NitroModules
import UIKit

class HybridVideoView: HybridVideoViewSpec {
  private let surface = PlayerLayerView()
  private let posterView = PosterView(frame: .zero)
  private(set) var engine = PlayerEngine()
  private var readyForDisplayObservation: NSKeyValueObservation?
  private var controlsReadyObservation: NSKeyValueObservation?
  private var mutedObservation: NSKeyValueObservation?
  private var embeddedController: AVPlayerViewController?
  // Resolves the exitFullscreen() promise for the embedded-controls surface,
  // where AVKit drives the transition and completion arrives via delegate.
  var pendingFullscreenExitCompletion: (() -> Void)?

  /// True while the embedded AVPlayerViewController owns rendering (the
  /// inline surface layer is deliberately blank then).
  var hasEmbeddedControls: Bool { embeddedController != nil }
  private lazy var pipManager = PictureInPictureManager(owner: self)
  private lazy var controllerDelegateProxy = PlayerControllerDelegateProxy(owner: self)

  // Coordinator-owned state (read/written on main only).
  var autoplayOverride: AutoplayOverride = .none
  var isInPictureInPicture = false
  var isFullscreen = false
  private var coordinator: PlaybackCoordinator?
  private var hibernateWorkItem: DispatchWorkItem?
  // Playback was interrupted by the window detach itself (screen covered),
  // so reattaching should resume it. Coordinated views are excluded — the
  // election decides who plays.
  private var resumePlaybackOnAttach = false

  /// Grace before tearing the item down on window detach, so transient
  /// detaches (navigation transitions, interactive-pop cancels, view
  /// reordering) don't thrash rebuild cycles.
  private static let hibernateGraceSeconds: TimeInterval = 1.0

  var view: UIView { surface }

  deinit {
    hibernateWorkItem?.cancel()
    // The parent VC's containment retains the embedded controller (and via
    // controller.player, the whole player stack) past this view's dealloc —
    // detach it explicitly. UIKit work must run on main; deinit may not be.
    if let controller = embeddedController {
      DispatchQueue.main.async {
        controller.willMove(toParent: nil)
        controller.view.removeFromSuperview()
        controller.removeFromParent()
        controller.player = nil
      }
    }
  }

  override init() {
    super.init()
    engine.delegate = self
    surface.player = engine.player
    attachEngineHooks()
    observeEnginePlayer()

    posterView.isHidden = true
    posterView.translatesAutoresizingMaskIntoConstraints = false
    surface.addSubview(posterView)
    NSLayoutConstraint.activate([
      posterView.leadingAnchor.constraint(equalTo: surface.leadingAnchor),
      posterView.trailingAnchor.constraint(equalTo: surface.trailingAnchor),
      posterView.topAnchor.constraint(equalTo: surface.topAnchor),
      posterView.bottomAnchor.constraint(equalTo: surface.bottomAnchor),
    ])

    readyForDisplayObservation = surface.playerLayer.observe(\.isReadyForDisplay) { [weak self] layer, _ in
      DispatchQueue.main.async {
        if layer.isReadyForDisplay {
          self?.posterView.isHidden = true
        }
      }
    }

    surface.onWindowChanged = { [weak self] in
      self?.handleWindowChanged()
    }
  }

  // MARK: - Props

  var source: VideoSource? = nil {
    didSet {
      let changed = source?.uri != engine.sourceUri
      if changed, isFullscreen {
        // This cell is being recycled while its engine is presented fullscreen.
        // Orphan the fullscreen engine (the presenter holds it strongly) and
        // continue with a fresh one so the new cell content is independent.
        detachEngineForFullscreenOrphan()
      }
      engine.setSource(source)
      if changed {
        posterView.isHidden = posterUri == nil
        autoplayOverride = .none
        resumePlaybackOnAttach = false
        coordinator?.noteSourceChanged(self)
      }
      updateCoordinatorRegistration()
      applyAutoplay()
      // A source swap while covered (data refresh behind a pushed screen)
      // attaches a live item — release it again once the grace passes.
      if surface.window == nil, !isInPictureInPicture, !isFullscreen {
        scheduleHibernate()
      }
    }
  }

  var autoplayMode: AutoplayMode = .off {
    didSet {
      guard autoplayMode != oldValue else { return }
      updateCoordinatorRegistration()
      applyAutoplay()
    }
  }

  var muted: Bool = false {
    didSet {
      // Session config must precede the unmute: flipping the category or
      // activating the session while unmuted samples are already rendering
      // reconfigures the audio graph mid-stream and audibly pops.
      if !muted, engine.status == .playing || engine.status == .buffering {
        AudioSessionManager.shared.willPlay(muted: false, mixMode: audioMixMode)
      }
      engine.isMuted = muted
    }
  }

  var loop: Bool = false {
    didSet { engine.loop = loop }
  }

  var volume: Double = 1 {
    didSet { engine.volume = volume }
  }

  var resizeMode: ResizeMode = .cover {
    didSet {
      surface.resizeMode = resizeMode
      embeddedController?.videoGravity = PlayerLayerView.gravity(for: resizeMode)
    }
  }

  var controls: Bool = false {
    didSet {
      guard controls != oldValue else { return }
      updateControlsSurface()
    }
  }

  var posterUri: String? = nil {
    didSet {
      posterView.setPoster(uri: posterUri)
      if posterUri == nil {
        posterView.isHidden = true
      } else if !surface.playerLayer.isReadyForDisplay {
        posterView.isHidden = false
      }
    }
  }

  var allowsPictureInPicture: Bool = false {
    didSet {
      embeddedController?.allowsPictureInPicturePlayback = allowsPictureInPicture
      embeddedController?.canStartPictureInPictureAutomaticallyFromInline = allowsPictureInPicture
      updatePiPSetup()
    }
  }

  var progressUpdateInterval: Double = 500 {
    didSet { engine.progressIntervalMs = progressUpdateInterval }
  }

  var audioMixMode: AudioMixMode = .mixwithothers

  var coordinatorGroup: String? = nil {
    didSet {
      guard coordinatorGroup != oldValue else { return }
      updateCoordinatorRegistration()
    }
  }

  var onLoad: ((LoadEvent) -> Void)? = nil
  var onProgress: ((ProgressEvent) -> Void)? = nil
  var onEnd: (() -> Void)? = nil
  var onError: ((VideoErrorEvent) -> Void)? = nil
  var onPlaybackStateChange: ((PlaybackStateEvent) -> Void)? = nil
  var onFullscreenChange: ((Bool) -> Void)? = nil
  var onPictureInPictureChange: ((Bool) -> Void)? = nil
  var onMutedChange: ((Bool) -> Void)? = nil
  var onVisibilityChange: ((Double) -> Void)? = nil

  // MARK: - Methods

  func play() throws {
    DispatchQueue.main.async { [self] in
      coordinator?.noteUserPlay(self)
      engine.play(reason: .user)
    }
  }

  func pause() throws {
    DispatchQueue.main.async { [self] in
      coordinator?.noteUserPause(self)
      engine.pause(reason: .user)
    }
  }

  func seek(seconds: Double) throws -> Promise<Void> {
    let promise = Promise<Void>()
    DispatchQueue.main.async { [self] in
      engine.seek(to: seconds) {
        promise.resolve(withResult: ())
      }
    }
    return promise
  }

  func getCurrentTime() throws -> Double {
    engine.currentTime
  }

  func enterFullscreen() throws -> Promise<Void> {
    let promise = Promise<Void>()
    DispatchQueue.main.async { [self] in
      guard !isFullscreen else {
        promise.resolve(withResult: ())
        return
      }
      FullscreenPresenter.shared.enter(for: self) { error in
        if let error {
          promise.reject(withError: error)
        } else {
          promise.resolve(withResult: ())
        }
      }
    }
    return promise
  }

  func exitFullscreen() throws -> Promise<Void> {
    let promise = Promise<Void>()
    DispatchQueue.main.async { [self] in
      if FullscreenPresenter.shared.isPresenting {
        FullscreenPresenter.shared.exit { error in
          if let error {
            promise.reject(withError: error)
          } else {
            promise.resolve(withResult: ())
          }
        }
      } else if isFullscreen, let embeddedController {
        // System-initiated fullscreen from the embedded controls surface.
        // AVKit drives the transition; resolve once the delegate reports the
        // exit finished (fullscreenTransition(active: false)).
        pendingFullscreenExitCompletion = {
          promise.resolve(withResult: ())
        }
        FullscreenPresenter.performTransition(
          embeddedController,
          selectorName: "exitFullScreenAnimated:completionHandler:"
        )
      } else {
        promise.reject(withError: VideoViewError.notInFullscreen)
      }
    }
    return promise
  }

  // MARK: - Fullscreen state (called by FullscreenPresenter / controls proxy)

  func fullscreenTransition(active: Bool) {
    isFullscreen = active
    coordinator?.noteStateInvalidated()
    onFullscreenChange?(active)
    if !active {
      pendingFullscreenExitCompletion?()
      pendingFullscreenExitCompletion = nil
    }
    // Fullscreen ended while the inline view is off-window (cell scrolled
    // away or screen covered mid-fullscreen): nothing re-triggers
    // didMoveToWindow, so pause and release from here — audio must never
    // continue for an invisible video.
    if !active, surface.window == nil, !isInPictureInPicture {
      engine.pause(reason: .system)
      scheduleHibernate()
    }
  }

  /// Restores playback intent after a fullscreen exit: AVKit implicitly pauses
  /// the player during dismissal, so resume when the video was playing as the
  /// exit began. When the user deliberately paused in fullscreen, register a
  /// user-pause with the coordinator so a `whenVisible` election doesn't
  /// immediately force-resume it.
  func fullscreenExitPlaybackIntent(wasPlaying: Bool) {
    if wasPlaying, surface.window != nil {
      engine.play(reason: .system)
    } else if !wasPlaying, let coordinator {
      coordinator.noteUserPause(self)
    }
  }

  func startPictureInPicture() throws -> Promise<Void> {
    let promise = Promise<Void>()
    DispatchQueue.main.async { [self] in
      updatePiPSetup()
      AudioSessionManager.shared.willStartPictureInPicture(muted: muted, mixMode: audioMixMode)
      pipManager.start { error in
        if let error {
          promise.reject(withError: error)
        } else {
          promise.resolve(withResult: ())
        }
      }
    }
    return promise
  }

  func stopPictureInPicture() throws -> Promise<Void> {
    let promise = Promise<Void>()
    DispatchQueue.main.async { [self] in
      pipManager.stop()
      promise.resolve(withResult: ())
    }
    return promise
  }

  // MARK: - Picture in Picture

  func pictureInPictureWillStart() {
    isInPictureInPicture = true
    coordinator?.noteStateInvalidated()
  }

  func pictureInPictureDidChange(active: Bool) {
    isInPictureInPicture = active
    coordinator?.noteStateInvalidated()
    onPictureInPictureChange?(active)
    // PiP ended while the owning screen is covered: nothing re-triggers
    // didMoveToWindow, so release the item from here.
    if !active, surface.window == nil, !isFullscreen {
      engine.pause(reason: .system)
      scheduleHibernate()
    }
  }

  private func updatePiPSetup() {
    guard allowsPictureInPicture, !controls, surface.window != nil else { return }
    pipManager.setup(playerLayer: surface.playerLayer)
    // Auto-entering PiP on background requires the .playback category up
    // front — but merely mounting a PiP-capable view must not interrupt
    // other apps' audio, so this never applies duck/doNotMix; play and
    // explicit PiP start apply the real mix mode.
    AudioSessionManager.shared.prepareForPictureInPicture()
  }

  // MARK: - Engine management

  private func attachEngineHooks() {
    engine.willPlay = { [weak self] in
      guard let self else { return }
      AudioSessionManager.shared.willPlay(muted: muted, mixMode: audioMixMode)
    }
  }

  private func observeEnginePlayer() {
    mutedObservation = engine.player.observe(\.isMuted) { [weak self] player, _ in
      DispatchQueue.main.async {
        guard let self else { return }
        if player.isMuted != self.muted {
          self.onMutedChange?(player.isMuted)
        }
      }
    }
  }

  /// Hands the current engine over to the fullscreen presenter (which holds it
  /// strongly) and installs a fresh engine for this view's next source.
  private func detachEngineForFullscreenOrphan() {
    isFullscreen = false
    engine.delegate = nil
    engine = PlayerEngine()
    engine.delegate = self
    engine.isMuted = muted
    engine.loop = loop
    engine.volume = volume
    engine.progressIntervalMs = progressUpdateInterval
    attachEngineHooks()
    observeEnginePlayer()
    if embeddedController != nil {
      embeddedController?.player = engine.player
    } else {
      surface.player = engine.player
    }
  }

  // MARK: - Inline rendering handoff (fullscreen presenter)

  /// Blanks every inline render surface while the fullscreen presenter owns
  /// this engine's rendering.
  func suspendInlineRendering() {
    surface.player = nil
    embeddedController?.player = nil
  }

  /// Hands rendering back to whichever inline surface is active. In controls
  /// mode the embedded controller owns rendering and the bare layer must stay
  /// blank.
  func resumeInlineRendering() {
    if let embeddedController {
      embeddedController.player = engine.player
    } else {
      surface.player = engine.player
    }
  }

  // MARK: - Controls surface

  private func updateControlsSurface() {
    if controls {
      guard embeddedController == nil, surface.window != nil,
            let parent = surface.nearestViewController else {
        // No window/VC yet — retried from didMoveToWindow.
        return
      }
      let controller = AVPlayerViewController()
      // While the fullscreen presenter renders this engine, the embedded
      // surface mounts blank — FullscreenPresenter.finishExit hands the
      // player over via resumeInlineRendering().
      controller.player =
        FullscreenPresenter.shared.isPresenting(engine: engine) ? nil : engine.player
      controller.videoGravity = PlayerLayerView.gravity(for: resizeMode)
      controller.allowsPictureInPicturePlayback = allowsPictureInPicture
      controller.canStartPictureInPictureAutomaticallyFromInline = allowsPictureInPicture
      controller.delegate = controllerDelegateProxy
      // The inline surface layer is blank in controls mode, so its
      // isReadyForDisplay never fires — hide the poster off the controller's
      // own readiness instead.
      controlsReadyObservation = controller.observe(\.isReadyForDisplay) { [weak self] controller, _ in
        DispatchQueue.main.async {
          if controller.isReadyForDisplay {
            self?.posterView.isHidden = true
          }
        }
      }
      parent.addChild(controller)
      controller.view.frame = surface.bounds
      controller.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
      controller.view.backgroundColor = .black
      surface.insertSubview(controller.view, belowSubview: posterView)
      controller.didMove(toParent: parent)
      embeddedController = controller
      surface.player = nil
    } else if let controller = embeddedController {
      controlsReadyObservation = nil
      controller.willMove(toParent: nil)
      controller.view.removeFromSuperview()
      controller.removeFromParent()
      controller.player = nil
      embeddedController = nil
      surface.player =
        FullscreenPresenter.shared.isPresenting(engine: engine) ? nil : engine.player
    }
  }

  // MARK: - Autoplay + coordination

  private func applyAutoplay() {
    guard source != nil, surface.window != nil else { return }
    if autoplayMode == .always {
      engine.play(reason: .system)
    }
  }

  private func handleWindowChanged() {
    updateCoordinatorRegistration()
    if surface.window == nil {
      if !isInPictureInPicture, !isFullscreen {
        resumePlaybackOnAttach = engine.status == .playing || engine.status == .buffering
        engine.pause(reason: .system)
        scheduleHibernate()
      }
    } else {
      hibernateWorkItem?.cancel()
      hibernateWorkItem = nil
      if engine.isHibernated {
        engine.wake()
      }
      // Props (including source) are set before the view joins a window, so
      // autoplay for a still-loading source applies here, not at prop-set.
      if engine.status == .loading {
        applyAutoplay()
      } else if resumePlaybackOnAttach, autoplayMode != .whenvisible {
        engine.play(reason: .system)
      }
      resumePlaybackOnAttach = false
      if controls, embeddedController == nil {
        updateControlsSurface()
      } else {
        updatePiPSetup()
      }
    }
  }

  /// A view that stays off-window past the grace period releases its whole
  /// AVPlayerItem stack (buffers, resource loader, decoder session) — so a
  /// deep navigation stack of video feeds costs only posters. The engine
  /// keeps the source + playhead and rebuilds on reattach.
  private func scheduleHibernate() {
    hibernateWorkItem?.cancel()
    let work = DispatchWorkItem { [weak self] in
      guard let self else { return }
      hibernateWorkItem = nil
      guard surface.window == nil, !isInPictureInPicture, !isFullscreen else { return }
      if posterUri != nil {
        posterView.isHidden = false
      }
      engine.hibernate()
    }
    hibernateWorkItem = work
    DispatchQueue.main.asyncAfter(deadline: .now() + Self.hibernateGraceSeconds, execute: work)
  }

  private func updateCoordinatorRegistration() {
    let shouldRegister =
      autoplayMode == .whenvisible && surface.window != nil && source != nil
    if shouldRegister {
      let target = PlaybackCoordinator.coordinator(forGroup: coordinatorGroup)
      if coordinator !== target {
        coordinator?.unregister(self)
        coordinator = target
      }
      target.register(self)
    } else if let coordinator {
      coordinator.unregister(self)
      self.coordinator = nil
    }
  }
}

// MARK: - AVPlayerViewControllerDelegate proxy (embedded controls surface)

/// Relays embedded AVPlayerViewController fullscreen/PiP transitions to the
/// owning view. A separate NSObject because HybridVideoView cannot conform to
/// AVPlayerViewControllerDelegate directly (it is not an NSObject).
final class PlayerControllerDelegateProxy: NSObject, AVPlayerViewControllerDelegate {
  weak var owner: HybridVideoView?

  init(owner: HybridVideoView) {
    self.owner = owner
    super.init()
  }

  func playerViewController(
    _ playerViewController: AVPlayerViewController,
    willBeginFullScreenPresentationWithAnimationCoordinator coordinator: UIViewControllerTransitionCoordinator
  ) {
    owner?.fullscreenTransition(active: true)
  }

  func playerViewController(
    _ playerViewController: AVPlayerViewController,
    willEndFullScreenPresentationWithAnimationCoordinator coordinator: UIViewControllerTransitionCoordinator
  ) {
    // Capture before AVKit's implicit pause during dismissal, and restore the
    // playback intent once the exit transition completes.
    let wasPlaying = playerViewController.player?.timeControlStatus != .paused
    coordinator.animate(alongsideTransition: nil) { [weak self] _ in
      guard let owner = self?.owner else { return }
      owner.fullscreenExitPlaybackIntent(wasPlaying: wasPlaying)
      owner.fullscreenTransition(active: false)
    }
  }

  func playerViewControllerWillStartPictureInPicture(_ playerViewController: AVPlayerViewController) {
    owner?.pictureInPictureWillStart()
  }

  func playerViewControllerDidStartPictureInPicture(_ playerViewController: AVPlayerViewController) {
    owner?.pictureInPictureDidChange(active: true)
  }

  func playerViewControllerDidStopPictureInPicture(_ playerViewController: AVPlayerViewController) {
    owner?.pictureInPictureDidChange(active: false)
  }
}

// MARK: - PlayerEngineDelegate

extension HybridVideoView: PlayerEngineDelegate {
  func engine(_ engine: PlayerEngine, didChangeStatus status: PlaybackStatus, reason: PlaybackChangeReason) {
    onPlaybackStateChange?(PlaybackStateEvent(status: status, reason: reason))
  }

  func engine(_ engine: PlayerEngine, didLoad event: LoadEvent) {
    onLoad?(event)
  }

  func engine(_ engine: PlayerEngine, didProgress event: ProgressEvent) {
    onProgress?(event)
  }

  func engineDidPlayToEnd(_ engine: PlayerEngine) {
    onEnd?()
  }

  func engine(_ engine: PlayerEngine, didFail error: VideoErrorEvent) {
    onError?(error)
  }
}

enum VideoViewError: Error, LocalizedError {
  case notImplemented(String)
  case fullscreenAlreadyPresented
  case notInFullscreen
  case noViewControllerToPresentFrom
  case pictureInPictureNotPossible

  var errorDescription: String? {
    switch self {
    case .notImplemented(let name):
      return "\(name) is not implemented yet"
    case .fullscreenAlreadyPresented:
      return "A fullscreen video is already presented"
    case .notInFullscreen:
      return "No fullscreen video is currently presented"
    case .noViewControllerToPresentFrom:
      return "Could not find a view controller to present fullscreen from"
    case .pictureInPictureNotPossible:
      return "Picture in Picture is not possible right now"
    }
  }
}
