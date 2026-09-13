const fs = require('node:fs');
const path = require('node:path');
const { readConfig, validateOrigin } = require('./config.cjs');
const {
  configureXcodeProject,
  configureGradle,
} = require('../plugin/build-hooks.cjs');

const metroMarker = '// crumb-metro';

function setupPlan(root, { sourceMaps, uploadUrl } = {}) {
  const pkg = JSON.parse(
    fs.readFileSync(path.join(root, 'package.json'), 'utf8')
  );
  const dependencies = { ...pkg.dependencies, ...pkg.devDependencies };
  if (!dependencies['react-native'])
    throw new Error('Run crumb setup from the React Native app directory.');
  const expo = Boolean(dependencies.expo);
  const manager = [
    'yarn.lock',
    'pnpm-lock.yaml',
    'bun.lock',
    'bun.lockb',
    'package-lock.json',
  ].find((name) => fs.existsSync(path.join(root, name)));
  const changes = [];
  const instructions = [];
  const edit = (name, content) => {
    const file = path.join(root, name);
    const before = fs.existsSync(file)
      ? fs.readFileSync(file, 'utf8')
      : undefined;
    if (before !== content) changes.push({ name, file, before, content });
  };
  const config = readConfig(root);
  if (sourceMaps !== undefined) config.sourceMaps.enabled = sourceMaps;
  if (config.sourceMaps.enabled)
    config.sourceMaps.uploadUrl = validateOrigin(
      uploadUrl || config.sourceMaps.uploadUrl
    );
  edit('crumb.config.json', JSON.stringify(config, null, 2) + '\n');
  if (!dependencies['react-native-nitro-modules']) {
    const version =
      require('../package.json').peerDependencies['react-native-nitro-modules'];
    const add =
      manager === 'yarn.lock'
        ? 'yarn add'
        : manager === 'pnpm-lock.yaml'
          ? 'pnpm add'
          : manager?.startsWith('bun')
            ? 'bun add'
            : 'npm install';
    instructions.push(
      `Install the required native peer: ${add} react-native-nitro-modules@${JSON.stringify(version)}`
    );
  }
  if (expo) {
    if (
      ['app.config.ts', 'app.config.js', 'app.config.mjs'].some((name) =>
        fs.existsSync(path.join(root, name))
      )
    ) {
      instructions.push(
        'Add @crumbsdk/react-native to plugins in your dynamic Expo config. Existing dynamic configuration was preserved.'
      );
    } else {
      const appFile = path.join(root, 'app.json');
      const app = fs.existsSync(appFile)
        ? JSON.parse(fs.readFileSync(appFile, 'utf8'))
        : { expo: {} };
      if (!app.expo)
        throw new Error(
          'app.json does not contain an Expo configuration. Add the Crumb plugin manually.'
        );
      const plugins = app.expo.plugins || [];
      if (
        !plugins.some(
          (item) =>
            (Array.isArray(item) ? item[0] : item) === '@crumbsdk/react-native'
        )
      ) {
        app.expo.plugins = [...plugins, '@crumbsdk/react-native'];
        edit('app.json', JSON.stringify(app, null, 2) + '\n');
      }
    }
    instructions.push(
      'Run your normal Expo prebuild/development build to apply native configuration. Expo Go cannot load the native SDK.'
    );
  } else {
    const podfile = path.join(root, 'ios/Podfile');
    if (fs.existsSync(podfile)) {
      let contents = fs.readFileSync(podfile, 'utf8');
      if (!contents.includes('crumb_native_pods!')) {
        if (
          /pod\s+['"](?:CrumbSDK(?:Core|UI)?|PLCrashReporter)['"]/.test(
            contents
          )
        ) {
          throw new Error(
            'Remove manual Crumb/PLCrashReporter pod declarations before using bundled native dependencies.'
          );
        }
        if (/^.*use_native_modules!.*$/m.test(contents)) {
          contents = contents.replace(
            /^.*use_native_modules!.*$/m,
            (line) =>
              `${line}\n  require File.join(File.dirname(\`node --print "require.resolve('@crumbsdk/react-native/package.json')"\`.strip), 'scripts', 'ios')\n  crumb_native_pods!`
          );
          edit('ios/Podfile', contents);
        } else
          instructions.push(
            'Register crumb_native_pods! inside your app target using the manual iOS instructions.'
          );
      }
      instructions.push(
        'Install the iOS pods using your project’s usual command.'
      );
    }
  }
  if (config.sourceMaps.enabled) {
    const ignoreFile = path.join(root, '.gitignore');
    const ignore = fs.existsSync(ignoreFile)
      ? fs.readFileSync(ignoreFile, 'utf8')
      : '';
    if (!ignore.split(/\r?\n/).includes('/.crumb/'))
      edit(
        '.gitignore',
        `${ignore}\n# Crumb local release artifacts (never commit source maps)\n/.crumb/\n`
      );
    const metroFiles = [
      'metro.config.js',
      'metro.config.cjs',
      'metro.config.mjs',
      'metro.config.ts',
    ].filter((name) => fs.existsSync(path.join(root, name)));
    if (metroFiles.length > 1)
      throw new Error(
        'Multiple Metro configurations found. Wrap the active configuration with withCrumb manually.'
      );
    const metroName =
      metroFiles[0] ||
      (pkg.type === 'module' ? 'metro.config.cjs' : 'metro.config.js');
    const before = metroFiles[0]
      ? fs.readFileSync(path.join(root, metroName), 'utf8')
      : undefined;
    if (
      before &&
      !before.includes(metroMarker) &&
      !before.includes('@crumbsdk/react-native/metro')
    ) {
      if (
        metroName.endsWith('.mjs') ||
        metroName.endsWith('.ts') ||
        (pkg.type === 'module' && metroName.endsWith('.js')) ||
        !before.includes('module.exports')
      ) {
        instructions.push(
          'Wrap your existing Metro config with withCrumb from @crumbsdk/react-native/metro. This configuration format was preserved.'
        );
      } else
        edit(
          metroName,
          `${before}\n${metroMarker}\nmodule.exports = require('@crumbsdk/react-native/metro').withCrumb(module.exports);\n`
        );
    } else if (!before) {
      edit(
        metroName,
        `const { getDefaultConfig } = require('${expo ? 'expo/metro-config' : '@react-native/metro-config'}');\n${metroMarker}\nmodule.exports = require('@crumbsdk/react-native/metro').withCrumb(getDefaultConfig(__dirname));\n`
      );
    }
    if (!expo) {
      const gradle = path.join(root, 'android/app/build.gradle');
      if (fs.existsSync(gradle))
        edit(
          'android/app/build.gradle',
          configureGradle(fs.readFileSync(gradle, 'utf8'))
        );
      else
        instructions.push(
          'Apply tools/crumb.gradle in your Android application module using the manual instructions.'
        );
      const ios = path.join(root, 'ios');
      const projects = fs.existsSync(ios)
        ? fs.readdirSync(ios).filter((name) => name.endsWith('.xcodeproj'))
        : [];
      if (projects.length === 1) {
        const name = `ios/${projects[0]}/project.pbxproj`;
        const project = require('xcode').project(path.join(root, name));
        project.parseSync();
        configureXcodeProject(project);
        // Avoid formatting unrelated project sections on repeat setup.
        if (
          !fs
            .readFileSync(path.join(root, name), 'utf8')
            .includes('crumb-release-build')
        )
          edit(name, project.writeSync());
      } else
        instructions.push(
          'Configure the app’s Xcode bundle phase using the manual instructions; no unique project was selected.'
        );
    }
    instructions.push(
      'Set CRUMB_SOURCE_MAP_TOKEN as a build secret. Never put it in this config, app initialization, or EXPO_PUBLIC_* variables.'
    );
    instructions.push(
      'Enable diagnostics.javascriptCrashCapture.enabled in Crumb.start. Remove manual release.bundleVersion when using generated build identity.'
    );
  }
  instructions.push(
    'Keep the native minimum targets at iOS 15.1 and Android API 26 or higher; retain any higher framework requirement.'
  );
  instructions.push(
    'Initialize Crumb with the SDK configuration from your dashboard, then send a test report.'
  );
  return { framework: expo ? 'Expo' : 'React Native', changes, instructions };
}

