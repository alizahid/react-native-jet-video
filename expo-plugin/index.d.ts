import type { ConfigPlugin } from 'expo/config-plugins'

export type JetVideoPluginOptions = {
  /**
   * Adds the `audio` background mode, required for Picture-in-Picture
   * (including auto-PiP on backgrounding).
   *
   * @default false
   */
  supportsPictureInPicture?: boolean

  /**
   * Adds the `audio` background mode so playback continues when the app is
   * backgrounded.
   *
   * @default false
   */
  supportsBackgroundPlayback?: boolean
}

/**
 * Usage in app.config.ts:
 *
 * ```ts
 * plugins: [withJetVideo({ supportsPictureInPicture: true })]
 * ```
 */
declare function withJetVideo(options?: JetVideoPluginOptions): ConfigPlugin

/** Classic `(config, props)` plugin, used by `app.plugin.js` for the string form. */
declare const appPlugin: ConfigPlugin<JetVideoPluginOptions | void>

export default withJetVideo
export { appPlugin, withJetVideo }
