import AVFoundation

/// Manages the shared AVAudioSession so the library never interrupts other
/// apps' audio unless the developer opts in.
///
/// - Muted playback: `.ambient` + `.mixWithOthers` — background music keeps
///   playing under a muted feed (never touches the session otherwise).
/// - Muted playback that must support PiP: `.playback` + `.mixWithOthers` —
///   PiP requires the playback category, but mixing still never interrupts.
/// - Unmuted playback / PiP: `.playback` with options derived from the view's
///   `audioMixMode` — `mixWithOthers` (default) keeps other audio running,
///   `duckOthers` lowers it, `doNotMix` interrupts it.
/// - Escalate-only: the category is never downgraded mid-session.
///
/// Every AVAudioSession call is an XPC round-trip to mediaserverd that can
/// block for hundreds of milliseconds (seconds under contention at app
/// launch) — so the actual session calls run on a private serial queue,
/// never the calling thread. Decision state lives on the main thread (all
/// entry points are main-thread), which also lets a no-op request complete
/// synchronously without paying the queue hop before playback starts.
final class AudioSessionManager {
  static let shared = AudioSessionManager()
  static var isManagementEnabled = true

  private let queue = DispatchQueue(label: "app.jet.video.audio-session", qos: .userInitiated)

  // Main-thread state describing what has been (or is queued to be) applied.
  private var playbackCategoryApplied = false
  private var activated = false
  private var targetCategory: AVAudioSession.Category?
  private var targetOptions: AVAudioSession.CategoryOptions?

  /// Called just before any playback starts, and when a playing video
  /// unmutes. `completion` fires (on main) once the session is configured —
  /// start playback then, so the first audio render never races the category
  /// change (which audibly pops mid-stream).
  ///
  /// Muted playback never explicitly activates the session — an inactive
  /// session can never interrupt another app's audio, no matter the category.
  /// Only audible playback (or starting PiP) activates.
  func willPlay(
    muted: Bool,
    mixMode: AudioMixMode,
    requiresPlaybackCategory: Bool,
    completion: @escaping () -> Void
  ) {
    guard Self.isManagementEnabled else {
      completion()
      return
    }
    if muted {
      if requiresPlaybackCategory {
        setPlayback(options: [.mixWithOthers], activate: false, completion: completion)
      } else if !playbackCategoryApplied {
        apply(category: .ambient, options: [.mixWithOthers], activate: false, completion: completion)
      } else {
        completion()
      }
    } else {
      setPlayback(options: Self.options(for: mixMode), activate: true, completion: completion)
    }
  }

  /// PiP requires the `.playback` category and an active session. For muted
  /// videos, mix regardless of the view's mode so starting PiP never
  /// interrupts other audio.
  func willStartPictureInPicture(
    muted: Bool,
    mixMode: AudioMixMode,
    completion: @escaping () -> Void
  ) {
    guard Self.isManagementEnabled else {
      completion()
      return
    }
    setPlayback(options: muted ? [.mixWithOthers] : Self.options(for: mixMode), activate: true, completion: completion)
  }

  /// Escalates to the `.playback` category (never downgraded afterwards) and
  /// activates at most once, only when audible playback or PiP demands it.
  private func setPlayback(
    options: AVAudioSession.CategoryOptions,
    activate: Bool,
    completion: @escaping () -> Void
  ) {
    let needsActivation = activate && !activated
    guard !playbackCategoryApplied || targetOptions != options || needsActivation else {
      completion()
      return
    }
    playbackCategoryApplied = true
    if needsActivation {
      activated = true
    }
    apply(category: .playback, options: options, activate: needsActivation, completion: completion)
  }

  /// Applies the category only when it actually changes: every setCategory
  /// call rebuilds the audio route, which can pop mid-playback and duck other
  /// apps' audio — repeated same-value sets are pure downside.
  private func apply(
    category: AVAudioSession.Category,
    options: AVAudioSession.CategoryOptions,
    activate: Bool,
    completion: @escaping () -> Void
  ) {
    let changed = targetCategory != category || targetOptions != options
    targetCategory = category
    targetOptions = options
    guard changed || activate else {
      completion()
      return
    }
    queue.async {
      let session = AVAudioSession.sharedInstance()
      if changed {
        try? session.setCategory(category, mode: .moviePlayback, options: options)
      }
      if activate {
        try? session.setActive(true)
      }
      DispatchQueue.main.async(execute: completion)
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
