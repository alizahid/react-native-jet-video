import {
  forwardRef,
  useCallback,
  useImperativeHandle,
  useMemo,
  useRef,
} from 'react'
import {
  callback,
  getHostComponent,
  type HybridRef,
} from 'react-native-nitro-modules'
import VideoViewConfig from '../nitrogen/generated/shared/json/VideoViewConfig.json'
import { autoplayModeFor, normalizeSource, sourceKey } from './normalize'
import type {
  LoadEvent,
  VideoViewProps as NativeVideoViewProps,
  VideoViewMethods,
} from './specs/VideoView.nitro'
import type { VideoViewProps, VideoViewRef } from './types'

const NativeVideoView = getHostComponent<
  NativeVideoViewProps,
  VideoViewMethods
>('VideoView', () => VideoViewConfig)

// The hybrid object behind the native view: props + methods on one instance.
type VideoHybrid = HybridRef<NativeVideoViewProps, VideoViewMethods>

function notMounted(): never {
  throw new Error('VideoView is not mounted')
}

const noop = () => {}

// `callback()` allocates a fresh wrapper object, so wrapping inline would
// mark every callback prop dirty on each parent re-render. A missing handler
// becomes a noop rather than undefined: see the note on the native props.
function useNitroCallback<T extends (...args: never[]) => void>(
  fn: T | undefined
) {
  return useMemo(() => callback(fn ?? (noop as T)), [fn])
}

// Promise-returning methods reject instead of throwing synchronously.
function notMountedAsync(): Promise<never> {
  return Promise.reject(new Error('VideoView is not mounted'))
}

export const VideoView = forwardRef<VideoViewRef, VideoViewProps>(
  function VideoView(props, ref) {
    const {
      source,
      autoplay = false,
      muted = false,
      loop = false,
      volume = 1,
      resizeMode = 'cover',
      controls = false,
      poster,
      playerKey,
      allowsPictureInPicture = false,
      progressUpdateInterval = 500,
      audioMixMode = 'mixWithOthers',
      coordinatorGroup,
      visibilityAxis = 'both',
      minVisibleFraction = -1,
      style,
      testID,
      onLoad,
      onProgress,
      onEnd,
      onError,
      onPlaybackStateChange,
      onFullscreenChange,
      onPictureInPictureChange,
      onMutedChange,
      onVisibilityChange,
    } = props

    const hybrid = useRef<VideoHybrid | null>(null)

    // Memoize by value so a re-render with an equivalent source object never
    // reaches native as a prop change (which would reset the player — fatal
    // inside recycling lists).
    const key = sourceKey(source)
    // biome-ignore lint/correctness/useExhaustiveDependencies: key is the value identity of source
    const nativeSource = useMemo(() => normalizeSource(source), [key])

    const autoplayMode = autoplayModeFor(autoplay)

    const hybridRef = useMemo(
      () =>
        callback((instance: VideoHybrid) => {
          hybrid.current = instance
        }),
      []
    )

    useImperativeHandle(
      ref,
      () => ({
        play: () => (hybrid.current ?? notMounted()).play(),
        pause: () => (hybrid.current ?? notMounted()).pause(),
        seek: (seconds: number) =>
          hybrid.current ? hybrid.current.seek(seconds) : notMountedAsync(),
        getCurrentTime: () => (hybrid.current ?? notMounted()).getCurrentTime(),
        enterFullscreen: () =>
          hybrid.current ? hybrid.current.enterFullscreen() : notMountedAsync(),
        exitFullscreen: () =>
          hybrid.current ? hybrid.current.exitFullscreen() : notMountedAsync(),
        startPictureInPicture: () =>
          hybrid.current
            ? hybrid.current.startPictureInPicture()
            : notMountedAsync(),
        stopPictureInPicture: () =>
          hybrid.current
            ? hybrid.current.stopPictureInPicture()
            : notMountedAsync(),
      }),
      []
    )

    const handleLoad = useCallback(
      (event: LoadEvent) => {
        onLoad?.({
          duration: event.duration,
          naturalSize: {
            width: event.naturalWidth,
            height: event.naturalHeight,
          },
          isLive: event.isLive,
        })
      },
      [onLoad]
    )

    const nativeOnLoad = useNitroCallback(onLoad ? handleLoad : undefined)
    const nativeOnProgress = useNitroCallback(onProgress)
    const nativeOnEnd = useNitroCallback(onEnd)
    const nativeOnError = useNitroCallback(onError)
    const nativeOnPlaybackStateChange = useNitroCallback(onPlaybackStateChange)
    const nativeOnFullscreenChange = useNitroCallback(onFullscreenChange)
    const nativeOnPictureInPictureChange = useNitroCallback(
      onPictureInPictureChange
    )
    const nativeOnMutedChange = useNitroCallback(onMutedChange)
    const nativeOnVisibilityChange = useNitroCallback(onVisibilityChange)

    return (
      <NativeVideoView
        hybridRef={hybridRef}
        source={nativeSource}
        autoplayMode={autoplayMode}
        muted={muted}
        loop={loop}
        volume={volume}
        resizeMode={resizeMode}
        controls={controls}
        posterUri={poster ?? ''}
        playerKey={playerKey ?? ''}
        allowsPictureInPicture={allowsPictureInPicture}
        progressUpdateInterval={progressUpdateInterval}
        audioMixMode={audioMixMode}
        coordinatorGroup={coordinatorGroup ?? ''}
        visibilityAxis={visibilityAxis}
        minVisibleFraction={minVisibleFraction}
        style={style}
        testID={testID}
        onLoad={nativeOnLoad}
        onProgress={nativeOnProgress}
        onEnd={nativeOnEnd}
        onError={nativeOnError}
        onPlaybackStateChange={nativeOnPlaybackStateChange}
        onFullscreenChange={nativeOnFullscreenChange}
        onPictureInPictureChange={nativeOnPictureInPictureChange}
        onMutedChange={nativeOnMutedChange}
        onVisibilityChange={nativeOnVisibilityChange}
      />
    )
  }
)
