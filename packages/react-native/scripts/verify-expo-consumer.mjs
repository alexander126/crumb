import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import {
  mkdirSync,
  mkdtempSync,
  readFileSync,
  readdirSync,
  rmSync,
  writeFileSync,
} from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const temporary = mkdtempSync(join(tmpdir(), 'crumb-expo-consumer-'));
const env = {
  ...process.env,
  CI: '1',
  COCOAPODS_DISABLE_STATS: 'true',
  npm_config_cache: join(temporary, 'npm-cache'),
};
function run(command, args, cwd) {
  execFileSync(command, args, { cwd, env, stdio: 'inherit' });
}
try {
  run(process.execPath, ['scripts/prepare-ios.mjs'], root);
  execFileSync(
    'npm',
    ['pack', '--ignore-scripts', '--pack-destination', temporary, '--json'],
    { cwd: root, env, stdio: 'pipe' }
  );
  const archive = readdirSync(temporary).find((name) => name.endsWith('.tgz'));
  assert.ok(archive);
  const consumer = join(temporary, 'consumer');
  mkdirSync(consumer);
  const example = JSON.parse(
    readFileSync(join(root, 'example/package.json'), 'utf8')
  );
  const dependencies = Object.fromEntries(
    [
      'expo',
      'expo-build-properties',
      'react',
      'react-native',
      'react-native-nitro-modules',
    ].map((name) => [name, example.dependencies[name]])
  );
  dependencies['@crumbsdk/react-native'] = `file:${join(temporary, archive)}`;
  writeFileSync(
    join(consumer, 'package.json'),
    JSON.stringify(
      {
        name: 'crumb-packed-consumer',
        version: '1.0.0',
        private: true,
        main: 'index.js',
        dependencies,
      },
      null,
      2
    )
  );
  writeFileSync(
    join(consumer, 'index.js'),
    "import { registerRootComponent } from 'expo';\nimport { Text } from 'react-native';\nimport Crumb from '@crumbsdk/react-native';\nfunction App() { return <Text onPress={() => Crumb.show()}>Crumb packaging check</Text>; }\nregisterRootComponent(App);\n"
  );
  writeFileSync(
    join(consumer, 'app.json'),
    JSON.stringify(
      {
        expo: {
          name: 'CrumbPackedConsumer',
          slug: 'crumb-packed-consumer',
          ios: { bundleIdentifier: 'com.crumbsdk.packaging.test' },
          plugins: [
            '@crumbsdk/react-native',
            ['expo-build-properties', { ios: { deploymentTarget: '15.1' } }],
          ],
        },
      },
      null,
      2
    )
  );
  run('npm', ['install', '--no-audit', '--no-fund'], consumer);
  if (!process.argv.includes('--bare-only')) {
    run(
      'npx',
      ['expo', 'prebuild', '--platform', 'ios', '--clean', '--no-install'],
      consumer
    );
    const podfile = readFileSync(join(consumer, 'ios/Podfile'), 'utf8');
    run(
      'npx',
      ['expo', 'prebuild', '--platform', 'ios', '--clean', '--no-install'],
      consumer
    );
    assert.equal(
      readFileSync(join(consumer, 'ios/Podfile'), 'utf8'),
      podfile,
      'Expo clean prebuild must be repeatable'
    );
    run('pod', ['install'], join(consumer, 'ios'));
    const lock = readFileSync(join(consumer, 'ios/Podfile.lock'), 'utf8');
    const specRepos = lock.split('SPEC REPOS:')[1]?.split('\n\n')[0] ?? '';
    assert.ok(
      !/CrumbSDK|PLCrashReporter/.test(specRepos),
      'Crumb-native dependencies must resolve from npm'
    );
    assert.ok(lock.includes('node_modules/@crumbsdk/react-native/native/ios'));
    run(
      'xcodebuild',
      [
        '-workspace',
        'ios/CrumbPackedConsumer.xcworkspace',
        '-scheme',
        'CrumbPackedConsumer',
        '-configuration',
        'Debug',
        '-sdk',
        'iphonesimulator',
        '-destination',
        'generic/platform=iOS Simulator',
        '-derivedDataPath',
        join(temporary, 'build'),
        'ARCHS=arm64',
        'ONLY_ACTIVE_ARCH=YES',
        'CODE_SIGNING_ALLOWED=NO',
        'build',
        '-quiet',
      ],
      consumer
    );
    console.log(
      'Standalone packed Expo iOS consumer built; clean prebuild is idempotent and Crumb dependencies are local.'
    );
  }
  // Exercise the same package from a conventional React Native Podfile too,
  // without Expo's Podfile plugin or use_expo_modules!.
  const bare = join(consumer, 'bare-ios');
  mkdirSync(bare);
  run(
    'ruby',
    [
      '-rxcodeproj',
      '-e',
      "project = Xcodeproj::Project.new('BareConsumer.xcodeproj'); project.new_target(:application, 'BareConsumer', :ios, '15.1'); project.save",
    ],
    bare
  );
  writeFileSync(
    join(bare, 'Podfile'),
    `require_relative '../node_modules/react-native/scripts/react_native_pods'
require_relative '../node_modules/@crumbsdk/react-native/scripts/ios'
ENV['RCT_USE_PREBUILT_RNCORE'] = '1'
ENV['RCT_USE_RN_DEP'] = '1'
project 'BareConsumer.xcodeproj'
platform :ios, '15.1'
prepare_react_native_project!
target 'BareConsumer' do
  crumb_native_pods!
  pod 'CrumbReactNative', :path => '../node_modules/@crumbsdk/react-native'
  pod 'NitroModules', :path => '../node_modules/react-native-nitro-modules'
  use_react_native!(:path => '../node_modules/react-native', :app_path => File.expand_path('..', __dir__))
  post_install do |installer|
    react_native_post_install(installer, '../node_modules/react-native', :mac_catalyst_enabled => false)
  end
end
`
  );
  run('pod', ['install'], bare);
  const bareLock = readFileSync(join(bare, 'Podfile.lock'), 'utf8');
  assert.ok(
    !/CrumbSDK|PLCrashReporter/.test(
      bareLock.split('SPEC REPOS:')[1]?.split('\n\n')[0] ?? ''
    )
  );
  run(
    'xcodebuild',
    [
      '-project',
      'Pods/Pods.xcodeproj',
      '-scheme',
      'CrumbReactNative',
      '-configuration',
      'Debug',
      '-sdk',
      'iphonesimulator',
      '-destination',
      'generic/platform=iOS Simulator',
      '-derivedDataPath',
      join(temporary, 'bare-build'),
      'ARCHS=arm64',
      'ONLY_ACTIVE_ARCH=YES',
      'CODE_SIGNING_ALLOWED=NO',
      'build',
      '-quiet',
    ],
    bare
  );
  console.log(
    'Bare React Native Podfile helper installed the packed dependencies and built the adapter.'
  );
} finally {
  rmSync(temporary, { recursive: true, force: true });
}
