import AVFoundation
import ImageIO
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
      guard let self, let data, let image = Self.decodeDownsampled(data) else { return }
      DispatchQueue.main.async {
        guard self.currentUri == uri else { return }
        self.image = image
      }
    }
    loadTask = task
    task.resume()
  }

  /// Decodes capped at screen-size pixels: a feed of full-resolution posters
  /// would otherwise dominate memory (a 4000px image is ~35MB+ decoded).
  private static func decodeDownsampled(_ data: Data) -> UIImage? {
    let bounds = UIScreen.main.bounds.size
    let maxPixelSize = max(bounds.width, bounds.height) * UIScreen.main.scale
    let options: [CFString: Any] = [
      kCGImageSourceCreateThumbnailFromImageAlways: true,
      kCGImageSourceCreateThumbnailWithTransform: true,
      kCGImageSourceShouldCacheImmediately: true,
      kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
    ]
    guard let source = CGImageSourceCreateWithData(data as CFData, nil),
          let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
      return UIImage(data: data)
    }
    return UIImage(cgImage: thumbnail)
  }
}
