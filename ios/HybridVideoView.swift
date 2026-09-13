import AVKit
import Foundation
import NitroModules
import UIKit

class HybridVideoView: HybridVideoViewSpec {
  private let surface = SurfaceView()
  private let posterView = PosterView(frame: .zero)
  /// The pooled engine this view controls. Leased lazily — when the video
  /// becomes visible, plays, or is otherwise needed — and handed to whichever
  /// view shows the same `playerKey` next.
  private(set) var engine: PlayerEngine?
  /// An engine another view now controls whose player this view keeps
  /// rendering, so the frame under a pushed/popped screen never blanks.
  private(set) var mirroredEngine: PlayerEngine?
  /// The one renderer (the expo-video approach): an AVPlayerViewController
  /// embedded over the surface, chrome hidden unless `controls`. The player
  /// draws to exactly one layer, and this is the controller AVKit zooms into
  /// fullscreen — so the zoom starts from what's already on screen, and
  /// nothing is attached to or detached from the player around it (an
  /// AVPlayerLayer attach makes a playing player renegotiate its pipeline: a
  /// frame hold ~0.5s later). Built once the view has a window and a parent
  /// view controller to live under.
  private(set) var controller: AVPlayerViewController?
  private var controllerReadyObservation: NSKeyValueObservation?
  private var mutedObservation: NSKeyValueObservation?
  // Resolve the enter/exit fullscreen promises: AVKit drives the transition
  // and completion arrives via the controller delegate.
  var pendingFullscreenExitCompletion: (() -> Void)?
  var pendingFullscreenEnterCompletion: (() -> Void)?
  private var pendingPiPStartCompletion: ((Error?) -> Void)?
  private lazy var controllerDelegateProxy = PlayerControllerDelegateProxy(owner: self)

  // Coordinator-owned state (read/written on main only).
  var autoplayOverride: AutoplayOverride = .none
  var isInPictureInPicture = false
  var isFullscreen = false
  /// Last visible fraction measured by the coordinator (0 off-window).
  var lastVisibleFraction: Double = 0
  var isDisplayed: Bool { surface.window != nil && lastVisibleFraction > 0.001 }
  private var coordinator: PlaybackCoordinator?
  // Playback was interrupted by the window detach itself (screen covered),
  // so reattaching should resume it. Coordinated views are excluded — the
  // election decides who plays.
  private var resumePlaybackOnAttach = false
  /// A view's first time on a window is a fresh mount as far as autoplay is
  /// concerned — even when it adopts a pooled player another screen paused.
  private var hasAttachedBefore = false

  var view: UIView { surface }

  /// Identity of this view's player in the pool.
  private var resolvedKey: String? { nonEmpty(playerKey) ?? source?.uri }
  private var poster: String? { nonEmpty(posterUri) }

  /// The spec has no optional props (Fabric clears them with a null Nitro
  /// rejects), so "" is the wire form of nil for strings.
  private func nonEmpty(_ value: String) -> String? { value.isEmpty ? nil : value }

  /// Fabric dropped the view (main thread): give the engine back now. The
  /// Swift object itself lives on until JS collects its hybrid ref, so
  /// `deinit` is both late and possibly on the JS thread.
  func onDropView() {
    releaseEngine()
    dropMirror()
    tearDownController()
    coordinator?.unregister(self)
    coordinator = nil
  }

  deinit {
    // Fallback for hosts that never call `onDropView` (RN < 0.82). The pool
    // can't be told who's releasing — `engine.owner` (weak self) is already
    // nil here — so just stop the orphan and let the LRU reclaim it. Pool and
    // UIKit state are main-only; deinit may run on the JS thread.
    engine?.delegate = nil
    let engine = engine
    let mirrored = mirroredEngine
    let controller = controller
    DispatchQueue.main.async {
      mirrored?.mirrorCount -= 1
      if let engine, engine.owner == nil {
        engine.pause(reason: .system)
        PlayerPool.shared.settle()
      }
      // The parent VC's containment retains the controller (and via
      // controller.player, the whole player stack) past this view's dealloc.
      if let controller {
        FullscreenPresenter.tearDown(controller)
      }
    }
  }

