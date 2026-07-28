import AVFoundation
import UIKit

/// A plain UIView backed by an AVPlayerLayer — the chrome-less render surface
/// used when `controls` is off (the cheap path for feed cells).
final class PlayerLayerView: UIView {
  override class var layerClass: AnyClass { AVPlayerLayer.self }

  var playerLayer: AVPlayerLayer {
    // swiftlint:disable-next-line force_cast
    layer as! AVPlayerLayer
  }

  var player: AVPlayer? {
    get { playerLayer.player }
    set { playerLayer.player = newValue }
  }

  var resizeMode: ResizeMode = .cover {
    didSet { playerLayer.videoGravity = Self.gravity(for: resizeMode) }
  }

  var onWindowChanged: (() -> Void)?

  override func didMoveToWindow() {
    super.didMoveToWindow()
    onWindowChanged?()
  }

  override init(frame: CGRect) {
    super.init(frame: frame)
    backgroundColor = .black
    playerLayer.videoGravity = Self.gravity(for: resizeMode)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) is not supported")
  }

  static func gravity(for mode: ResizeMode) -> AVLayerVideoGravity {
    switch mode {
    case .contain:
      return .resizeAspect
    case .cover:
      return .resizeAspectFill
    case .stretch:
      return .resize
    }
  }
}

/// Poster image overlay: covers the video surface until the first frame is
/// ready for display, then hides. Re-shown on every source change.
final class PosterView: UIImageView {
  private var loadTask: URLSessionDataTask?
  private var currentUri: String?

  override init(frame: CGRect) {
    super.init(frame: frame)
    contentMode = .scaleAspectFill
    clipsToBounds = true
    backgroundColor = .black
    isUserInteractionEnabled = false
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) is not supported")
  }

  func setPoster(uri: String?) {
    guard uri != currentUri else { return }
    currentUri = uri
    loadTask?.cancel()
    image = nil

    guard let uri, let url = URL(string: uri) else { return }
    let task = URLSession.shared.dataTask(with: url) { [weak self] data, _, _ in
      guard let self, let data, let image = UIImage(data: data) else { return }
      DispatchQueue.main.async {
        guard self.currentUri == uri else { return }
        self.image = image
      }
    }
    loadTask = task
    task.resume()
  }
}
