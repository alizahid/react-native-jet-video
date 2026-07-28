import Foundation
import NitroModules

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

  func configureCache(config: CacheConfig) throws {
    if let maxSizeBytes = config.maxSizeBytes, maxSizeBytes > 0 {
      VideoCache.shared.maxSizeBytes = Int64(maxSizeBytes)
      VideoCache.shared.enforceLimit()
    }
  }

  func clearCache() throws -> Promise<Void> {
    let promise = Promise<Void>()
    VideoCache.shared.clear {
      promise.resolve(withResult: ())
    }
    return promise
  }

  func getCacheSizeBytes() throws -> Promise<Double> {
    let promise = Promise<Double>()
    VideoCache.shared.totalSize { size in
      promise.resolve(withResult: Double(size))
    }
    return promise
  }
}
