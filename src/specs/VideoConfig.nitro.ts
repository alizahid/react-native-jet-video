import type { HybridObject } from 'react-native-nitro-modules'

export interface AutoplayConfig {
  /** Minimum visible fraction (0–1) for a video to be autoplay-eligible. Default 0.2. Overridable per view via the `minVisibleFraction` prop. */
  minVisibleFraction?: number
  /** How much more visible a challenger must be to steal the election. Default 0.1. */
  hysteresis?: number
}

export interface CacheConfig {
  /** Total disk budget for the video cache, in bytes. Default 1 GB. */
  maxSizeBytes?: number
}

export interface VideoConfig extends HybridObject<{ ios: 'swift' }> {
  configureAutoplay(config: AutoplayConfig): void
  setAudioSessionManagementEnabled(enabled: boolean): void
  configureCache(config: CacheConfig): void
  clearCache(): Promise<void>
  getCacheSizeBytes(): Promise<number>
}
