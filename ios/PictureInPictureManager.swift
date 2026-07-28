import AVKit
import Foundation

/// Owns the AVPictureInPictureController for a view's player layer and relays
/// PiP state to the owning view (events + coordinator exemption).
final class PictureInPictureManager: NSObject, AVPictureInPictureControllerDelegate {
  private weak var owner: HybridVideoView?
  private(set) var controller: AVPictureInPictureController?

  init(owner: HybridVideoView) {
    self.owner = owner
    super.init()
  }

  func setup(playerLayer: AVPlayerLayer) {
    guard AVPictureInPictureController.isPictureInPictureSupported() else { return }
    if controller == nil || controller?.playerLayer !== playerLayer {
      controller = AVPictureInPictureController(playerLayer: playerLayer)
      controller?.delegate = self
    }
    // PiP-enabled videos auto-enter PiP when the app is backgrounded while
    // they are playing — allowsPictureInPicture is the single switch.
    controller?.canStartPictureInPictureAutomaticallyFromInline = true
  }

  func teardown() {
    controller?.delegate = nil
    controller = nil
  }

  private var possibleObservation: NSKeyValueObservation?

  func start(completion: @escaping (Error?) -> Void) {
    guard let controller else {
      completion(VideoViewError.pictureInPictureNotPossible)
      return
    }
    if controller.isPictureInPicturePossible {
      controller.startPictureInPicture()
      completion(nil)
      return
    }
    // isPictureInPicturePossible flips true asynchronously after the
    // controller is created — wait briefly for it before giving up.
    var finished = false
    possibleObservation = controller.observe(\.isPictureInPicturePossible) { [weak self] controller, _ in
      DispatchQueue.main.async {
        guard !finished, controller.isPictureInPicturePossible else { return }
        finished = true
        self?.possibleObservation = nil
        controller.startPictureInPicture()
        completion(nil)
      }
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
      guard !finished else { return }
      finished = true
      self?.possibleObservation = nil
      completion(VideoViewError.pictureInPictureNotPossible)
    }
  }

  func stop() {
    controller?.stopPictureInPicture()
  }

  // MARK: - AVPictureInPictureControllerDelegate

  func pictureInPictureControllerWillStartPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
    // Flag before the app's didEnterBackground handlers run, so the
    // coordinator/background logic doesn't pause the auto-entering video.
    owner?.pictureInPictureWillStart()
  }

  func pictureInPictureControllerDidStartPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
    owner?.pictureInPictureDidChange(active: true)
  }

  func pictureInPictureControllerDidStopPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
    owner?.pictureInPictureDidChange(active: false)
  }

  func pictureInPictureController(
    _ pictureInPictureController: AVPictureInPictureController,
    failedToStartPictureInPictureWithError error: Error
  ) {
    owner?.pictureInPictureDidChange(active: false)
  }
}
