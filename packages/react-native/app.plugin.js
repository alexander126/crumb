const { configurePodfile } = require('./plugin/podfile.cjs');
const { name, version } = require('./package.json');
const {
  configureXcodeProject,
  configureGradle,
} = require('./plugin/build-hooks.cjs');
const { readConfig } = require('./tools/config.cjs');

module.exports = function withCrumb(config) {
  // Resolve Expo from the consuming app, including non-hoisted workspaces.
  const {
    withPodfile,
    withXcodeProject,
    withAppBuildGradle,
    createRunOncePlugin,
  } = require(
    require.resolve('expo/config-plugins', {
      paths: [config._internal?.projectRoot ?? process.cwd()],
    })
  );
  return createRunOncePlugin(
    (appConfig) => {
      appConfig = withPodfile(appConfig, (modConfig) => {
        modConfig.modResults.contents = configurePodfile(
          modConfig.modResults.contents
        );
        return modConfig;
      });
      if (
        !readConfig(config._internal?.projectRoot ?? process.cwd()).sourceMaps
          .enabled
      )
        return appConfig;
      appConfig = withXcodeProject(appConfig, (modConfig) => {
        configureXcodeProject(modConfig.modResults);
        return modConfig;
      });
      return withAppBuildGradle(appConfig, (modConfig) => {
        if (modConfig.modResults.language !== 'groovy')
          throw new Error(
            'Crumb automatic setup needs a Groovy app build file. Use the manual build-hook instructions for Kotlin DSL.'
          );
        modConfig.modResults.contents = configureGradle(
          modConfig.modResults.contents
        );
        return modConfig;
      });
    },
    name,
    version
  )(config);
};