function applyPlan(plan) {
  // Check every file before changing any: a preview must not overwrite later user edits.
  for (const change of plan.changes) {
    const current = fs.existsSync(change.file)
      ? fs.readFileSync(change.file, 'utf8')
      : undefined;
    if (current !== change.before)
      throw new Error(
        `Setup stopped because ${change.name} changed after preview. Run setup again.`
      );
  }
  for (const change of plan.changes) {
    fs.mkdirSync(path.dirname(change.file), { recursive: true });
    fs.writeFileSync(change.file, change.content);
  }
}

function doctor(root) {
  const config = readConfig(root);
  const checks = [];
  const pkg = JSON.parse(
    fs.readFileSync(path.join(root, 'package.json'), 'utf8')
  );
  for (const name of ['@crumbsdk/react-native', 'react-native-nitro-modules']) {
    try {
      require.resolve(`${name}/package.json`, { paths: [root] });
      checks.push({ check: name, status: 'ready' });
    } catch {
      checks.push({
        check: name,
        status: 'missing',
        action: 'Install the dependency in this app.',
      });
    }
  }
  if (config.sourceMaps.enabled) {
    const metro = [
      'metro.config.js',
      'metro.config.cjs',
      'metro.config.mjs',
      'metro.config.ts',
    ].some((name) => {
      const file = path.join(root, name);
      return (
        fs.existsSync(file) &&
        fs.readFileSync(file, 'utf8').includes('@crumbsdk/react-native/metro')
      );
    });
    checks.push({
      check: 'Metro release integration',
      status: metro ? 'configured' : 'missing',
      action:
        'Run crumb setup or wrap your existing Metro config with withCrumb.',
    });
    checks.push({
      check: 'Upload credential in this environment',
      status: process.env.CRUMB_SOURCE_MAP_TOKEN ? 'present' : 'missing',
      action:
        'Set the build secret in the environment that runs release builds.',
    });
  }
  return {
    framework:
      pkg.dependencies?.expo || pkg.devDependencies?.expo
        ? 'Expo'
        : 'React Native',
    sourceMaps: config.sourceMaps.enabled,
    checks,
    note: 'Local checks do not confirm uploaded maps or readable crashes. Build a release and verify a test crash in the dashboard.',
  };
}

module.exports = { setupPlan, applyPlan, doctor };
