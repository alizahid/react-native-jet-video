# Changelog

## Unreleased

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
