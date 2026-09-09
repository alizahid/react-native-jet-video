import AVKit
import UIKit

/// AVKit fullscreen helpers, plus a holder for a fullscreen presentation whose
/// view was recycled to another source mid-presentation: the controller and
/// engine live on here until AVKit's exit lands, then are torn down.
///
/// Fullscreen itself is the expo-video approach — the view's inline
/// AVPlayerViewController is asked to enter AVKit's own fullscreen
/// presentation (`enterFullScreenAnimated:`), so the zoom starts from the
/// renderer that's already on screen and nothing is attached to or detached
/// from the player around the animation.
final class FullscreenPresenter: NSObject {
  static let shared = FullscreenPresenter()

  private var controller: AVPlayerViewController?
  private var engine: PlayerEngine?

  /// True while this engine's player is rendered by an orphaned fullscreen
  /// presentation (the pool must not evict it).
  func isPresenting(engine: PlayerEngine) -> Bool {
    controller != nil && self.engine === engine
  }

  /// Takes over a presentation whose view moved on to another source. Counts
  /// as a mirror so releasing the view's ownership doesn't pause it.
  func orphan(controller: AVPlayerViewController, engine: PlayerEngine) {
    finish()
    self.controller = controller
    self.engine = engine
    engine.mirrorCount += 1
    controller.delegate = self
  }

  private func finish() {
    guard let controller, let engine else { return }
    self.controller = nil
    self.engine = nil
    engine.mirrorCount -= 1
    engine.pause(reason: .system)
    Self.tearDown(controller)
    PlayerPool.shared.settle()
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

// MARK: - AVPlayerViewControllerDelegate (orphaned presentation)

extension FullscreenPresenter: AVPlayerViewControllerDelegate {
  func playerViewController(
    _ playerViewController: AVPlayerViewController,
    willEndFullScreenPresentationWithAnimationCoordinator coordinator: UIViewControllerTransitionCoordinator
  ) {
    playerViewController.showsPlaybackControls = false
    coordinator.animate(alongsideTransition: nil) { [weak self] _ in
      self?.finish()
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
