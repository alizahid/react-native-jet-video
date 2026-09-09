import AVKit
import UIKit

/// Drives the expo-video-style fullscreen transition: the AVPlayerViewController
/// the view keeps warm over its inline surface is asked to enter AVKit's own
/// fullscreen presentation, so fullscreen zooms out of the VideoView (and back
/// into it on exit) instead of sliding up as a modal. Holds the engine strongly
/// while presented so fullscreen playback survives the originating cell being
/// recycled or unmounted. Falls back to a modal presentation if the AVKit
/// transition is unavailable.
///
/// Nothing is attached to or detached from the player around the animations:
/// attaching or detaching an AVPlayerLayer makes a playing AVPlayer renegotiate
/// its video pipeline, which shows as a frame hold about half a second later —
/// mid-zoom, or just after the exit lands. The controller is attached while the
/// view is at rest, the inline layer stays attached (only covered), and the
/// controller is handed back afterwards, still attached.
final class FullscreenPresenter: NSObject {
  static let shared = FullscreenPresenter()

  private var controller: AVPlayerViewController?
  private var engine: PlayerEngine?
  private weak var view: HybridVideoView?
  private var wasPlayingAtExitStart = false
  private var enterCompletion: ((Error?) -> Void)?
  private var exitCompletion: ((Error?) -> Void)?

  var isPresenting: Bool { controller != nil }

  /// True while this engine's player is rendered by the fullscreen
  /// presentation.
  func isPresenting(engine: PlayerEngine) -> Bool {
    controller != nil && self.engine === engine
  }

  // MARK: - Enter

  func enter(for view: HybridVideoView, engine: PlayerEngine, completion: @escaping (Error?) -> Void) {
    guard controller == nil else {
      completion(VideoViewError.fullscreenAlreadyPresented)
      return
    }
    guard let parent = view.view.nearestViewController else {
      completion(VideoViewError.noViewControllerToPresentFrom)
      return
    }

    // Warm from the view whenever it had a window to build it in: already
    // attached to the player and rendering, so the zoom starts on the spot.
    let controller = view.takeFullscreenController() ?? AVPlayerViewController()
    // Registering as the Now Playing app forcibly interrupts other apps'
    // audio — never do it implicitly.
    controller.updatesNowPlayingInfoCenter = false
    controller.showsPlaybackControls = true
    // The fullscreen presentation letterboxes regardless; an aspect-fill
    // controller pops at the zoom's first frame.
    controller.videoGravity = .resizeAspect
    controller.allowsPictureInPicturePlayback = view.allowsPictureInPicture
    controller.delegate = self
    Self.keepPlayingThroughExit(controller)
    if controller.player !== engine.player {
      controller.player = engine.player
    }

    self.controller = controller
    self.engine = engine
    self.view = view

    // Fallback should AVKit ever pause the player during a transition.
    engine.beginTransitionPlaybackHold()

    if Self.supportsAVKitTransition(controller) {
      // Embedded over the inline surface so AVKit's transition zooms out of
      // (and back into) the video's own rect.
      if controller.parent !== parent {
        if controller.parent != nil {
          controller.willMove(toParent: nil)
          controller.removeFromParent()
        }
        parent.addChild(controller)
        controller.didMove(toParent: parent)
      }
      controller.view.frame = view.view.bounds
      controller.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
      controller.view.backgroundColor = .clear
      if controller.view.superview !== view.view {
        view.view.addSubview(controller.view)
      }
      controller.view.isHidden = false
      controller.view.isUserInteractionEnabled = true

      enterCompletion = completion
      view.view.layoutIfNeeded()
      // A warm controller has a frame already; a fresh one gets a moment for
      // its first, so the zoom never starts from a black layer.
      Self.once(controller, isTrue: \.isReadyForDisplay, timeout: 0.35) {
        Self.performTransition(controller, selectorName: "enterFullScreenAnimated:completionHandler:")
      }
    } else {
      if controller.parent != nil {
        controller.willMove(toParent: nil)
        controller.view.removeFromSuperview()
        controller.removeFromParent()
      }
      controller.view.isHidden = false
      controller.view.isUserInteractionEnabled = true
      controller.modalPresentationStyle = .fullScreen
      parent.present(controller, animated: true) { [weak self] in
        self?.engine?.endTransitionPlaybackHold()
        self?.view?.fullscreenTransition(active: true)
        completion(nil)
      }
    }
  }

  // MARK: - Exit

  func exit(completion: @escaping (Error?) -> Void) {
    guard let controller else {
      completion(VideoViewError.notInFullscreen)
      return
    }
    exitCompletion = completion
    engine?.beginTransitionPlaybackHold()
    if Self.supportsAVKitTransition(controller), controller.parent != nil {
      Self.performTransition(controller, selectorName: "exitFullScreenAnimated:completionHandler:")
    } else {
      wasPlayingAtExitStart = controller.player?.timeControlStatus != .paused
      controller.presentingViewController?.dismiss(animated: true) { [weak self] in
        self?.finishExit()
      }
    }
  }

  // MARK: - Teardown

