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
  private var appliedCategory: AVAudioSession.Category?
  private var appliedOptions: AVAudioSession.CategoryOptions?

  /// Called just before any playback starts, and when a playing video unmutes.
  func willPlay(muted: Bool, mixMode: AudioMixMode) {
    guard Self.isManagementEnabled else { return }
    if muted {
      guard !escalated else { return }
      apply(category: .ambient, options: [.mixWithOthers], activate: false)
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

  /// Category pre-arming for auto-PiP at view mount: `.playback` is required
  /// for the system to auto-enter PiP on backgrounding, but mounting must
  /// never interrupt other audio — always mix; playback applies the real mode.
  func prepareForPictureInPicture() {
    guard Self.isManagementEnabled else { return }
    escalate(options: [.mixWithOthers])
  }

  private func escalate(options: AVAudioSession.CategoryOptions) {
    guard !escalated || appliedOptions != options else { return }
    // Activate only on the first escalation — the session stays active after
    // that, and redundant setActive(true) calls audibly dip other apps' audio.
    apply(category: .playback, options: options, activate: !escalated)
    escalated = true
  }

  /// Applies the category only when it actually changes: every setCategory
  /// call rebuilds the audio route, which can pop mid-playback and duck other
  /// apps' audio — repeated same-value sets are pure downside.
  private func apply(
    category: AVAudioSession.Category,
    options: AVAudioSession.CategoryOptions,
    activate: Bool
  ) {
    let session = AVAudioSession.sharedInstance()
    if appliedCategory != category || appliedOptions != options {
      try? session.setCategory(category, mode: .moviePlayback, options: options)
      appliedCategory = category
      appliedOptions = options
    }
    if activate {
      try? session.setActive(true)
    }
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
