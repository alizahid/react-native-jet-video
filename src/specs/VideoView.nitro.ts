import type {
  HybridView,
  HybridViewMethods,
  HybridViewProps,
} from 'react-native-nitro-modules'

export interface VideoSource {
  uri: string
  headers?: Record<string, string>
  /** Disk-cache this source (progressive formats only). Default true. */
  cache?: boolean
}

export type AutoplayMode = 'off' | 'always' | 'whenVisible'

export type ResizeMode = 'contain' | 'cover' | 'stretch'

export type AudioMixMode = 'mixWithOthers' | 'duckOthers' | 'doNotMix'

export type VisibilityAxis = 'both' | 'vertical' | 'horizontal'

export type PlaybackStatus =
  | 'idle'
  | 'loading'
  | 'readyToPlay'
  | 'buffering'
  | 'playing'
  | 'paused'
  | 'ended'
  | 'error'

export type PlaybackChangeReason = 'user' | 'coordinator' | 'system'

export interface LoadEvent {
  duration: number
  naturalWidth: number
  naturalHeight: number
  isLive: boolean
}

export interface ProgressEvent {
  currentTime: number
  /**
   * Absolute position (in seconds) up to which media is buffered contiguously
   * from the playhead — draw this behind the scrubber. Equals `currentTime`
   * when nothing ahead is buffered.
   */
  bufferedPosition: number
}

export interface PlaybackStateEvent {
  status: PlaybackStatus
  reason: PlaybackChangeReason
}

export interface VideoErrorEvent {
  code: string
  message: string
}

export interface VideoViewProps extends HybridViewProps {
  source?: VideoSource
  autoplayMode: AutoplayMode
  muted: boolean
  loop: boolean
  volume: number
  resizeMode: ResizeMode
  controls: boolean
  posterUri?: string
  allowsPictureInPicture: boolean
  progressUpdateInterval: number
  audioMixMode: AudioMixMode
  coordinatorGroup?: string
  visibilityAxis: VisibilityAxis
  /** Negative means "use the global configureAutoplay value". Never optional:
   * clearing an optional number prop makes Fabric send an explicit null,
   * which Nitro's prop parser rejects. */
  minVisibleFraction: number

  onLoad?: (event: LoadEvent) => void
  onProgress?: (event: ProgressEvent) => void
  onEnd?: () => void
  onError?: (event: VideoErrorEvent) => void
  onPlaybackStateChange?: (event: PlaybackStateEvent) => void
  onFullscreenChange?: (isFullscreen: boolean) => void
  onPictureInPictureChange?: (isActive: boolean) => void
  onMutedChange?: (muted: boolean) => void
  onVisibilityChange?: (visibleFraction: number) => void
}

export interface VideoViewMethods extends HybridViewMethods {
  play(): void
  pause(): void
  seek(seconds: number): Promise<void>
  getCurrentTime(): number
  enterFullscreen(): Promise<void>
  exitFullscreen(): Promise<void>
  startPictureInPicture(): Promise<void>
  stopPictureInPicture(): Promise<void>
}

export type VideoView = HybridView<
  VideoViewProps,
  VideoViewMethods,
  { ios: 'swift' }
>
