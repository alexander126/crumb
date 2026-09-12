const { configurePodfile } = require('./plugin/podfile.cjs');
const { name, version } = require('./package.json');

module.exports = function withCrumb(config) {
  // Resolve Expo from the consuming app, including non-hoisted workspaces.
  const { withPodfile, createRunOncePlugin } = require(
    require.resolve('expo/config-plugins', {
      paths: [config._internal?.projectRoot ?? process.cwd()],
    })
  );
  return createRunOncePlugin(
    (appConfig) =>
      withPodfile(appConfig, (modConfig) => {
        modConfig.modResults.contents = configurePodfile(
          modConfig.modResults.contents
        );
        return modConfig;
      }),
    name,
    version
  )(config);
};
