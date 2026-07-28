// Library source resolution is handled by the exports condition in
// metro.config.js (react-native-jet-video-source), so no babel aliasing
// is needed here.
module.exports = (api) => {
  api.cache(true)

  return {
    presets: ['babel-preset-expo'],
  }
}