  override init() {
    super.init()

    posterView.isHidden = true
    posterView.frame = surface.bounds
    posterView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    surface.addSubview(posterView)

    surface.onWindowChanged = { [weak self] in
      self?.handleWindowChanged()
    }
  }

  // MARK: - Props

  var source: VideoSource? = nil {
    didSet { handleIdentityChange(oldKey: nonEmpty(playerKey) ?? oldValue?.uri) }
  }

  /// Explicit player identity (defaults to the source uri). Views sharing a
  /// key share one player — the feed cell and the post screen it opens
  /// continue each other seamlessly.
  var playerKey: String = "" {
    didSet { handleIdentityChange(oldKey: nonEmpty(oldValue) ?? source?.uri) }
  }

  private func handleIdentityChange(oldKey: String?) {
    if resolvedKey != oldKey {
      // Recycled to another video: the old engine stays pooled (playhead
      // intact) for whoever shows that video next.
      releaseEngine()
      dropMirror()
      posterView.isHidden = poster == nil
      autoplayOverride = .none
      resumePlaybackOnAttach = false
      hasAttachedBefore = false
      coordinator?.noteSourceChanged(self)
    } else if let source {
      engine?.setSource(source)
    }
    updateCoordinatorRegistration()
    applyAutoplay()
  }

  var autoplayMode: AutoplayMode = .off {
    didSet {
      guard autoplayMode != oldValue else { return }
      coordinator?.noteStateInvalidated()
      applyAutoplay()
    }
  }

  var muted: Bool = false {
    didSet {
      // Session config must precede the unmute: flipping the category or
      // activating the session while unmuted samples are already rendering
      // reconfigures the audio graph mid-stream and audibly pops. The config
      // runs off-main; unmute once it lands (unless the user flipped back).
      if !muted, isPlaying {
        AudioSessionManager.shared.prepare(muted: false, mixMode: audioMixMode, activate: true) { [weak self] in
          guard let self, !self.muted else { return }
          engine?.isMuted = false
        }
      } else {
        engine?.isMuted = muted
      }
    }
  }

  var loop: Bool = false {
    didSet { engine?.loop = loop }
  }

  var volume: Double = 1 {
    didSet { engine?.volume = volume }
  }

  var resizeMode: ResizeMode = .cover {
    didSet { applyGravity() }
  }

  var controls: Bool = false {
    didSet {
      guard controls != oldValue else { return }
      applyChrome()
    }
  }

  var posterUri: String = "" {
    didSet {
      posterView.setPoster(uri: poster)
      if poster == nil {
        posterView.isHidden = true
      } else if controller?.isReadyForDisplay != true {
        posterView.isHidden = false
      }
    }
  }

  var allowsPictureInPicture: Bool = false {
    didSet {
      if !allowsPictureInPicture {
        tearDownPiP()
      } else if isPlaying {
        // Enabled mid-playback: set up now so auto-PiP works without
        // waiting for the next play.
        updatePiPSetup()
      }
    }
  }

  var progressUpdateInterval: Double = 500 {
    didSet { engine?.progressIntervalMs = progressUpdateInterval }
  }

  var audioMixMode: AudioMixMode = .mixwithothers

  var visibilityAxis: VisibilityAxis = .both {
    didSet {
      guard visibilityAxis != oldValue else { return }
      coordinator?.noteStateInvalidated()
    }
  }

  /// Negative = defer to the global (configureAutoplay) threshold.
  var minVisibleFraction: Double = -1 {
    didSet {
      guard minVisibleFraction != oldValue else { return }
      coordinator?.noteStateInvalidated()
    }
  }

  var coordinatorGroup: String = "" {
    didSet {
      guard coordinatorGroup != oldValue else { return }
      updateCoordinatorRegistration()
    }
  }

