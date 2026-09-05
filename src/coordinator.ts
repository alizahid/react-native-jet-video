import { NitroModules } from 'react-native-nitro-modules'
import type {
  AutoplayConfig,
  CacheConfig,
  PlayerPoolConfig,
  PlayerPoolStats,
  VideoConfig,
} from './specs/VideoConfig.nitro'

let config: VideoConfig | null = null

function nativeConfig(): VideoConfig {
  config ??= NitroModules.createHybridObject<VideoConfig>('VideoConfig')
  return config
}

/**
 * Tunes the visibility-based autoplay election globally.
 * Optional — the defaults (20% visibility threshold, 10% hysteresis) fit most
 * feeds. The threshold can also be overridden per view with the
 * `minVisibleFraction` prop.
 */
export function configureAutoplay(options: AutoplayConfig): void {
  nativeConfig().configureAutoplay(options)
}

/**
 * Bounds the pool of native players shared by every `VideoView` in the app
 * (default 5). The least recently used player that nothing is displaying is
 * released to make room; its playhead is remembered.
 */
export function configurePlayerPool(options: PlayerPoolConfig): void {
  nativeConfig().configurePlayerPool(options)
}

/** How many native players the pool holds right now, and how many have a loaded item. */
export function getPlayerPoolStats(): Promise<PlayerPoolStats> {
  return nativeConfig().getPlayerPoolStats()
}

/**
 * Disable the library's automatic AVAudioSession management if your app
 * configures the audio session itself.
 */
export function setAudioSessionManagementEnabled(enabled: boolean): void {
  nativeConfig().setAudioSessionManagementEnabled(enabled)
}

/**
 * Configures the video disk cache (progressive sources are cached
 * automatically, including partially streamed ones).
 */
export function configureCache(options: CacheConfig): void {
  nativeConfig().configureCache(options)
}

/** Deletes all cached video data. */
export function clearCache(): Promise<void> {
  return nativeConfig().clearCache()
}

/** Current size of the video cache on disk, in bytes. */
export function getCacheSize(): Promise<number> {
  return nativeConfig().getCacheSizeBytes()
}

export type { AutoplayConfig, CacheConfig, PlayerPoolConfig, PlayerPoolStats }
