import Foundation

class HybridVideoConfig: HybridVideoConfigSpec {
  func configureAutoplay(config: AutoplayConfig) throws {
    DispatchQueue.main.async {
      if let minVisibleFraction = config.minVisibleFraction {
        PlaybackCoordinator.minVisibleFraction = min(1, max(0, minVisibleFraction))
      }
      if let hysteresis = config.hysteresis {
        PlaybackCoordinator.hysteresis = min(1, max(0, hysteresis))
      }
    }
  }

  func setAudioSessionManagementEnabled(enabled: Bool) throws {
    DispatchQueue.main.async {
      AudioSessionManager.isManagementEnabled = enabled
    }
  }
}
