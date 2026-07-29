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
 * Returns the static plugin tuple for `ExpoConfig['plugins']`:
 *
 * ```ts
 * plugins: [withJetVideo({ supportsPictureInPicture: true })]
 * ```
 */
declare function withJetVideo(
  options?: JetVideoPluginOptions,
): [string, JetVideoPluginOptions]

/** The actual `(config, props)` plugin, resolved via `app.plugin.js`. */
declare const appPlugin: ConfigPlugin<JetVideoPluginOptions | void>

export default withJetVideo
export { appPlugin, withJetVideo }
