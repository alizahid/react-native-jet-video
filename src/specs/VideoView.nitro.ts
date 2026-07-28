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
  bufferedDuration: number
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
  autoEnterPiPOnBackground: boolean
  progressUpdateInterval: number
  audioMixMode: AudioMixMode
  coordinatorGroup?: string

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
