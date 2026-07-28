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
    // Unvalidated JS numbers: Int64(Infinity) or Int64(1e19) traps at runtime.
    if let maxSizeBytes = config.maxSizeBytes, maxSizeBytes.isFinite,
       maxSizeBytes >= 1, maxSizeBytes < 9e18 {
      VideoCache.shared.configure(maxSizeBytes: Int64(maxSizeBytes))
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
