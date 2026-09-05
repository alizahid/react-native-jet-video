import type { HybridObject } from 'react-native-nitro-modules'

export interface AutoplayConfig {
  /** Minimum visible fraction (0–1) for a video to be autoplay-eligible. Default 0.2. Overridable per view via the `minVisibleFraction` prop. */
  minVisibleFraction?: number
  /** How much more visible a challenger must be to steal the election. Default 0.1. */
  hysteresis?: number
}

export interface PlayerPoolConfig {
  /** Most native players kept alive at once, across every screen. Default 10. */
  maxPlayers?: number
}

export interface PlayerPoolStats {
  /** Native players currently alive in the pool. */
  players: number
  /** Of those, how many hold a loaded item (the rest idle with just a playhead). */
  liveItems: number
}

export interface CacheConfig {
  /** Total disk budget for the video cache, in bytes. Default 1 GB. */
  maxSizeBytes?: number
}

export interface VideoConfig extends HybridObject<{ ios: 'swift' }> {
  configureAutoplay(config: AutoplayConfig): void
  configurePlayerPool(config: PlayerPoolConfig): void
  getPlayerPoolStats(): Promise<PlayerPoolStats>
  setAudioSessionManagementEnabled(enabled: boolean): void
  configureCache(config: CacheConfig): void
  clearCache(): Promise<void>
  getCacheSizeBytes(): Promise<number>
}
