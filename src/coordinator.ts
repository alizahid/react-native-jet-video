import { NitroModules } from 'react-native-nitro-modules'
import type { AutoplayConfig, VideoConfig } from './specs/VideoConfig.nitro'

let config: VideoConfig | null = null

/**
 * Tunes the visibility-based autoplay election globally.
 * Optional — the defaults (50% visibility threshold, 10% hysteresis) fit most feeds.
 */
export function configureAutoplay(options: AutoplayConfig): void {
  config ??= NitroModules.createHybridObject<VideoConfig>('VideoConfig')
  config.configureAutoplay(options)
}

/**
 * Disable the library's automatic AVAudioSession management if your app
 * configures the audio session itself.
 */
export function setAudioSessionManagementEnabled(enabled: boolean): void {
  config ??= NitroModules.createHybridObject<VideoConfig>('VideoConfig')
  config.setAudioSessionManagementEnabled(enabled)
}

export type { AutoplayConfig }
