import AVFoundation

/// Keeps the shared AVAudioSession in the one configuration this library
/// needs so playback never interrupts other apps' audio unless asked to.
///
/// - Category is always `.playback` (PiP and unmuted playback both require
///   it). Never `.ambient`: switching categories mid-playback rebuilds the
///   audio graph, which audibly pops when a feed video unmutes.
/// - Mode is `.default`, and the mode is never a reason to reconfigure.
///   Reconfiguring a session that another library has already *activated*
///   (react-native-sound-player's `setMixAudio(true)` does `playback` +
///   `mixWithOthers` + `setActive` at JS startup) interrupts other apps'
///   audio even though every option involved is mixable — verified on
///   device: the one `setCategory` call that switched an active session's
///   mode to `.moviePlayback` paused Apple Music. `.default` matches what
///   such libraries set, so the call is skipped; `.moviePlayback` only added
///   speaker EQ for dialogue, which a feed player doesn't need.
/// - Options: muted playback always mixes; unmuted playback uses the view's
///   `audioMixMode` (`mixWithOthers` by default, so still no interruption).
/// - The *real* session state is checked before every play, not a cached
///   copy: other libraries in the app may reconfigure the session at any
///   time, and AVPlayer implicitly activates whatever category is current.
///
/// Every AVAudioSession call is an XPC round-trip to mediaserverd that can
/// block for hundreds of milliseconds (seconds under contention at app
/// launch), so everything runs on a private serial queue.
final class AudioSessionManager {
  static let shared = AudioSessionManager()
  static var isManagementEnabled = true

  private let queue = DispatchQueue(label: "app.jet.video.audio-session", qos: .userInitiated)
  // Queue-confined: whether we activated the session and nothing has
  // deactivated it since (an interruption does).
  private var activated = false
  // Main-confined: the initial mixing configuration has landed, so player
  // items may be created (see `whenConfigured`).
  private var configured = false
  private var configurationWaiters: [() -> Void] = []

  private init() {
    NotificationCenter.default.addObserver(
      forName: AVAudioSession.interruptionNotification,
      object: AVAudioSession.sharedInstance(),
      queue: nil
    ) { [weak self] note in
      guard let self,
            let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
            AVAudioSession.InterruptionType(rawValue: raw) == .began else { return }
      queue.async { self.activated = false }
    }
  }

  /// Runs `body` (on main) once the session has its initial mixing
  /// configuration — synchronously if it already has. AVFoundation activates
  /// the session as soon as a player item is prepared, not only on play; on
  /// the default `soloAmbient` category that stops the user's music the
  /// moment a feed of videos mounts, before anything has played. So no item
  /// is attached until the category is a mixing one.
  func whenConfigured(_ body: @escaping () -> Void) {
    guard Self.isManagementEnabled, !configured else {
      body()
      return
    }
    configurationWaiters.append(body)
    guard configurationWaiters.count == 1 else { return }
    prepare(muted: true, mixMode: .mixwithothers, activate: false) { [self] in
      configured = true
      let waiters = configurationWaiters
      configurationWaiters = []
      waiters.forEach { $0() }
    }
  }

  /// Configures the session for playback and calls `completion` on main once
  /// it's safe to render audio — start (or unmute) playback only then, so the
  /// first audible sample never races the configuration.
  ///
  /// Muted playback never explicitly activates: only audible playback and
  /// PiP need an active session (AVPlayer activates implicitly anyway, and
  /// with a mixing category that can't interrupt anyone).
  func prepare(
    muted: Bool,
    mixMode: AudioMixMode,
    activate: Bool,
    completion: @escaping () -> Void
  ) {
    guard Self.isManagementEnabled else {
      completion()
      return
    }
    let options: AVAudioSession.CategoryOptions = muted ? [.mixWithOthers] : Self.options(for: mixMode)
    queue.async { [self] in
      let session = AVAudioSession.sharedInstance()
      if session.category != .playback || session.categoryOptions != options {
        try? session.setCategory(.playback, mode: .default, options: options)
      }
      if activate, !activated {
        activated = (try? session.setActive(true)) != nil
      }
      DispatchQueue.main.async(execute: completion)
    }
  }

  private static func options(for mixMode: AudioMixMode) -> AVAudioSession.CategoryOptions {
    switch mixMode {
    case .mixwithothers:
      return [.mixWithOthers]
    case .duckothers:
      // Ducking implies mixing; list both so the comparison with the live
      // session state (which reports both) is stable.
      return [.mixWithOthers, .duckOthers]
    case .donotmix:
      return []
    }
  }
}