  var onLoad: (LoadEvent) -> Void = { _ in }
  var onProgress: (ProgressEvent) -> Void = { _ in }
  var onEnd: () -> Void = {}
  var onError: (VideoErrorEvent) -> Void = { _ in }
  var onPlaybackStateChange: (PlaybackStateEvent) -> Void = { _ in }
  var onFullscreenChange: (Bool) -> Void = { _ in }
  var onPictureInPictureChange: (Bool) -> Void = { _ in }
  var onMutedChange: (Bool) -> Void = { _ in }
  var onVisibilityChange: (Double) -> Void = { _ in }

  // MARK: - Methods

  func play() throws {
    DispatchQueue.main.async { [self] in
      coordinator?.noteUserPlay(self)
      ensureEngine(force: true)?.play(reason: .user)
    }
  }

  func pause() throws {
    DispatchQueue.main.async { [self] in
      coordinator?.noteUserPause(self)
      engine?.pause(reason: .user)
    }
  }

  func seek(seconds: Double) throws -> Promise<Void> {
    let promise = Promise<Void>()
    DispatchQueue.main.async { [self] in
      guard let engine = ensureEngine(force: true) else {
        promise.resolve(withResult: ())
        return
      }
      engine.seek(to: seconds) {
        promise.resolve(withResult: ())
      }
    }
    return promise
  }

  /// Synchronous by contract (JS reads it on its own thread); the engine and
  /// pool are main-confined, so hop over.
  func getCurrentTime() throws -> Double {
    if Thread.isMainThread {
      return currentTimeOnMain()
    }
    return DispatchQueue.main.sync { currentTimeOnMain() }
  }

  private func currentTimeOnMain() -> Double {
    if let engine {
      return engine.currentTime
    }
    return resolvedKey.map { PlayerPool.shared.rememberedPosition(for: $0) } ?? 0
  }

  func enterFullscreen() throws -> Promise<Void> {
    let promise = Promise<Void>()
    DispatchQueue.main.async { [self] in
      guard !isFullscreen else {
        promise.resolve(withResult: ())
        return
      }
      guard ensureEngine(force: true) != nil else {
        promise.reject(withError: VideoViewError.noSource)
        return
      }
      ensureController()
      guard let controller else {
        promise.reject(withError: VideoViewError.noViewControllerToPresentFrom)
        return
      }
      guard FullscreenPresenter.supportsAVKitTransition(controller) else {
        promise.reject(withError: VideoViewError.notImplemented("AVKit fullscreen transition"))
        return
      }
      // Fullscreen is where apps unmute. Activating the audio session is a
      // route change on real hardware, and one during the zoom shows as a
      // frame hold — so activate now, at rest, and any unmute made in
      // onFullscreenChange finds the session ready.
      AudioSessionManager.shared.prepare(muted: muted, mixMode: audioMixMode, activate: true) { [weak self] in
        guard let self, self.controller === controller, !isFullscreen else {
          promise.reject(withError: VideoViewError.fullscreenAlreadyPresented)
          return
        }
        pendingFullscreenEnterCompletion = {
          promise.resolve(withResult: ())
        }
        // The presentation letterboxes regardless; an aspect-fill renderer
        // pops at the zoom's first frame. Switched at rest, before the zoom.
        controller.videoGravity = .resizeAspect
        controller.showsPlaybackControls = true
        controller.view.isUserInteractionEnabled = true
        engine?.beginTransitionPlaybackHold()
        FullscreenPresenter.performTransition(
          controller,
          selectorName: "enterFullScreenAnimated:completionHandler:"
        )
      }
    }
    return promise
  }

  func exitFullscreen() throws -> Promise<Void> {
    let promise = Promise<Void>()
    DispatchQueue.main.async { [self] in
      guard isFullscreen, let controller else {
        promise.reject(withError: VideoViewError.notInFullscreen)
        return
      }
      pendingFullscreenExitCompletion = {
        promise.resolve(withResult: ())
      }
      FullscreenPresenter.performTransition(
        controller,
        selectorName: "exitFullScreenAnimated:completionHandler:"
      )
    }
    return promise
  }

  // MARK: - Fullscreen state (called by the controller delegate proxy)

