import AVKit
import Foundation
import NitroModules
import UIKit

class HybridVideoView: HybridVideoViewSpec {
  private let surface = PlayerLayerView()
  private let posterView = PosterView(frame: .zero)
  /// The pooled engine this view controls. Leased lazily — when the video
  /// becomes visible, plays, or is otherwise needed — and handed to whichever
  /// view shows the same `playerKey` next.
  private(set) var engine: PlayerEngine?
  /// An engine another view now controls whose player this view keeps
  /// rendering, so the frame under a pushed/popped screen never blanks.
  private(set) var mirroredEngine: PlayerEngine?
  private var readyForDisplayObservation: NSKeyValueObservation?
  private var controlsReadyObservation: NSKeyValueObservation?
  private var mutedObservation: NSKeyValueObservation?
  private var embeddedController: AVPlayerViewController?
  /// Fullscreen renderer kept warm — hidden, attached to the player — while
  /// this view renders chromeless. Attaching an AVPlayerLayer to a playing
  /// AVPlayer makes it renegotiate its video pipeline (a frame hold ~0.5s
  /// later), so the controller AVKit zooms into fullscreen is attached at
  /// rest, and the inline layer stays attached throughout — only covered.
  private var fullscreenController: AVPlayerViewController?
  /// Covers the inline layer while a fullscreen presentation owns the screen.
  private let curtain = UIView()
  // Resolves the exitFullscreen() promise for the embedded-controls surface,
  // where AVKit drives the transition and completion arrives via delegate.
  var pendingFullscreenExitCompletion: (() -> Void)?
  var pendingFullscreenEnterCompletion: (() -> Void)?

  /// True while the embedded AVPlayerViewController owns rendering (the
  /// inline surface layer is deliberately blank then).
  var hasEmbeddedControls: Bool { embeddedController != nil }
  private lazy var pipManager = PictureInPictureManager(owner: self)
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
  private var resolvedKey: String? { playerKey ?? source?.uri }

  deinit {
    if let engine {
      engine.delegate = nil
      PlayerPool.shared.release(engine, from: self)
    }
    mirroredEngine?.mirrorCount -= 1
    // The parent VC's containment retains the embedded controller (and via
    // controller.player, the whole player stack) past this view's dealloc —
    // detach it explicitly. UIKit work must run on main; deinit may not be.
    for controller in [embeddedController, fullscreenController].compactMap({ $0 }) {
      DispatchQueue.main.async {
        FullscreenPresenter.tearDown(controller)
      }
    }
  }

  override init() {
    super.init()

    curtain.backgroundColor = .black
    curtain.isHidden = true
    curtain.frame = surface.bounds
    curtain.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    surface.addSubview(curtain)

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
    didSet { handleIdentityChange(oldKey: playerKey ?? oldValue?.uri) }
  }

  /// Explicit player identity (defaults to the source uri). Views sharing a
  /// key share one player — the feed cell and the post screen it opens
  /// continue each other seamlessly.
  var playerKey: String? = nil {
    didSet { handleIdentityChange(oldKey: oldValue ?? source?.uri) }
  }

