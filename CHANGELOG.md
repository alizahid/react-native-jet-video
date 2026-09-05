# Changelog

## Unreleased

- Memory/CPU: only visible videos hold a live player item. Mounted-but-offscreen cells (FlashList render-ahead, ScrollView content, feeds under a page sheet) release their whole player stack and show the poster; visible `whenVisible` videos beyond the playing one are capped at a handful. Posters decode at screen-width instead of screen-height pixels. The disk cache now uses one shared URL session (no per-video session, URLCache disabled), reads metadata lazily off the main thread, and throttles metadata writes and eviction scans.
- Audio: fixed muted playback stopping the user's music at app launch — the `ambient` category was requested with the movie-playback mode, which it rejects, leaving the default `soloAmbient` for AVPlayer to activate. The session is now always `playback` + mixing (verified against the live session state before every play, so other libraries can't leave a non-mixing category behind), the PiP controller is created only after the session is configured, and unmuting no longer switches categories mid-playback.
- Election: a pause made on AVKit's controls (fullscreen or embedded) is now a user pause and is no longer force-resumed; playback resumes after an audio interruption (call, Siri) ends; videos under a covering modal presentation (page/form sheet, full screen) count as invisible and pause; loops no longer flicker through a paused state at the boundary.
- Fullscreen: AVKit's implicit pauses during the enter/exit animations are reverted synchronously (before the audio pipeline drains) instead of a frame later, and the enter transition waits for the fullscreen controller to have a frame — no black flash, freeze, or audio dip on either side.

- Fixed flicker when exiting fullscreen: the inline layer is blanked while
  AVKit owns rendering (no double image behind the shrinking video),
  fullscreen chrome is dropped as the exit starts (no controls flash at the
  inline rect), and the embedded view is removed only once the inline layer
  has a frame ready (no black flash on handback).

- **Breaking:** `onProgress` now reports `bufferedPosition` — the absolute
  position up to which media is buffered contiguously from the playhead
  (what scrubbers draw) — replacing `bufferedDuration`, which was the
  seconds-ahead runway and shrank as playback consumed the buffer.

- Fullscreen now uses AVKit's native zoom transition — fullscreen expands out
  of the `VideoView` and collapses back into it (like expo-video) instead of
  sliding up as a modal.
- Playback resumes after exiting fullscreen when the video was playing;
  AVKit's implicit pause during dismissal is undone. A deliberate pause made
  in fullscreen sticks, and registers as a user-pause with the autoplay
  coordinator so it isn't force-resumed.

- Autoplay election: when candidates are comparably visible (within
  hysteresis), the video closest to the screen center now wins — fixes
  scrolling back up not handing playback to the previous video, and makes
  handoff symmetric in both scroll directions.
- Fixed cache corruption when `clearCache()` ran during active playback:
  active entries now reset their in-memory state, and stale metadata ranges
  that can't be backed by the data file are dropped on load.
- **Breaking:** removed `autoEnterPiPOnBackground`. `allowsPictureInPicture`
  alone now also auto-enters PiP with the currently playing video when the app
  is backgrounded.
- Transparent disk caching for progressive sources (MP4/MOV/M4A…): byte-range
  cache with write-through streaming, so partially streamed videos resume from
  disk across playbacks and app launches. LRU eviction (1 GB default).
- New APIs: `clearCache()`, `getCacheSize()`, `configureCache({ maxSizeBytes })`,
  and a per-source opt-out (`source={{ uri, cache: false }}`).
- HLS is not disk-cached (documented).

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