  func fullscreenTransition(active: Bool) {
    isFullscreen = active
    coordinator?.noteStateInvalidated()
    onFullscreenChange(active)
    if active {
      pendingFullscreenEnterCompletion?()
      pendingFullscreenEnterCompletion = nil
    } else {
      pendingFullscreenExitCompletion?()
      pendingFullscreenExitCompletion = nil
    }
    // Fullscreen ended while the inline view is off-window (cell scrolled
    // away or screen covered mid-fullscreen): nothing re-triggers
    // didMoveToWindow, so pause and release from here — audio must never
    // continue for an invisible video.
    if !active, surface.window == nil, !isInPictureInPicture {
      engine?.pause(reason: .system)
    }
  }

  /// Restores playback intent after a fullscreen exit: AVKit implicitly pauses
  /// the player during dismissal, so resume when the video was playing as the
  /// exit began. When the user deliberately paused in fullscreen, register a
  /// user-pause with the coordinator so a `whenVisible` election doesn't
  /// immediately force-resume it.
  func fullscreenExitPlaybackIntent(wasPlaying: Bool) {
    if wasPlaying, surface.window != nil {
      engine?.play(reason: .system)
    } else if !wasPlaying, let coordinator {
      coordinator.noteUserPause(self)
    }
  }

  /// Fullscreen chrome and gravity back to the inline configuration.
  func restoreInlineChrome() {
    applyGravity()
    applyChrome()
  }

  private func applyGravity() {
    controller?.videoGravity = isFullscreen ? .resizeAspect : SurfaceView.gravity(for: resizeMode)
  }

  /// Chrome, and with it touch handling: even with controls hidden the
  /// controller's view has tap recognizers, and a chromeless video must let
  /// touches through to whatever wraps it (a Pressable). Fullscreen reuses
  /// this same view for the presentation, so it takes touches there.
  private func applyChrome() {
    let interactive = controls || isFullscreen
    controller?.showsPlaybackControls = interactive
    controller?.view.isUserInteractionEnabled = interactive
  }

  // MARK: - Picture in Picture