  private func handleIdentityChange(oldKey: String?) {
    if resolvedKey != oldKey {
      // Recycled to another video: the old engine stays pooled (playhead
      // intact) for whoever shows that video next.
      releaseEngine()
      dropMirror()
      posterView.isHidden = posterUri == nil
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
      if !allowsPictureInPicture {
        pipManager.teardown()
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

  func getCurrentTime() throws -> Double {
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
      guard let engine = ensureEngine(force: true) else {
        promise.reject(withError: VideoViewError.noSource)
        return
      }
      if let embeddedController, FullscreenPresenter.supportsAVKitTransition(embeddedController) {
        // Controls mode: the embedded controller is the renderer — AVKit
        // zooms it straight into fullscreen, nothing to attach.
        pendingFullscreenEnterCompletion = {
          promise.resolve(withResult: ())
        }
        FullscreenPresenter.performTransition(
          embeddedController,
          selectorName: "enterFullScreenAnimated:completionHandler:"
        )
        return
      }
      // Fullscreen is where apps unmute. Activating the audio session is a
      // route change on real hardware, and one during the zoom shows as a
      // frame hold — so activate now, at rest, and any unmute made in
      // onFullscreenChange finds the session ready.
      AudioSessionManager.shared.prepare(muted: muted, mixMode: audioMixMode, activate: true) { [weak self] in
        guard let self else { return }
        FullscreenPresenter.shared.enter(for: self, engine: engine) { error in
          if let error {
            promise.reject(withError: error)
          } else {
            promise.resolve(withResult: ())
          }
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

  func startPictureInPicture() throws -> Promise<Void> {
    let promise = Promise<Void>()
    DispatchQueue.main.async { [self] in
      guard ensureEngine(force: true) != nil else {
        promise.reject(withError: VideoViewError.noSource)
        return
      }
      AudioSessionManager.shared.prepare(muted: muted, mixMode: audioMixMode, activate: true) { [weak self] in
        guard let self else { return }
        updatePiPSetup()
        pipManager.start { error in
          if let error {
            promise.reject(withError: error)
          } else {
            promise.resolve(withResult: ())
          }
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
    // didMoveToWindow, so pause from here.
    if !active, surface.window == nil, !isFullscreen {
      engine?.pause(reason: .system)
    }
  }

  /// Creates the AVPictureInPictureController for this view's layer. Deferred
  /// to playback (never mount): instantiating a PiP controller is expensive
  /// and registers with the system's media services — doing it for every
  /// mounting feed cell at app open blocks the main thread for seconds and
  /// can knock out other apps' background audio. Only the video that actually
  /// plays needs one (auto-PiP only ever engages for playing content).
  private func updatePiPSetup() {
    guard allowsPictureInPicture, !controls, surface.window != nil else { return }
    pipManager.setup(playerLayer: surface.playerLayer)
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
        // After the session is configured — the controller registers with
        // media services, and must never do so on the default category.
        self?.updatePiPSetup()
        proceed()
      }
    }
    // Pauses/plays from AVKit chrome (fullscreen, embedded controls) are the
    // user's; anything else that touches the rate behind our back is system.
    engine.isUserControlled = { [weak self] in
      guard let self else { return false }
      return isFullscreen || hasEmbeddedControls
    }
    mutedObservation = engine.player.observe(\.isMuted) { [weak self] player, _ in
      DispatchQueue.main.async {
        guard let self else { return }
        if player.isMuted != self.muted {
          self.onMutedChange?(player.isMuted)
        }
      }
    }
    if !FullscreenPresenter.shared.isPresenting(engine: engine) {
      resumeInlineRendering()
    }
    engine.replayState(to: self)
  }

  /// Gives the engine back to the pool (it idles there, playhead intact).
  private func releaseEngine() {
    guard let engine else { return }
    engine.delegate = nil
    engine.willPlay = nil
    engine.isUserControlled = nil
    mutedObservation = nil
    if FullscreenPresenter.shared.isPresenting(engine: engine) {
      // Recycled mid-fullscreen: the presenter keeps the engine; this view
      // carries on independently.
      isFullscreen = false
      applyPendingControlsUpdate()
    }
    self.engine = nil
    setInlinePlayer(nil)
    pipManager.teardown()
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
    pipManager.teardown()
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
    pipManager.teardown()
    if posterUri != nil {
      posterView.isHidden = false
    }
    coordinator?.noteStateInvalidated()
  }

  private func mirror(_ engine: PlayerEngine) {
    guard mirroredEngine !== engine else { return }
    dropMirror()
    mirroredEngine = engine
    engine.mirrorCount += 1
    if !FullscreenPresenter.shared.isPresenting(engine: engine) {
      setInlinePlayer(engine.player)
    }
  }

  private func dropMirror() {
    guard let mirroredEngine else { return }
    mirroredEngine.mirrorCount -= 1
    self.mirroredEngine = nil
    if engine == nil {
      setInlinePlayer(nil)
      if posterUri != nil {
        posterView.isHidden = false
      }
    }
  }

  // MARK: - Inline rendering handoff (fullscreen presenter)

  /// Covers the inline surface while the fullscreen presenter owns the
  /// screen. The layer keeps its player: detaching it here (mid-zoom) made
  /// the player renegotiate its pipeline and hold a frame during the animation.
  func suspendInlineRendering() {
    curtain.isHidden = false
  }

  /// Uncovers the inline surface and makes sure every inline renderer has
  /// the current player. Idempotent.
  func resumeInlineRendering() {
    curtain.isHidden = true
    setInlinePlayer(engine?.player ?? mirroredEngine?.player)
  }

  /// The one place inline renderers get their player: the embedded controls
  /// controller, or the bare layer plus the warm fullscreen controller.
  /// Never re-sets an already-attached player — that alone re-attaches the
  /// layer, with the frame hold that brings.
  private func setInlinePlayer(_ player: AVPlayer?) {
    if let embeddedController {
      if embeddedController.player !== player {
        embeddedController.player = player
      }
      return
    }
    if surface.player !== player {
      surface.player = player
    }
    if player != nil {
      ensureFullscreenController()
    }
    if let fullscreenController, fullscreenController.player !== player {
      fullscreenController.player = player
    }
  }

  private var isPresentedFullscreen: Bool {
    engine.map { FullscreenPresenter.shared.isPresenting(engine: $0) } ?? false
  }

  // MARK: - Warm fullscreen controller

  private func ensureFullscreenController() {
    guard fullscreenController == nil, embeddedController == nil,
          surface.window != nil, let parent = surface.nearestViewController else {
      // No window/VC yet — retried from didMoveToWindow.
      return
    }
    let controller = AVPlayerViewController()
    controller.updatesNowPlayingInfoCenter = false
    controller.showsPlaybackControls = false
    controller.videoGravity = .resizeAspect
    controller.view.backgroundColor = .clear
    controller.view.isHidden = true
    controller.view.isUserInteractionEnabled = false
    controller.view.frame = surface.bounds
    controller.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    FullscreenPresenter.keepPlayingThroughExit(controller)
    parent.addChild(controller)
    surface.insertSubview(controller.view, belowSubview: posterView)
    controller.didMove(toParent: parent)
    fullscreenController = controller
  }

  private func tearDownFullscreenController() {
    guard let controller = fullscreenController else { return }
    fullscreenController = nil
    FullscreenPresenter.tearDown(controller)
  }

  /// The presenter takes the warm controller for the presentation…
  func takeFullscreenController() -> AVPlayerViewController? {
    defer { fullscreenController = nil }
    return fullscreenController
  }

  /// …and hands it back afterwards, still attached to the player. It stays
  /// on screen a moment longer: AVKit's presentation had the inline layer
  /// off the window, and a layer rejoining the render tree renegotiates
  /// its pipeline right around the landing — the controller's layer never
  /// left, so it covers that, then hides once the inline layer has settled.
  func adoptFullscreenController(_ controller: AVPlayerViewController) {
    guard embeddedController == nil, fullscreenController == nil else {
      FullscreenPresenter.tearDown(controller)
      return
    }
    controller.delegate = nil
    controller.showsPlaybackControls = false
    controller.videoGravity = PlayerLayerView.gravity(for: resizeMode)
    controller.view.isUserInteractionEnabled = false
    controller.view.frame = surface.bounds
    fullscreenController = controller
    setInlinePlayer(engine?.player ?? mirroredEngine?.player)
    DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self, weak controller] in
      guard let self, let controller, fullscreenController === controller else { return }
      controller.view.isHidden = true
    }
  }

  // MARK: - Controls surface

  /// Set when a `controls` change arrives while a fullscreen presentation
  /// owns this engine's rendering. Building or tearing down the embedded
  /// AVPlayerViewController mid-transition swaps renderers during the
  /// animation (visible jank), and attaching a playing player to a fresh
  /// controller makes AVKit re-sync its scrubber with a tolerance-y seek —
  /// the playhead audibly jumps back. Applied after the handback settles.
  private var pendingControlsUpdate = false

  func applyPendingControlsUpdate() {
    guard pendingControlsUpdate else { return }
    // Small grace so a transient flip (apps toggling `controls` off the
    // fullscreen state, which lands via JS just after the exit) settles to
    // its final value before the surface is rebuilt.
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
      guard let self, pendingControlsUpdate else { return }
      pendingControlsUpdate = false
      updateControlsSurface()
    }
  }

  private func updateControlsSurface() {
    if isPresentedFullscreen || isFullscreen {
      pendingControlsUpdate = true
      return
    }
    pendingControlsUpdate = false
    if controls {
      guard embeddedController == nil, surface.window != nil,
            let parent = surface.nearestViewController else {
        // No window/VC yet — retried from didMoveToWindow.
        return
      }
      tearDownFullscreenController()
      let controller = AVPlayerViewController()
      // Registering as the Now Playing app forcibly interrupts other apps'
      // audio — never do it implicitly.
      controller.updatesNowPlayingInfoCenter = false
      controller.videoGravity = PlayerLayerView.gravity(for: resizeMode)
      controller.allowsPictureInPicturePlayback = allowsPictureInPicture
      controller.canStartPictureInPictureAutomaticallyFromInline = allowsPictureInPicture
      controller.delegate = controllerDelegateProxy
      FullscreenPresenter.keepPlayingThroughExit(controller)
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
    }
    resumeInlineRendering()
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
        pipManager.teardown()
        PlayerPool.shared.settle()
      }
      dropMirror()
    } else {
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
      if controls, embeddedController == nil {
        updateControlsSurface()
      } else if !isPresentedFullscreen, !isFullscreen {
        resumeInlineRendering()
      }
    }
  }

  private func updateCoordinatorRegistration() {
    // Every on-window video is tracked (for item liveness); only
    // `whenVisible` ones take part in the election.
    let shouldRegister = surface.window != nil && source != nil
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
    coordinator.animate(alongsideTransition: nil) { [weak self] _ in
      guard let owner = self?.owner else { return }
      owner.fullscreenExitPlaybackIntent(wasPlaying: wasPlaying)
      owner.fullscreenTransition(active: false)
      owner.engine?.endTransitionPlaybackHold()
      owner.applyPendingControlsUpdate()
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
  case noSource

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
    case .noSource:
      return "The video has no source"
    }
  }
}
