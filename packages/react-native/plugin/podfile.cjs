const marker = '# crumb-bundled-ios';
const block = `${marker}
  require File.join(File.dirname(\`node --print "require.resolve('@crumbsdk/react-native/package.json')"\`.strip), 'scripts', 'ios')
  crumb_native_pods!`;

function configurePodfile(contents) {
  if (contents.includes(marker)) return contents;
  if (/pod\s+['"](?:CrumbSDK(?:Core|UI)?|PLCrashReporter)['"]/.test(contents)) {
    throw new Error(
      'Remove manual Crumb/PLCrashReporter pod entries before enabling the Crumb Expo plugin. It registers the bundled dependencies.'
    );
  }
  const target = /^(\s*)use_expo_modules!\s*$/m;
  if (!target.test(contents)) {
    throw new Error(
      'Crumb could not find use_expo_modules! in the Expo Podfile. Add crumb_native_pods! inside the app target using the bare React Native setup guide.'
    );
  }
  return contents.replace(target, (match) => `${match}\n  ${block}\n`);
}
module.exports = { configurePodfile };
