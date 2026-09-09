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

A single-component video view for React Native, powered by [Nitro Modules](https://nitro.margelo.com) and AVFoundation. No player objects, no view/player wiring — just a view:

```tsx
import { VideoView } from 'react-native-jet-video'

<VideoView source="https://example.com/video.mp4" autoplay muted style={styles.video} />
```

## Contents

- [Installation](#installation)
- [Feeds that just work](#feeds-that-just-work)
- [One shared pool of players](#one-shared-pool-of-players)
- [API](#api)
- [Playback control](#playback-control)
- [Audio](#audio)
- [Caching](#caching)
- [Fullscreen](#fullscreen)
- [Picture-in-Picture](#picture-in-picture)
- [Example app](#example-app)

## Installation

```sh
npm install react-native-jet-video react-native-nitro-modules
cd ios && pod install
```

- Requires the React Native new architecture (default since RN 0.76).
- iOS only for now. Android is planned; the TypeScript API is platform-agnostic.
- Expo: works in a [development build](https://docs.expo.dev/develop/development-builds/introduction/), not Expo Go. See [Picture-in-Picture](#picture-in-picture) for the config plugin.

## Feeds that just work

Drop `VideoView` into a [FlashList](https://shopify.github.io/flash-list/) (or any scroll container) with `autoplay="whenVisible"`, and the native playback coordinator makes sure **only the most prominent video plays** — the rest stay paused. No viewability callbacks, no scroll listeners, no JS wiring:

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

### How the election works

All native, ~10 Hz, works with nested and clipped scroll views:

- **Eligibility.** A video is eligible once it's ≥20% visible, and stops once it drops below. Visibility is measured against what the layout shows — a video cropped by an `overflow: hidden` cell is fully visible when the cell is — and content under a transparent header or translucent tab bar doesn't count.
- **Ranking.** Among eligible videos, the one covering the most screen *and* least cut off plays: a tall video filling half the screen beats a short one below it, but once the tall one is half hidden under the header, the short one fully in view takes over. When two are comparable, the first in reading order plays — the top one in a feed, the leftmost in a carousel.
- **Warm start.** Any video that's even slightly on screen is loaded and prerolled, so the moment it's elected it starts on the next frame.
- **No flapping.** Hysteresis and debouncing keep two videos near 50/50 from trading places.
- **User intent wins.** A user pause (ref or native controls) is never force-resumed until the video scrolls fully away, which resets it like the feeds you know. A user play wins the election until the video drops below the threshold.
- **PiP suspends the election** — nothing plays alongside a video in Picture-in-Picture.
- **Recycling is safe.** A source change fully resets the player, position, and overrides.

Tune the threshold per view with `minVisibleFraction`, or globally:

```ts
import { configureAutoplay } from 'react-native-jet-video'

configureAutoplay({ minVisibleFraction: 0.6, hysteresis: 0.15 })
```

Use `coordinatorGroup="stories"` to run independent elections for separate lists on one screen.

### Swipeable cards: `visibilityAxis`

If your feed cells swipe **horizontally** for actions (upvote, dismiss, reveal buttons), area-based visibility would count the card as "less visible" mid-swipe and pause it. Set `visibilityAxis="vertical"` and only vertical coverage counts — the video keeps playing while its card is dragged sideways, and still pauses once it actually leaves the screen. `'horizontal'` is the mirror for horizontal lists whose cells swipe vertically.

```tsx
<VideoView source={item.uri} autoplay="whenVisible" visibilityAxis="vertical" />
```

## One shared pool of players

Every `VideoView` draws its native player from one app-wide pool (5 by default), keyed by `playerKey` — the source uri unless you set one. That gives you Twitter-grade continuity for free:

- **Feed → post → back, no reload.** The post screen shows the same video as the feed cell, so it *is* the same player: it continues from the same frame the instant the screen appears, and hands back just as seamlessly when you pop. The cell under the pushed screen keeps rendering during the transition — nothing blanks.
- **Scroll away and back, same position.** A cell that scrolls off keeps its player idle in the pool; scroll back and it resumes where it was. When the pool is full, the least recently used player nothing is displaying is released and its playhead remembered, so even an evicted video resumes at the right second.
- **Bounded, everywhere.** `maxPlayers` is the ceiling across every list and every screen in the stack. Fullscreen, PiP and on-screen players are never evicted; the pool grows past its cap for a moment rather than blank something on screen, and settles back as soon as something leaves.

```tsx
// Same video in two places? Give both the same key (default: the source uri).
<VideoView source={post.video} playerKey={post.id} autoplay="whenVisible" />

configurePlayerPool({ maxPlayers: 10 }) // default 5
const { players, liveItems } = await getPlayerPoolStats() // for your own dashboards
```

### Memory stays flat

- **The pool is the only budget.** Off-screen cells, covered screens and popped detail views all keep their player until LRU eviction actually needs the slot; nothing is torn down on a timer.
- **Only the playing video buffers freely.** Every non-playing player is capped to a ~2s forward buffer — warm enough for an instant start, without buffering the whole feed. A 10-deep stack of video feeds costs the same as one.
- **Transient failures self-heal.** A visible video that errors (decoder pressure, flaky network) is rebuilt and retried a bounded number of times instead of staying black.
- **Posters are downsampled** to screen-width pixels at decode, so full-resolution poster URLs don't balloon memory.

## API

### Props

| Prop | Type | Default | |
|---|---|---|---|
| `source` | `string \| { uri, headers?, cache? }` | — | MP4, HLS (`.m3u8`), anything AVPlayer speaks |
| `autoplay` | `boolean \| 'whenVisible'` | `false` | `'whenVisible'` joins the election |
| `muted` | `boolean` | `false` | |
| `loop` | `boolean` | `false` | |
| `volume` | `number` | `1` | 0–1, independent of `muted` |
| `resizeMode` | `'cover' \| 'contain' \| 'stretch'` | `'cover'` | |
| `controls` | `boolean` | `false` | Native system playback controls |
| `poster` | `string` | — | Image shown until the first frame renders |
| `playerKey` | `string` | source uri | Player identity in the shared pool |
| `allowsPictureInPicture` | `boolean` | `false` | Enables PiP, incl. auto-PiP on backgrounding |
| `progressUpdateInterval` | `number` | `500` | ms between `onProgress`; `0` disables |
| `audioMixMode` | `'mixWithOthers' \| 'duckOthers' \| 'doNotMix'` | `'mixWithOthers'` | See [Audio](#audio) |
| `coordinatorGroup` | `string` | — | Separate election groups |
| `visibilityAxis` | `'both' \| 'vertical' \| 'horizontal'` | `'both'` | Which axes count toward visibility |
| `minVisibleFraction` | `number` | `0.2` | Visible fraction needed to autoplay (this view) |

### Events

| Event | Payload |
|---|---|
| `onLoad` | `{ duration, naturalSize: { width, height }, isLive }` — `duration` is `-1` for live streams |
| `onProgress` | `{ currentTime, bufferedPosition }` — `bufferedPosition` is the absolute position buffered contiguously ahead of the playhead |
| `onEnd` | — |
| `onError` | `{ code, message }` |
| `onPlaybackStateChange` | `{ status, reason }` |
| `onFullscreenChange` | `isFullscreen: boolean` |
| `onPictureInPictureChange` | `isActive: boolean` |
| `onMutedChange` | `muted: boolean` — native controls changed the mute state; mirror it into your `muted` prop |
| `onVisibilityChange` | `visibleFraction: number` — throttled, 0–1 |

`status` is `idle | loading | readyToPlay | buffering | playing | paused | ended | error`. `reason` tells you **who** caused the change — `user`, `coordinator`, or `system` — so your UI can react to coordination without fighting it.

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

### Global configuration

| Function | |
|---|---|
| `configureAutoplay({ minVisibleFraction?, hysteresis? })` | Election threshold (default 0.2) and how much more prominent a challenger must be to take over (default 0.1) |
| `configurePlayerPool({ maxPlayers? })` | Pool ceiling (default 5) |
| `getPlayerPoolStats()` | `Promise<{ players, liveItems }>` |
| `configureCache({ maxSizeBytes? })` | Disk cache budget (default 1 GB) |
| `getCacheSize()` | `Promise<number>` bytes on disk |
| `clearCache()` | Deletes all cached video data |
| `setAudioSessionManagementEnabled(enabled)` | Opt out of the library's `AVAudioSession` handling |

## Playback control

There is no `paused` prop. Playback state has three writers — your code, the user (native controls), and the visibility coordinator — and the last two live on the native side. A controlled `paused` prop would be stale the moment the coordinator elects a different video, and re-asserting it would fight the election.

Instead, playback is **uncontrolled** with a strict precedence: user intent > coordinator > autoplay policy. Drive it with `play()` / `pause()` on the ref, and mirror truth with `onPlaybackStateChange` (the `reason` field tells you who did what).

## Audio

The library never interrupts other apps' audio unless you ask it to:

- **Muted playback always mixes** — a muted feed never stops the user's music.
- **Unmuted playback** follows `audioMixMode`: `'mixWithOthers'` (default) plays alongside the user's music, `'duckOthers'` ducks it, `'doNotMix'` interrupts it (the traditional video-app behavior, opt-in).
- **One category, checked before every play.** The session is always `playback` (what PiP and audible playback need), so unmuting never switches categories or glitches audio. The *live* session state is verified right before playback starts, so another library reconfiguring the session can't make the next play interrupt anyone.
- **Session work never blocks the UI.** Audio-session calls are XPC round-trips that can stall for hundreds of milliseconds; they run on a background queue and playback starts are sequenced behind them.
- **Now Playing is never claimed.** The system controllers are configured not to register your app as the Now Playing app, which would forcibly interrupt other audio.

If your app manages its own `AVAudioSession`, opt out entirely with `setAudioSessionManagementEnabled(false)`.

## Caching

Progressive sources (MP4, MOV, M4A, …) are **disk-cached automatically**, including partially streamed ones: whatever bytes were streamed are kept as ranges on disk, so a later playback — even after an app restart — serves from cache instantly and only fetches the missing ranges. The cache is LRU-evicted against a 1 GB budget by default.

```ts
import { clearCache, configureCache, getCacheSize } from 'react-native-jet-video'

configureCache({ maxSizeBytes: 512 * 1024 * 1024 })
const bytes = await getCacheSize()
await clearCache()
```

Opt out per source with `source={{ uri, cache: false }}`. HLS streams are **not** disk-cached (AVPlayer buffers them in memory).

## Fullscreen

- `enterFullscreen()` works with or without `controls` — AVKit zooms the video out of its inline rect into a system fullscreen player (with playback controls) and back into it on exit.
- Playback rolls **through** the enter/exit animations — no freeze, no audio gap, no playhead jump at the boundary.
- Fullscreen playback survives the originating cell being recycled or unmounted (relevant inside lists).
- `controls` gives you the system inline controls, including their own fullscreen button. You don't need to flip it on for fullscreen; the fullscreen presentation always shows controls.

## Picture-in-Picture

1. Set `allowsPictureInPicture` on the view. That one flag enables the PiP methods **and** automatic PiP: backgrounding the app pops the currently playing video into a PiP window.
2. Declare the `audio` background mode for your app target:
   - **Expo:** add the config plugin to your app config, then run prebuild:

     ```json
     "plugins": [
       ["react-native-jet-video", { "supportsPictureInPicture": true }]
     ]
     ```

     Or, in a TypeScript app config, import it for typed options:

     ```ts
     import { withJetVideo } from 'react-native-jet-video/expo-plugin'

     plugins: [withJetVideo({ supportsPictureInPicture: true })]
     ```

     The plugin also accepts `supportsBackgroundPlayback` to keep audio playing when the app is backgrounded without PiP.
   - **Bare React Native:** in Xcode, enable **Background Modes → Audio, AirPlay, and Picture in Picture** (adds `UIBackgroundModes: [audio]` to Info.plist).

`startPictureInPicture()` rejects if PiP isn't possible (unsupported device, missing background mode). The iOS *simulator* only supports PiP on iPad simulators; test iPhone PiP on a device.

## Example app

`example/` is an Expo dev-client app with a screen per feature — `BasicPlayback`, `RefMethods`, `Feed` (200-item FlashList stress test with a live pool readout), `FeedToDetail`, `Stacked`, `SwipeActions`, `Fullscreen`, `PictureInPicture`, `Cache`:

```sh
bun install
cd example
bun run ios
```

## Sponsors

<p align="center">
  <a href="https://acorn.blue"><img alt="Acorn" src="https://acorn.blue/images/acorn.png" width="96"></a>
</p>

<p align="center">
  Built for and sponsored by <a href="https://acorn.blue">Acorn</a>, a Reddit client for iOS.
</p>

## License

MIT © Ali Zahid
