import type {
  AutoplayMode,
  VideoSource as NativeVideoSource,
} from './specs/VideoView.nitro'
import type { VideoSource } from './types'

export function normalizeSource(source: VideoSource): NativeVideoSource {
  if (typeof source === 'string') {
    return { uri: source }
  }
  return { uri: source.uri, headers: source.headers }
}

/**
 * A stable value-identity key for a source, so re-renders with an equivalent
 * source never reach native as a prop change (which would reset the player —
 * fatal inside recycling lists).
 */
export function sourceKey(source: VideoSource): string {
  return typeof source === 'string' ? source : JSON.stringify(source)
}

export function autoplayModeFor(
  autoplay: boolean | 'whenVisible' | undefined
): AutoplayMode {
  if (autoplay === 'whenVisible') {
    return 'whenVisible'
  }
  return autoplay ? 'always' : 'off'
}
