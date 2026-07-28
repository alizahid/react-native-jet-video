import AVKit
import UIKit

/// Presents a fullscreen AVPlayerViewController bound to a view's player.
/// Holds the engine strongly while presented so fullscreen playback survives
/// the originating cell being recycled or unmounted.
final class FullscreenPresenter {
  static let shared = FullscreenPresenter()

  private var activeEngine: PlayerEngine?
  private weak var activeView: HybridVideoView?
  private var controller: FullscreenPlayerViewController?

  var isPresenting: Bool { controller != nil }

  func present(for view: HybridVideoView, completion: @escaping (Error?) -> Void) {
    guard controller == nil else {
      completion(VideoViewError.fullscreenAlreadyPresented)
      return
    }
    guard let presenter = view.view.nearestViewController ?? Self.keyWindowRootViewController() else {
      completion(VideoViewError.noViewControllerToPresentFrom)
      return
    }

    let vc = FullscreenPlayerViewController()
    vc.player = view.engine.player
    vc.showsPlaybackControls = true
    vc.modalPresentationStyle = .fullScreen
    vc.allowsPictureInPicturePlayback = view.allowsPictureInPicture
    vc.onDismissed = { [weak self] in
      self?.handleDismissed()
    }

    activeEngine = view.engine
    activeView = view
    controller = vc
    view.isFullscreen = true

    presenter.present(vc, animated: true) {
      view.onFullscreenChange?(true)
      completion(nil)
    }
  }

  func dismiss(completion: @escaping (Error?) -> Void) {
    guard let controller else {
      completion(VideoViewError.notInFullscreen)
      return
    }
    controller.presentingViewController?.dismiss(animated: true) {
      // Cleanup happens in onDismissed (viewDidDisappear), which also covers
      // the user-initiated Done/swipe dismissal path.
      completion(nil)
    }
  }

  private func handleDismissed() {
    let view = activeView
    let engine = activeEngine
    controller = nil
    activeEngine = nil
    activeView = nil

    guard let view else {
      // Originating view is gone (unmounted mid-fullscreen): just stop the
      // orphaned engine.
      engine?.pause(reason: .system)
      return
    }
    if view.engine !== engine {
      // The cell was recycled to a new source mid-fullscreen; the fullscreen
      // engine is orphaned. Stop it — the view already has a fresh engine.
      engine?.pause(reason: .system)
    }
    view.isFullscreen = false
    view.onFullscreenChange?(false)
  }

  private static func keyWindowRootViewController() -> UIViewController? {
    let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
    let window = scenes.flatMap(\.windows).first { $0.isKeyWindow }
    var top = window?.rootViewController
    while let presented = top?.presentedViewController {
      top = presented
    }
    return top
  }
}

final class FullscreenPlayerViewController: AVPlayerViewController {
  var onDismissed: (() -> Void)?

  override func viewDidDisappear(_ animated: Bool) {
    super.viewDidDisappear(animated)
    if isBeingDismissed || presentingViewController == nil {
      onDismissed?()
      onDismissed = nil
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