  private func finishExit() {
    let finishedEngine = engine
    let finishedView = view
    let finishedController = controller
    controller = nil
    engine = nil
    view = nil

    if let finishedView, finishedView.engine === finishedEngine {
      // The inline layer was attached (covered) all along: uncover it, and
      // hand the controller back still attached — nothing for the player to
      // renegotiate, so playback rolls through the landing.
      finishedView.resumeInlineRendering()
      finishedView.fullscreenExitPlaybackIntent(wasPlaying: wasPlayingAtExitStart)
      finishedView.fullscreenTransition(active: false)
      if let finishedController {
        if finishedController.view.superview === finishedView.view {
          finishedView.adoptFullscreenController(finishedController)
        } else {
          Self.tearDown(finishedController)
        }
      }
      finishedEngine?.endTransitionPlaybackHold()
      finishedView.applyPendingControlsUpdate()
    } else {
      // The cell was recycled to a new source (or unmounted) mid-fullscreen;
      // this engine is orphaned — stop it.
      finishedEngine?.pause(reason: .system)
      if let finishedController {
        Self.tearDown(finishedController)
      }
    }

    exitCompletion?(nil)
    exitCompletion = nil
  }

  /// Detaches the player before the view goes: AVKit pauses a controller's
  /// player as its view disappears, and by then the player may already be
  /// leased to another view that just started it.
  static func tearDown(_ controller: AVPlayerViewController) {
    controller.delegate = nil
    controller.player = nil
    controller.willMove(toParent: nil)
    controller.view.removeFromSuperview()
    controller.removeFromParent()
  }

  /// Runs `action` on main as soon as `keyPath` is true — now, on its next
  /// KVO change, or after `timeout` regardless.
  private static func once<T: NSObject>(
    _ object: T,
    isTrue keyPath: KeyPath<T, Bool>,
    timeout: TimeInterval,
    then action: @escaping () -> Void
  ) {
    if object[keyPath: keyPath] {
      action()
      return
    }
    var observation: NSKeyValueObservation?
    var finished = false
    let finish = {
      guard !finished else { return }
      finished = true
      observation?.invalidate()
      observation = nil
      action()
    }
    observation = object.observe(keyPath) { object, _ in
      if object[keyPath: keyPath] {
        DispatchQueue.main.async(execute: finish)
      }
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + timeout, execute: finish)
  }

  // MARK: - AVKit transition

  /// AVKit pauses the player as its fullscreen exit lands (twice, in
  /// practice), and reverting that on the spot still costs a rate re-sync —
  /// the stutter right after the shrink animation. Its private
  /// `canPausePlaybackWhenExitingFullScreen` flag skips the pause entirely.
  /// The transition hold stays as the fallback should the flag disappear.
  static func keepPlayingThroughExit(_ controller: AVPlayerViewController) {
    let selector = NSSelectorFromString("setCanPausePlaybackWhenExitingFullScreen:")
    guard controller.responds(to: selector) else { return }
    controller.setValue(false, forKey: "canPausePlaybackWhenExitingFullScreen")
  }

  static func supportsAVKitTransition(_ controller: AVPlayerViewController) -> Bool {
    controller.responds(to: NSSelectorFromString("enterFullScreenAnimated:completionHandler:"))
      && controller.responds(to: NSSelectorFromString("exitFullScreenAnimated:completionHandler:"))
  }

  /// Invokes AVKit's own fullscreen transition (the same non-public API used
  /// by expo-video and react-native-video to get the zoom animation).
  /// The completion parameter must be a real nullable pointer (the ObjC block
  /// slot) — a Swift `Any?` here corrupts the argument frame and the
  /// transition runs unanimated.
  static func performTransition(_ controller: AVPlayerViewController, selectorName: String) {
    let selector = NSSelectorFromString(selectorName)
    guard controller.responds(to: selector) else { return }
    typealias Transition = @convention(c) (AnyObject, Selector, ObjCBool, UnsafeRawPointer?) -> Void
    let function = unsafeBitCast(controller.method(for: selector), to: Transition.self)
    function(controller, selector, ObjCBool(true), nil)
  }
}

// MARK: - AVPlayerViewControllerDelegate

extension FullscreenPresenter: AVPlayerViewControllerDelegate {
  func playerViewController(
    _ playerViewController: AVPlayerViewController,
    willBeginFullScreenPresentationWithAnimationCoordinator coordinator: UIViewControllerTransitionCoordinator
  ) {
    // AVKit owns the screen from here: cover the inline surface so nothing
    // shows a second copy of the video behind the animating fullscreen view.
    view?.suspendInlineRendering()
    view?.fullscreenTransition(active: true)
    coordinator.animate(alongsideTransition: nil) { [weak self] _ in
      self?.engine?.endTransitionPlaybackHold()
      self?.enterCompletion?(nil)
      self?.enterCompletion = nil
    }
  }

  func playerViewController(
    _ playerViewController: AVPlayerViewController,
    willEndFullScreenPresentationWithAnimationCoordinator coordinator: UIViewControllerTransitionCoordinator
  ) {
    // Capture before any implicit pause during dismissal. Begin the hold
    // here too — this is the only hook when AVKit itself initiates the exit
    // (the user tapping the fullscreen Done button never goes through exit()).
    wasPlayingAtExitStart = playerViewController.player?.timeControlStatus != .paused
    engine?.beginTransitionPlaybackHold()
    // Drop the fullscreen chrome now: the embedded view shows bare video
    // during the shrink and the brief handback window, instead of flashing
    // playback controls at the inline rect.
    playerViewController.showsPlaybackControls = false
    coordinator.animate(alongsideTransition: nil) { [weak self] _ in
      self?.finishExit()
    }
  }
}

extension UIView {
  var nearestViewController: UIViewController? {
    var responder: UIResponder? = next
    while let current = responder {
      if let viewController = current as? UIViewController {
        return viewController
      }
      responder = current.next
    }
    return nil
  }
}
