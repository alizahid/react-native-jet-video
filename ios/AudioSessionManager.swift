import AVFoundation

/// Manages the shared AVAudioSession so the library never interrupts other
/// apps' audio unless the developer opts in.
///
/// - Muted playback: `.ambient` + `.mixWithOthers` — background music keeps
///   playing under a muted feed (never touches the session otherwise).
/// - Unmuted playback / PiP: `.playback` with options derived from the view's
///   `audioMixMode` — `mixWithOthers` (default) keeps other audio running,
///   `duckOthers` lowers it, `doNotMix` interrupts it.
/// - Escalate-only: the category is never downgraded mid-session.
final class AudioSessionManager {
  static let shared = AudioSessionManager()
  static var isManagementEnabled = true

  private var escalated = false
  private var appliedOptions: AVAudioSession.CategoryOptions?

  /// Called just before any playback starts, and when a playing video unmutes.
  func willPlay(muted: Bool, mixMode: AudioMixMode) {
    guard Self.isManagementEnabled else { return }
    if muted {
      guard !escalated else { return }
      try? AVAudioSession.sharedInstance().setCategory(
        .ambient,
        mode: .moviePlayback,
        options: [.mixWithOthers]
      )
    } else {
      escalate(options: Self.options(for: mixMode))
    }
  }

  /// PiP requires the `.playback` category. For muted videos, mix regardless of
  /// the view's mode so starting PiP never interrupts other audio.
  func willStartPictureInPicture(muted: Bool, mixMode: AudioMixMode) {
    guard Self.isManagementEnabled else { return }
    escalate(options: muted ? [.mixWithOthers] : Self.options(for: mixMode))
  }

  private func escalate(options: AVAudioSession.CategoryOptions) {
    guard !escalated || appliedOptions != options else { return }
    let session = AVAudioSession.sharedInstance()
    try? session.setCategory(.playback, mode: .moviePlayback, options: options)
    try? session.setActive(true)
    escalated = true
    appliedOptions = options
  }

  private static func options(for mixMode: AudioMixMode) -> AVAudioSession.CategoryOptions {
    switch mixMode {
    case .mixwithothers:
      return [.mixWithOthers]
    case .duckothers:
      return [.duckOthers]
    case .donotmix:
      return []
    }
  }
}