  func startPictureInPicture() throws -> Promise<Void> {
    let promise = Promise<Void>()
    DispatchQueue.main.async { [self] in
      guard ensureEngine(force: true) != nil else {
        promise.reject(withError: VideoViewError.noSource)
        return
      }
      guard AVPictureInPictureController.isPictureInPictureSupported() else {
        promise.reject(withError: VideoViewError.pictureInPictureNotPossible)
        return
      }
      AudioSessionManager.shared.prepare(muted: muted, mixMode: audioMixMode, activate: true) { [weak self] in
        guard let self else { return }
        updatePiPSetup()
        // AVPlayerViewController exposes no public start; expo-video and
        // react-native-video use the same selector.
        let selector = NSSelectorFromString("startPictureInPicture")
        guard let controller, controller.allowsPictureInPicturePlayback, controller.responds(to: selector) else {
          promise.reject(withError: VideoViewError.pictureInPictureNotPossible)
          return
        }
        finishPiPStart(error: VideoViewError.pictureInPictureNotPossible)
        pendingPiPStartCompletion = { error in
          if let error {
            promise.reject(withError: error)
          } else {
            promise.resolve(withResult: ())
          }
        }
        _ = controller.perform(selector)
        // PiP becomes possible asynchronously after the player attaches;
        // AVKit reports the failure through the delegate, or not at all.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
          self?.finishPiPStart(error: VideoViewError.pictureInPictureNotPossible)
        }
      }
    }
    return promise
  }

  func stopPictureInPicture() throws -> Promise<Void> {
    let promise = Promise<Void>()
    DispatchQueue.main.async { [self] in
      let selector = NSSelectorFromString("stopPictureInPicture")
      if let controller, controller.responds(to: selector) {
        _ = controller.perform(selector)
      }
      promise.resolve(withResult: ())
    }
    return promise
  }

  func pictureInPictureWillStart() {
    isInPictureInPicture = true
    coordinator?.noteStateInvalidated()
  }

  func pictureInPictureDidChange(active: Bool) {
    isInPictureInPicture = active
    coordinator?.noteStateInvalidated()
    onPictureInPictureChange(active)
    if active {
      finishPiPStart(error: nil)
    }
    // PiP ended while the owning screen is covered: nothing re-triggers
    // didMoveToWindow, so pause from here.
    if !active, surface.window == nil, !isFullscreen {
      engine?.pause(reason: .system)
    }
  }

  func pictureInPictureDidFail(_ error: Error) {
    pictureInPictureDidChange(active: false)
    finishPiPStart(error: error)
  }

  private func finishPiPStart(error: Error?) {
    pendingPiPStartCompletion?(error)
    pendingPiPStartCompletion = nil
  }

  /// Enables PiP on the renderer. Deferred to playback (never mount): AVKit
  /// builds its PiP controller once allowed, which registers with the
  /// system's media services — doing it for every mounting feed cell at app
  /// open blocks the main thread for seconds and can knock out other apps'
  /// background audio. Only the video that actually plays needs it (auto-PiP
  /// only ever engages for playing content).
  private func updatePiPSetup() {
    guard allowsPictureInPicture, surface.window != nil, let controller else { return }
    controller.allowsPictureInPicturePlayback = true
    // PiP-enabled videos auto-enter PiP when the app is backgrounded while
    // they are playing — allowsPictureInPicture is the single switch.
    controller.canStartPictureInPictureAutomaticallyFromInline = true
  }

  private func tearDownPiP() {
    controller?.allowsPictureInPicturePlayback = false
    controller?.canStartPictureInPictureAutomaticallyFromInline = false
  }

  // MARK: - Engine leasing

  var isPlaying: Bool {
    engine?.status == .playing || engine?.status == .buffering
  }

  /// The engine for this view's key, leased from the pool on first need.
  /// Without `force` (coordinator-driven), a view mirroring an engine that
  /// another on-window view controls keeps mirroring instead of stealing it
  /// back — that's the feed cell under a pushed post screen; stealing would
  /// ping-pong the player between the two every tick.
  @discardableResult
  func ensureEngine(force: Bool) -> PlayerEngine? {
    if let engine {
      return engine
    }
    guard let source, let key = resolvedKey else { return nil }
    if !force, let mirrored = mirroredEngine, let owner = mirrored.owner, owner.view.window != nil {
      return nil
    }
    guard let leased = PlayerPool.shared.lease(key: key, source: source, for: self) else {
      // Pinned to another view by fullscreen/PiP: render it, don't control it.
      if let pinned = PlayerPool.shared.engine(for: key) {
        mirror(pinned)
      }
      return nil
    }
    adopt(leased)
    return leased
  }

  private func adopt(_ engine: PlayerEngine) {
    self.engine = engine
    dropMirror()
    engine.delegate = self
    engine.isMuted = muted
    engine.loop = loop
    engine.volume = volume
    engine.progressIntervalMs = progressUpdateInterval
    engine.willPlay = { [weak self] proceed in
      guard let self else {
        proceed()
        return
      }
      AudioSessionManager.shared.prepare(muted: muted, mixMode: audioMixMode, activate: !muted) { [weak self] in
        // PiP setup rides the play path: the playing video is the only one
        // auto-PiP can pick up, and it must exist before the app backgrounds.
        // After the session is configured — AVKit registers with media
        // services, and must never do so on the default category.
        self?.updatePiPSetup()
        proceed()
      }
    }
    // Pauses/plays from AVKit chrome (fullscreen, inline controls) are the
    // user's; anything else that touches the rate behind our back is system.
    engine.isUserControlled = { [weak self] in
      guard let self else { return false }
      return isFullscreen || controls
    }
    mutedObservation = engine.player.observe(\.isMuted) { [weak self] player, _ in
      DispatchQueue.main.async {
        guard let self else { return }
        if player.isMuted != self.muted {
          self.onMutedChange(player.isMuted)
        }
      }
    }
    resumeInlineRendering()
    engine.replayState(to: self)
  }

  /// Gives the engine back to the pool (it idles there, playhead intact).
  private func releaseEngine() {
    guard let engine else { return }
    engine.delegate = nil
    engine.willPlay = nil
    engine.isUserControlled = nil
    mutedObservation = nil
    self.engine = nil
    if isFullscreen, let controller {
      // Recycled mid-fullscreen: the presentation carries on with the old
      // engine (as an orphan); this view builds a fresh renderer for its
      // new source.
      FullscreenPresenter.shared.orphan(controller: controller, engine: engine)
      controllerReadyObservation = nil
      self.controller = nil
      isFullscreen = false
      pendingFullscreenEnterCompletion = nil
      pendingFullscreenExitCompletion = nil
    } else {
      setInlinePlayer(nil)
      tearDownPiP()
    }
    PlayerPool.shared.release(engine, from: self)
  }

  /// Pool callback: another view now controls this engine. Keep rendering
  /// its player (mirror) so nothing blanks mid-transition; control returns
  /// via `ensureEngine` when this view is next wanted and the taker is gone.
  func engineWasTaken(_ engine: PlayerEngine) {
    guard self.engine === engine else { return }
    engine.delegate = nil
    mutedObservation = nil
    self.engine = nil
    tearDownPiP()
    mirror(engine)
    coordinator?.noteStateInvalidated()
  }

  /// Pool callback: the engine was destroyed to make room. Back to the
  /// poster; a fresh engine is leased when this view is next wanted.
  func engineEvicted(_ engine: PlayerEngine) {
    guard self.engine === engine else { return }
    engine.delegate = nil
    mutedObservation = nil
    self.engine = nil
    setInlinePlayer(nil)
    tearDownPiP()
    if poster != nil {
      posterView.isHidden = false
    }
    coordinator?.noteStateInvalidated()
  }

  private func mirror(_ engine: PlayerEngine) {
    guard mirroredEngine !== engine else { return }
    dropMirror()
    mirroredEngine = engine
    engine.mirrorCount += 1
    setInlinePlayer(engine.player)
  }

  private func dropMirror() {
    guard let mirroredEngine else { return }
    mirroredEngine.mirrorCount -= 1
    self.mirroredEngine = nil
    if engine == nil {
      setInlinePlayer(nil)
      if poster != nil {
        posterView.isHidden = false
      }
    }
  }

  // MARK: - Inline rendering

  /// Makes sure the renderer has the current player. Idempotent.
  private func resumeInlineRendering() {
    setInlinePlayer(engine?.player ?? mirroredEngine?.player)
  }

  /// The one place the renderer gets its player. Never re-sets an
  /// already-attached player — that alone re-attaches the layer, with the
  /// frame hold that brings.
  private func setInlinePlayer(_ player: AVPlayer?) {
    if player != nil {
      ensureController()
    }
    if let controller, controller.player !== player {
      controller.player = player
    }
  }

  /// Builds the renderer under the nearest view controller, or re-parents it
  /// when the view moved to another screen (a popped screen's controller
  /// releases its children). No window/VC yet — retried from didMoveToWindow.
  private func ensureController() {
    guard surface.window != nil, let parent = surface.nearestViewController else { return }
    if let controller {
      if controller.parent !== parent {
        controller.willMove(toParent: nil)
        controller.removeFromParent()
        parent.addChild(controller)
        controller.didMove(toParent: parent)
      }
      return
    }
    let controller = AVPlayerViewController()
    // Registering as the Now Playing app forcibly interrupts other apps'
    // audio — never do it implicitly.
    controller.updatesNowPlayingInfoCenter = false
    controller.showsPlaybackControls = controls
    controller.view.isUserInteractionEnabled = controls
    controller.videoGravity = SurfaceView.gravity(for: resizeMode)
    controller.allowsPictureInPicturePlayback = false
    controller.delegate = controllerDelegateProxy
    FullscreenPresenter.keepPlayingThroughExit(controller)
    controller.view.backgroundColor = .black
    controller.view.frame = surface.bounds
    controller.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    controllerReadyObservation = controller.observe(\.isReadyForDisplay) { [weak self] controller, _ in
      DispatchQueue.main.async {
        if controller.isReadyForDisplay {
          self?.posterView.isHidden = true
        }
      }
    }
    parent.addChild(controller)
    surface.insertSubview(controller.view, belowSubview: posterView)
    controller.didMove(toParent: parent)
    self.controller = controller
  }

  private func tearDownController() {
    guard let controller else { return }
    controllerReadyObservation = nil
    self.controller = nil
    FullscreenPresenter.tearDown(controller)
  }

  // MARK: - Autoplay + coordination

  private func applyAutoplay() {
    guard source != nil, surface.window != nil, autoplayMode == .always else { return }
    ensureEngine(force: true)?.play(reason: .system)
  }

  /// Coordinator-driven play: leases the engine if needed. A view mirroring
  /// an engine another on-window view controls (the feed cell under a
  /// pushed post) plays that shared engine instead of stealing it.
  func coordinatorPlay() {
    if let engine = ensureEngine(force: false) {
      engine.play(reason: .coordinator)
    } else if let mirroredEngine, mirroredEngine.owner != nil {
      mirroredEngine.play(reason: .coordinator)
    }
  }

  /// A screen showing a video that's already live on the screen it's
  /// pushed over takes the player the moment it joins the window — so the
  /// first frame of the push animation is the video, not a poster. Same-screen
  /// duplicates (two cells, one key) are left to the coordinator.
  private func adoptSharedLiveEngine() {
    guard engine == nil, mirroredEngine == nil, let key = resolvedKey,
          let shared = PlayerPool.shared.engine(for: key),
          let owner = shared.owner,
          owner.view.nearestViewController !== surface.nearestViewController else { return }
    ensureEngine(force: false)
  }

  private func handleWindowChanged() {
    updateCoordinatorRegistration()
    if surface.window == nil {
      lastVisibleFraction = 0
      if let engine, engine.mirrorCount > 0 {
        // Another view is showing this player (the screen under a pop):
        // hand it over now rather than pausing it out from under them.
        releaseEngine()
      } else if !isInPictureInPicture, !isFullscreen {
        // A play still waiting on the audio-session gate counts: a screen
        // push briefly detaches and re-attaches the view, and the request
        // must survive that.
        resumePlaybackOnAttach = isPlaying || engine?.playRequested == true
        engine?.pause(reason: .system)
        // The player stays live (instant pop-back); the pool's LRU eviction
        // reclaims it if the slot is needed.
        tearDownPiP()
        PlayerPool.shared.settle()
      }
      dropMirror()
    } else {
      ensureController()
      adoptSharedLiveEngine()
      // Props (including source) are set before the view joins a window, so
      // autoplay for a still-loading source applies here, not at prop-set.
      let firstAttach = !hasAttachedBefore
      hasAttachedBefore = true
      if engine == nil || engine?.status == .loading || firstAttach {
        // Nothing playing yet, or a fresh mount: autoplay applies now — a
        // pooled player paused by the screen that popped must not leave a
        // new `autoplay` view sitting on a still frame.
        applyAutoplay()
      } else if resumePlaybackOnAttach, autoplayMode != .whenvisible {
        engine?.play(reason: .system)
      }
      resumePlaybackOnAttach = false
      if !isFullscreen {
        resumeInlineRendering()
      }
    }
  }

  private func updateCoordinatorRegistration() {
    // Every on-window video is tracked (for item liveness); only
    // `whenVisible` ones take part in the election.
    let shouldRegister = surface.window != nil && source != nil
    if shouldRegister {
      let target = PlaybackCoordinator.coordinator(forGroup: nonEmpty(coordinatorGroup))
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

// MARK: - AVPlayerViewControllerDelegate proxy

/// Relays the renderer's fullscreen/PiP transitions to the owning view. A
/// separate NSObject because HybridVideoView cannot conform to
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
    // Keep playback rolling through AVKit's transition (it implicitly pauses
    // the player at points during present/dismiss).
    owner?.engine?.beginTransitionPlaybackHold()
    owner?.fullscreenTransition(active: true)
    coordinator.animate(alongsideTransition: nil) { [weak self] _ in
      self?.owner?.engine?.endTransitionPlaybackHold()
    }
  }

  func playerViewController(
    _ playerViewController: AVPlayerViewController,
    willEndFullScreenPresentationWithAnimationCoordinator coordinator: UIViewControllerTransitionCoordinator
  ) {
    // Capture before AVKit's implicit pause during dismissal, and restore the
    // playback intent once the exit transition completes.
    let wasPlaying = playerViewController.player?.timeControlStatus != .paused
    owner?.engine?.beginTransitionPlaybackHold()
    // Drop the fullscreen chrome now: the inline rect shows bare video during
    // the shrink instead of flashing playback controls.
    if owner?.controls != true {
      playerViewController.showsPlaybackControls = false
    }
    coordinator.animate(alongsideTransition: nil) { [weak self] context in
      guard let owner = self?.owner else { return }
      // A swipe-to-dismiss the user let go of early: AVKit snaps back to
      // fullscreen, so only the chrome hidden above needs restoring.
      if context.isCancelled {
        playerViewController.showsPlaybackControls = true
        owner.engine?.endTransitionPlaybackHold()
        return
      }
      owner.fullscreenExitPlaybackIntent(wasPlaying: wasPlaying)
      owner.fullscreenTransition(active: false)
      owner.engine?.endTransitionPlaybackHold()
      owner.restoreInlineChrome()
    }
  }

  func playerViewControllerWillStartPictureInPicture(_ playerViewController: AVPlayerViewController) {
    // Flag before the app's didEnterBackground handlers run, so the
    // coordinator/background logic doesn't pause the auto-entering video.
    owner?.pictureInPictureWillStart()
  }

  func playerViewControllerDidStartPictureInPicture(_ playerViewController: AVPlayerViewController) {
    owner?.pictureInPictureDidChange(active: true)
  }

  func playerViewControllerDidStopPictureInPicture(_ playerViewController: AVPlayerViewController) {
    owner?.pictureInPictureDidChange(active: false)
  }

  func playerViewController(
    _ playerViewController: AVPlayerViewController,
    failedToStartPictureInPictureWithError error: Error
  ) {
    owner?.pictureInPictureDidFail(error)
  }
}

