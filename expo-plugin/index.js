const { createRunOncePlugin, withInfoPlist } = require('expo/config-plugins')

const pkg = require('../package.json')

const appPlugin = createRunOncePlugin(
  (
    config,
    { supportsPictureInPicture = false, supportsBackgroundPlayback = false } = {},
  ) =>
    withInfoPlist(config, (config) => {
      if (supportsPictureInPicture || supportsBackgroundPlayback) {
        const modes = config.modResults.UIBackgroundModes ?? []

        if (!modes.includes('audio')) {
          config.modResults.UIBackgroundModes = [...modes, 'audio']
        }
      }

      return config
    }),
  pkg.name,
  pkg.version,
)

const withJetVideo = (options) => (config) => appPlugin(config, options)

module.exports = withJetVideo
module.exports.withJetVideo = withJetVideo
module.exports.default = withJetVideo
module.exports.appPlugin = appPlugin
