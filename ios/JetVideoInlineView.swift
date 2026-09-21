import UIKit

/// A native host for the same player used by VideoView, without a React tree.
/// The stable Objective-C name lets optional consumers discover it at runtime.
@objc(JetVideoInlineView)
public final class JetVideoInlineView: UIView {
  private let player = HybridVideoView()
  private let playButton = UIButton(type: .system)
  private var sourceURI = ""
  private var posterURI = ""

  public override init(frame: CGRect) {
    super.init(frame: frame)
    player.controls = true
    player.keepsPosterUntilPlay = true
    // Reuse the coordinator's clipping-aware visibility tracking without
    // opting into autoplay. Returning on screen still requires a tap.
    player.onVisibilityChange = { [weak self] fraction in
      guard let self, !player.isFullscreen, !player.isInPictureInPicture else { return }
      let threshold = player.minVisibleFraction >= 0
        ? player.minVisibleFraction : PlaybackCoordinator.minVisibleFraction
      if fraction < max(0.001, threshold) {
        player.engine?.pause(reason: .system)
      }
    }
    player.resizeMode = .contain
    player.view.frame = bounds
    player.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    addSubview(player.view)

    playButton.setImage(UIImage(systemName: "play.circle.fill"), for: .normal)
    playButton.setPreferredSymbolConfiguration(
      UIImage.SymbolConfiguration(pointSize: 52), forImageIn: .normal
    )
    playButton.tintColor = .white
    playButton.accessibilityLabel = "Play video"
    playButton.addTarget(self, action: #selector(play), for: .touchUpInside)
    playButton.frame = bounds
    playButton.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    addSubview(playButton)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) is not supported")
  }

  @objc(configureSource:poster:)
  public func configure(source: String, poster: String) {
    // Rebinding an unchanged markdown block must not restart playback.
    if source != sourceURI {
      sourceURI = source
      player.keepsPosterUntilPlay = true
      player.source = source.isEmpty ? nil : VideoSource(uri: source, headers: nil, cache: nil)
      playButton.isHidden = false
    }
    if poster != posterURI {
      posterURI = poster
      player.posterUri = poster
    }
    playButton.isEnabled = !source.isEmpty
  }

  @objc private func play() {
    player.keepsPosterUntilPlay = false
    player.ensureEngine(force: true)?.play(reason: .user)
    playButton.isHidden = true
  }

  deinit {
    // Native hosts own the hybrid directly; release pooled playback and
    // controller containment when the markdown block is recycled away.
    player.onDropView()
  }
}
