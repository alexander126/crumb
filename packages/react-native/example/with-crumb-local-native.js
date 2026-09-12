const { withSettingsGradle } = require('@expo/config-plugins');

const LOCAL_NATIVE_MARKER = 'crumb-local-native';

module.exports = function withCrumbLocalNative(config) {
  config = withSettingsGradle(config, (modConfig) => {
    if (modConfig.modResults.contents.includes(LOCAL_NATIVE_MARKER)) {
      return modConfig;
    }

    modConfig.modResults.contents += `

// ${LOCAL_NATIVE_MARKER}: use the native SDK sources from this checkout.
includeBuild('../../../android') {
  dependencySubstitution {
    substitute module('com.crumbsdk:crumb-core') using project(':crumb-core')
    substitute module('com.crumbsdk:crumb-ui') using project(':crumb-ui')
  }
}
`;
    return modConfig;
  });

  return config;
};
