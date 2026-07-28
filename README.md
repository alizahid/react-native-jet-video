<p align="center">
  <img alt="react-native-jet-video — single-component video view for React Native with visibility autoplay, PiP, and caching" src="https://raw.githubusercontent.com/alizahid/react-native-jet-video/main/docs/hero.svg" width="900">
</p>

<p align="center">
  Single-component video for React Native — visibility autoplay, fullscreen, PiP &amp; disk caching
</p>

<p align="center">
  <a href="https://www.npmjs.com/package/react-native-jet-video"><img src="https://img.shields.io/npm/v/react-native-jet-video?color=A02F6F&label=npm" alt="npm"></a>
  <a href="https://github.com/alizahid/react-native-jet-video/blob/main/LICENSE"><img src="https://img.shields.io/npm/l/react-native-jet-video?color=668C0B" alt="license"></a>
  <img src="https://img.shields.io/badge/platform-iOS-5E409D" alt="platform">
  <img src="https://img.shields.io/badge/powered%20by-Nitro-205EA6" alt="nitro">
</p>

---

A single-component video view for React Native, powered by [Nitro Modules](https://nitro.margelo.com) and AVFoundation.

No player objects. No view/player wiring. Just a view:

```tsx
import { VideoView } from 'react-native-jet-video'

<VideoView source="https://example.com/video.mp4" autoplay muted style={styles.video} />
```

## The headline: feeds that just work

Drop `VideoView` into a [FlashList](https://shopify.github.io/flash-list/) (or any scroll container) with `autoplay="whenVisible"`, and the library's native playback coordinator makes sure **only the most-visible video plays** — the rest stay paused. No viewability callbacks, no scroll listeners, no JS wiring:

```tsx
<FlashList
  data={items}
  renderItem={({ item }) => (
    <VideoView
      source={item.uri}
      autoplay="whenVisible"
      muted
      loop
      style={styles.video}
    />
  )}
/>
```

How the election works (all native, ~10 Hz, works with nested/clipped scroll views):

- A video is eligible once it's ≥50% visible; the most-visible eligible video plays.
- When two videos are comparably visible (e.g. both fully on screen), the one **closest to the center of the screen** plays — so scrolling in either direction hands playback to the video you're looking at.
- Hysteresis + debouncing prevent flapping when two videos are near 50/50.
- If the user pauses a video (ref or tap), the coordinator **never force-resumes it** — until it scrolls fully away, which resets it like feeds you know.
- If the user plays a video explicitly, it wins the election until it scrolls below the threshold.
- A video in Picture-in-Picture suspends the election entirely — nothing plays alongside it.
- Views are recycled correctly: a source change fully resets the player, position, and overrides.

Tune it globally if needed:

```ts
import { configureAutoplay } from 'react-native-jet-video'

configureAutoplay({ minVisibleFraction: 0.6, hysteresis: 0.15 })
```

Use `coordinatorGroup="stories"` to run independent elections for separate lists on one screen.

## Installation

```sh
npm install react-native-jet-video react-native-nitro-modules
cd ios && pod install
```

Requires the React Native new architecture (default since RN 0.76). iOS only for now — Android is planned; the TypeScript API is platform-agnostic.

Expo: works in a [development build](https://docs.expo.dev/develop/development-builds/introduction/) (not Expo Go).

## API

### Props

| Prop | Type | Default | |
|---|---|---|---|
| `source` | `string \| { uri, headers? }` | — | MP4, HLS (`.m3u8`), anything AVPlayer speaks |
| `autoplay` | `boolean \| 'whenVisible'` | `false` | `'whenVisible'` enables the coordinator |
| `muted` | `boolean` | `false` | |
| `loop` | `boolean` | `false` | |
| `volume` | `number` | `1` | 0–1, independent of `muted` |
| `resizeMode` | `'cover' \| 'contain' \| 'stretch'` | `'cover'` | |
| `controls` | `boolean` | `false` | Native system playback controls |
| `poster` | `string` | — | Image shown until the first frame renders |
| `allowsPictureInPicture` | `boolean` | `false` | Enables PiP, incl. auto-PiP on backgrounding |
| `progressUpdateInterval` | `number` | `500` | ms between `onProgress`; `0` disables |
| `audioMixMode` | `'mixWithOthers' \| 'duckOthers' \| 'doNotMix'` | `'mixWithOthers'` | See audio section |
| `coordinatorGroup` | `string` | — | Separate election groups |

### Events

`onLoad({ duration, naturalSize, isLive })` · `onProgress({ currentTime, bufferedPosition })` · `onEnd()` · `onError({ code, message })` · `onPlaybackStateChange({ status, reason })` · `onFullscreenChange(isFullscreen)` · `onPictureInPictureChange(isActive)` · `onMutedChange(muted)` · `onVisibilityChange(visibleFraction)`

`status` is `idle | loading | readyToPlay | buffering | playing | paused | ended | error`. `reason` tells you **who** caused the change: `user`, `coordinator`, or `system` — so your UI can react to coordination without fighting it.

### Ref methods

```tsx
const ref = useRef<VideoViewRef>(null)

ref.current?.play()
ref.current?.pause()
await ref.current?.seek(seconds)        // resolves when the seek completes
ref.current?.getCurrentTime()           // synchronous, thanks to Nitro
await ref.current?.enterFullscreen()
await ref.current?.exitFullscreen()
await ref.current?.startPictureInPicture()
await ref.current?.stopPictureInPicture()
```

## Why is there no `paused` prop?

Playback state has three writers: your code, the user (native controls), and the visibility coordinator — the last two live on the native side. A controlled `paused` prop would be stale the moment the coordinator elects a different video, and re-asserting it would fight the election.

Instead, playback is **uncontrolled** with a strict precedence: user intent > coordinator > autoplay policy. Drive it with `play()`/`pause()` on the ref, and mirror truth with `onPlaybackStateChange` (the `reason` field tells you who did what).

## Audio behavior

The library never interrupts other apps' audio unless you ask it to:

- **Muted playback** uses the `ambient` audio category with mixing — a muted feed never stops the user's music. (This is the classic video-library bug; it's handled.)
- **Unmuted playback** escalates to the `playback` category with options from `audioMixMode`:
  - `'mixWithOthers'` (default): the user's music keeps playing alongside your video.
  - `'duckOthers'`: other audio ducks under your video.
  - `'doNotMix'`: other audio is interrupted (the traditional video-app behavior — opt-in).

If your app manages its own `AVAudioSession`, opt out entirely:

```ts
import { setAudioSessionManagementEnabled } from 'react-native-jet-video'

setAudioSessionManagementEnabled(false)
```

## Caching

Progressive sources (MP4, MOV, M4A, …) are **disk-cached automatically**, including partially streamed ones: whatever bytes were streamed are kept as ranges on disk, so a later playback — even after an app restart — serves from cache instantly and only fetches the missing ranges. The cache is LRU-evicted against a 1 GB budget by default.

```ts
import { clearCache, configureCache, getCacheSize } from 'react-native-jet-video'

configureCache({ maxSizeBytes: 512 * 1024 * 1024 })
const bytes = await getCacheSize()
await clearCache()
```

Opt out per source with `source={{ uri, cache: false }}`.

HLS streams are **not** disk-cached (AVPlayer buffers them in memory); caching applies to progressive downloads only.

## Picture-in-Picture setup

1. Set `allowsPictureInPicture` on the view. That one flag enables the PiP methods **and** automatic PiP: backgrounding the app pops the currently playing video into a PiP window.
2. In Xcode, enable **Background Modes → Audio, AirPlay, and Picture in Picture** for your app target (adds `UIBackgroundModes: [audio]` to Info.plist).

`startPictureInPicture()` rejects if PiP isn't possible (unsupported device, missing background mode). Note: the iOS *simulator* only supports PiP on iPad simulators; test iPhone PiP on a device.

## Fullscreen

- `controls` gives you the system inline controls, including the system fullscreen button.
- `enterFullscreen()` works even with `controls={false}` — it presents a system player fullscreen over your app.
- Fullscreen playback survives the originating cell being recycled or unmounted (relevant inside lists).

## Example app

`example/` is an Expo dev-client app with screens for each feature — `BasicPlayback`, `RefMethods`, `Feed` (200-item FlashList stress test), `Fullscreen`, `PictureInPicture`, `Cache`:

```sh
bun install
cd example
bun run ios
```

## License

MIT © Ali Zahid