// MARK: - PlayerEngineDelegate

extension HybridVideoView: PlayerEngineDelegate {
  func engine(_ engine: PlayerEngine, didChangeStatus status: PlaybackStatus, reason: PlaybackChangeReason) {
    // A pause or play the user made on AVKit's controls is user intent just
    // like the ref methods — the election must not undo it.
    if reason == .user {
      switch status {
      case .paused:
        coordinator?.noteUserPause(self)
      case .playing, .buffering:
        coordinator?.noteUserPlay(self)
      default:
        break
      }
    }
    onPlaybackStateChange(PlaybackStateEvent(status: status, reason: reason))
  }

  func engine(_ engine: PlayerEngine, didLoad event: LoadEvent) {
    onLoad(event)
  }

  func engine(_ engine: PlayerEngine, didProgress event: ProgressEvent) {
    onProgress(event)
  }

  func engineDidPlayToEnd(_ engine: PlayerEngine) {
    onEnd()
  }

  func engine(_ engine: PlayerEngine, didFail error: VideoErrorEvent) {
    onError(error)
  }
}

enum VideoViewError: Error, LocalizedError {
  case notImplemented(String)
  case fullscreenAlreadyPresented
  case notInFullscreen
  case noViewControllerToPresentFrom
  case pictureInPictureNotPossible
  case noSource

  var errorDescription: String? {
    switch self {
    case .notImplemented(let name):
      return "\(name) is not available"
    case .fullscreenAlreadyPresented:
      return "A fullscreen video is already presented"
    case .notInFullscreen:
      return "No fullscreen video is currently presented"
    case .noViewControllerToPresentFrom:
      return "Could not find a view controller to present fullscreen from"
    case .pictureInPictureNotPossible:
      return "Picture in Picture is not possible right now"
    case .noSource:
      return "The video has no source"
    }
  }
}
