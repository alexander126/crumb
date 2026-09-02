const { withPodfile, withSettingsGradle } = require('@expo/config-plugins');

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

  return withPodfile(config, (modConfig) => {
    if (modConfig.modResults.contents.includes(LOCAL_NATIVE_MARKER)) {
      return modConfig;
    }

    const marker = '  use_expo_modules!\n';
    if (!modConfig.modResults.contents.includes(marker)) {
      throw new Error(
        'Crumb local-native plugin could not find the Expo Podfile target'
      );
    }

    const localPods = `
  # ${LOCAL_NATIVE_MARKER}: use the native SDK sources from this checkout.
  pod 'CrumbSDKCore', :path => File.expand_path('../../../../', __dir__)
  pod 'CrumbSDKUI', :path => File.expand_path('../../../../', __dir__)
`;
    modConfig.modResults.contents = modConfig.modResults.contents.replace(
      marker,
      `${marker}${localPods}`
    );
    return modConfig;
  });
};
