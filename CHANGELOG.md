# Changelog

## 1.0.0

The first stable release. Everything since 0.1.0, curated:

### Rendering and fullscreen

- The inline renderer is a single `AVPlayerViewController` per view (the expo-video approach), chrome hidden unless `controls`. Each player draws to exactly one layer, `controls` toggles chrome instead of rebuilding the surface, and a chromeless video lets touches through to whatever wraps it (a Pressable).
- Fullscreen uses AVKit's native zoom — it expands out of the `VideoView` and collapses back into it — starting from the renderer already on screen, so nothing is attached to or detached from the player around the animation. Playback rolls through both transitions: AVKit's implicit pauses are skipped (`canPausePlaybackWhenExitingFullScreen`) and any that slip through are reverted synchronously, fullscreen chrome is dropped as the exit starts, and the audio session is activated before the zoom so an unmute in `onFullscreenChange` doesn't reconfigure audio mid-animation.
- A deliberate pause made in fullscreen (or on the inline controls) sticks and registers as a user pause with the coordinator, so it isn't force-resumed. Fullscreen survives the originating cell being recycled.
- `enterFullscreen()` rejects if AVKit's transition selector is ever unavailable (no modal fallback).

### Player pool

- Native players live in one app-wide pool (5 by default, `configurePlayerPool({ maxPlayers })`), keyed by the new `playerKey` prop (default: the source uri). Views showing the same video share one player: opening a post from a feed continues from the same frame with no reload, and popping back hands it back seamlessly — the covered cell keeps rendering during the transition, and a screen showing a video already live beneath it takes the player the moment it joins the window.
- Scrolled-away cells and covered screens keep their player idle for instant resume; nothing is torn down on a timer. When the pool is full, the least recently used player nothing is displaying is released and its playhead remembered. Fullscreen, PiP and on-screen players are never evicted.
- Only the playing video buffers freely; every other player is capped to a ~2s forward buffer. Ready players preroll so an elected video starts on the next frame.
- `getPlayerPoolStats()` reports live pool usage. Fabric's unmount releases the view's player deterministically.

### Visibility election

- Eligibility threshold is 20% (was 50%), overridable per view with the new `minVisibleFraction` prop. Visibility is measured against what the layout shows of a video (an `overflow: hidden` cell's crop), and content under a transparent header or translucent tab bar doesn't count.
- Ranking is screen coverage discounted by how much of the video is cut off; comparable candidates go in reading order (topmost, or leftmost for horizontal lists), so the first video in a feed plays when the screen opens.
- New `visibilityAxis` prop (`'both' | 'vertical' | 'horizontal'`): single-axis coverage so swipe-to-action cells don't pause mid-swipe.
- Videos under a covering modal presentation (page/form sheet, full screen) count as invisible. Playback resumes after an audio interruption (call, Siri) ends. A visible video that errors is rebuilt and retried a bounded number of times. Loops don't flicker through a paused state at the boundary.

### Audio

- The session is always `playback` + mixing, verified against the live session state before every play, so muted playback never stops the user's music — at launch or later — and unmuting never switches categories mid-playback. All audio-session work runs off the main thread; playback starts are sequenced behind it. Now Playing is never claimed.
- The PiP controller is created on first play, after the session is configured (creating one per mounting cell was a launch-time hang and a background-music killer).

### Caching

- Transparent disk caching for progressive sources (MP4/MOV/M4A…): a byte-range cache with write-through streaming, so partially streamed videos resume from disk across playbacks and app launches. LRU eviction, 1 GB default. HLS is not disk-cached.
- New APIs: `clearCache()`, `getCacheSize()`, `configureCache({ maxSizeBytes })`, and a per-source opt-out (`source={{ uri, cache: false }}`).
- One shared URL session, metadata read lazily off the main thread, throttled metadata writes and eviction scans. `clearCache()` during playback no longer corrupts active entries.

### Recycling

- No native prop is optional any more. Fabric clears an optional prop with an explicit `null`, which Nitro's prop parser rejects as a fatal JS error, so a recycled cell moving from a video with a poster to one without (or dropping a handler) crashed the app. Empty string is the wire form of "unset" for `posterUri`, `playerKey` and `coordinatorGroup`; a missing callback is sent as a noop.

### Breaking changes since 0.1.0

- `onProgress` reports `bufferedPosition` (absolute position buffered contiguously ahead of the playhead, what scrubbers draw) instead of `bufferedDuration`.
- `autoEnterPiPOnBackground` is gone; `allowsPictureInPicture` alone also auto-enters PiP when the app is backgrounded.
- Peer range: `react-native-nitro-modules >= 0.36`.

## 0.1.0

Initial release (iOS).

- `<VideoView />` — single-component API; the view owns its player.
- MP4 + HLS playback via AVFoundation, with headers support.
- Visibility-based autoplay coordination (`autoplay="whenVisible"`): native
  election with hysteresis, user-intent overrides, and coordinator groups.
  Built for FlashList and any other scroll container.
- Correct behavior under list view recycling; warm-buffer policy for
  non-elected videos.
- Ref methods: `play`, `pause`, `seek` (promise), synchronous `getCurrentTime`,
  fullscreen and Picture-in-Picture controls.
- Native system controls (`controls` prop) and programmatic fullscreen that
  survives cell recycling.
- Picture-in-Picture with `autoEnterPiPOnBackground`.
- Polite audio-session management with `audioMixMode`
  (default `mixWithOthers`) — never interrupts other apps' audio by default.
- Poster images, loop, volume, resize modes, and a full playback event surface
  with cause attribution (`user` / `coordinator` / `system`).
