import AVKit
import UIKit

/// Drives the expo-video-style fullscreen transition: an AVPlayerViewController
/// embedded over the inline view is asked to enter AVKit's own fullscreen
/// presentation, so fullscreen zooms out of the VideoView (and back into it on
/// exit) instead of sliding up as a modal. Holds the engine strongly while
/// presented so fullscreen playback survives the originating cell being
/// recycled or unmounted. Falls back to a modal presentation if the AVKit
/// transition is unavailable.
final class FullscreenPresenter: NSObject {
  static let shared = FullscreenPresenter()

  private var controller: AVPlayerViewController?
  private var engine: PlayerEngine?
  private weak var view: HybridVideoView?
  private var wasPlayingAtExitStart = false
  private var enterCompletion: ((Error?) -> Void)?
  private var exitCompletion: ((Error?) -> Void)?

  var isPresenting: Bool { controller != nil }

  // MARK: - Enter

  func enter(for view: HybridVideoView, completion: @escaping (Error?) -> Void) {
    guard controller == nil else {
      completion(VideoViewError.fullscreenAlreadyPresented)
      return
    }
    guard let parent = view.view.nearestViewController else {
      completion(VideoViewError.noViewControllerToPresentFrom)
      return
    }

    let controller = AVPlayerViewController()
    controller.player = view.engine.player
    controller.showsPlaybackControls = true
    controller.videoGravity = PlayerLayerView.gravity(for: view.resizeMode)
    controller.allowsPictureInPicturePlayback = view.allowsPictureInPicture
    controller.delegate = self

    self.controller = controller
    engine = view.engine
    self.view = view

    if Self.supportsAVKitTransition(controller) {
      // Embed over the inline surface so AVKit's transition zooms out of
      // (and back into) the video's own rect.
      parent.addChild(controller)
      controller.view.frame = view.view.bounds
      controller.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
      controller.view.backgroundColor = .clear
      view.view.addSubview(controller.view)
      controller.didMove(toParent: parent)

      enterCompletion = completion
      DispatchQueue.main.async {
        view.view.layoutIfNeeded()
        Self.performTransition(controller, selectorName: "enterFullScreenAnimated:completionHandler:")
      }
    } else {
      controller.modalPresentationStyle = .fullScreen
      parent.present(controller, animated: true) { [weak self] in
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

    if let finishedController {
      finishedController.willMove(toParent: nil)
      finishedController.view.removeFromSuperview()
      finishedController.removeFromParent()
      finishedController.delegate = nil
      finishedController.player = nil
    }

    if let finishedView, finishedView.engine === finishedEngine {
      finishedView.fullscreenExitPlaybackIntent(wasPlaying: wasPlayingAtExitStart)
      finishedView.fullscreenTransition(active: false)
    } else {
      // The cell was recycled to a new source (or unmounted) mid-fullscreen;
      // this engine is orphaned — stop it.
      finishedEngine?.pause(reason: .system)
    }

    exitCompletion?(nil)
    exitCompletion = nil
  }

  // MARK: - AVKit transition

  private static func supportsAVKitTransition(_ controller: AVPlayerViewController) -> Bool {
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
    view?.fullscreenTransition(active: true)
    coordinator.animate(alongsideTransition: nil) { [weak self] _ in
      self?.enterCompletion?(nil)
      self?.enterCompletion = nil
    }
  }

  func playerViewController(
    _ playerViewController: AVPlayerViewController,
    willEndFullScreenPresentationWithAnimationCoordinator coordinator: UIViewControllerTransitionCoordinator
  ) {
    // Capture before AVKit's implicit pause during dismissal.
    wasPlayingAtExitStart = playerViewController.player?.timeControlStatus != .paused
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
