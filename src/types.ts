import type { StyleProp, ViewStyle } from 'react-native'
import type {
  AudioMixMode,
  PlaybackChangeReason,
  PlaybackStatus,
  ProgressEvent,
  VideoErrorEvent,
} from './specs/VideoView.nitro'

export type {
  AudioMixMode,
  PlaybackChangeReason,
  PlaybackStatus,
  ProgressEvent,
  VideoErrorEvent,
}

/**
 * A video source: either a URI string, or an object with a URI, optional
 * HTTP headers sent with every request, and an optional cache opt-out.
 */
export type VideoSource =
  | string
  | {
      uri: string
      headers?: Record<string, string>
      /**
       * Disk-cache this source so later playbacks (even after partial
       * streaming) load from disk. Progressive formats only (MP4, MOV, M4A…);
       * HLS streams are never disk-cached. Default true.
       */
      cache?: boolean
    }

export interface VideoLoadEvent {
  /** Duration in seconds, or -1 for live streams. */
  duration: number
  naturalSize: {
    width: number
    height: number
  }
  isLive: boolean
}

export interface VideoPlaybackStateEvent {
  status: PlaybackStatus
  /** What triggered the change: a user action, the autoplay coordinator, or the system. */
  reason: PlaybackChangeReason
}

export interface VideoViewProps {
  source: VideoSource
  /**
   * `false` (default): never autoplay. `true`: play as soon as the source is ready.
   * `'whenVisible'`: this view participates in visibility-based autoplay — of all
   * mounted `whenVisible` views, only the most visible one plays at a time.
   */
  autoplay?: boolean | 'whenVisible'
  muted?: boolean
  loop?: boolean
  /** Playback volume from 0 to 1. Independent of `muted`. */
  volume?: number
  resizeMode?: 'contain' | 'cover' | 'stretch'
  /** Show native playback controls. */
  controls?: boolean
  /** Image shown until the first video frame is ready. */
  poster?: string
  allowsPictureInPicture?: boolean
  /** Automatically enter PiP when the app moves to the background. */
  autoEnterPiPOnBackground?: boolean
  /** How often `onProgress` fires, in milliseconds. 0 disables it. Default 500. */
  progressUpdateInterval?: number
  /**
   * How this video's audio interacts with other apps' audio when unmuted.
   * Default `'mixWithOthers'` — playing a video never interrupts e.g. background music.
   */
  audioMixMode?: AudioMixMode
  /**
   * Visibility-autoplay election group. Views in different groups elect
   * independently. Defaults to a single global group.
   */
  coordinatorGroup?: string
  style?: StyleProp<ViewStyle>
  testID?: string

  onLoad?: (event: VideoLoadEvent) => void
  onProgress?: (event: ProgressEvent) => void
  onEnd?: () => void
  onError?: (event: VideoErrorEvent) => void
  onPlaybackStateChange?: (event: VideoPlaybackStateEvent) => void
  onFullscreenChange?: (isFullscreen: boolean) => void
  onPictureInPictureChange?: (isActive: boolean) => void
  /** Fires when native controls change the mute state. Mirror it into your `muted` prop. */
  onMutedChange?: (muted: boolean) => void
  /** Fires (throttled) with this view's visible fraction, 0–1. */
  onVisibilityChange?: (visibleFraction: number) => void
}

export interface VideoViewRef {
  play(): void
  pause(): void
  /** Seeks to the given position in seconds. Resolves when the seek completes. */
  seek(seconds: number): Promise<void>
  /** Returns the current playback position in seconds, synchronously. */
  getCurrentTime(): number
  enterFullscreen(): Promise<void>
  exitFullscreen(): Promise<void>
  startPictureInPicture(): Promise<void>
  stopPictureInPicture(): Promise<void>
}
