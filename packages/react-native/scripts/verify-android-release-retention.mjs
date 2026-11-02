import assert from 'node:assert/strict';
import { execFileSync, spawn } from 'node:child_process';
import { createHash } from 'node:crypto';
import { once } from 'node:events';
import {
  closeSync,
  copyFileSync,
  existsSync,
  mkdirSync,
  mkdtempSync,
  openSync,
  readFileSync,
  rmSync,
  writeFileSync,
} from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join, resolve } from 'node:path';
import { createInterface } from 'node:readline';
import { fileURLToPath } from 'node:url';
import { inspectDexDump } from './android-release-retention.mjs';

const root = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const android = join(root, 'example/android');
const sdk = process.env.ANDROID_HOME || process.env.ANDROID_SDK_ROOT;
assert.ok(sdk, 'Set ANDROID_HOME or ANDROID_SDK_ROOT.');
const dexdump = join(sdk, 'build-tools/36.0.0', 'dexdump');
assert.ok(existsSync(dexdump), 'Install Android build-tools;36.0.0.');
assert.ok(
  existsSync(join(android, 'gradlew')),
  'Run the Android Expo prebuild.'
);
const evidence = mkdtempSync(
  join(process.env.RUNNER_TEMP || tmpdir(), 'crumb-android-release-')
);
const buildLog = join(evidence, 'build.log');
console.log(`Minified Android consumer evidence: ${evidence}`);
const log = openSync(buildLog, 'w');
try {
  execFileSync(
    './gradlew',
    [
      // Public environment values are not Gradle bundle inputs.
      ':app:createBundleReleaseJsAndAssets',
      '--rerun',
      ':app:assembleRelease',
      '-Pandroid.enableMinifyInReleaseBuilds=true',
      '-PreactNativeArchitectures=arm64-v8a',
      '-Dorg.gradle.jvmargs=-Xmx4g',
      '--console=plain',
      ...process.argv.slice(2),
    ],
    {
      cwd: android,
      stdio: ['ignore', log, log],
      env: {
        ...process.env,
        EXPO_NO_DOTENV: '1',
        EXPO_PUBLIC_CRUMB_PROJECT_KEY: 'synthetic-release-retention-key',
        EXPO_PUBLIC_CRUMB_INGESTION_URL: '',
        EXPO_PUBLIC_CRUMB_ENVIRONMENT: 'release-retention-test',
        EXPO_PUBLIC_CRUMB_BUNDLE_VERSION: '',
        EXPO_PUBLIC_CRUMB_NAVIGATION: '',
        CRUMB_SOURCE_MAP_TOKEN: '',
        CRUMB_SOURCE_MAP_DRY_RUN: '1',
        CRUMB_SOURCE_MAP_STRICT: '1',
      },
    }
  );
} catch (error) {
  console.error(
    readFileSync(buildLog, 'utf8').split('\n').slice(-60).join('\n')
  );
  throw error;
} finally {
  closeSync(log);
}

const mapping = join(android, 'app/build/outputs/mapping/release');
assert.ok(
  /^> Task :app:minifyReleaseWithR8(?: UP-TO-DATE| FROM-CACHE)?\r?$/m.test(
    readFileSync(buildLog, 'utf8')
  ),
  'The consumer build must run the R8 minification task.'
);
const rules = readFileSync(join(mapping, 'configuration.txt'), 'utf8');
assert.ok(!/^\s*-dont(?:shrink|obfuscate)\b/m.test(rules));
assert.ok(readFileSync(join(mapping, 'mapping.txt'), 'utf8').length > 0);
copyFileSync(
  join(mapping, 'configuration.txt'),
  join(evidence, 'configuration.txt')
);
const apk = join(evidence, 'app-release.apk');
copyFileSync(
  join(android, 'app/build/outputs/apk/release/app-release.apk'),
  apk
);
const hashes = {};
for (const [name, path] of Object.entries({
  apk,
  rules: join(mapping, 'configuration.txt'),
  implementation: join(
    root,
    'android/src/main/java/com/margelo/nitro/crumbsdk/reactnative/CrumbReactNative.kt'
  ),
})) {
  hashes[name] = createHash('sha256').update(readFileSync(path)).digest('hex');
}
writeFileSync(join(evidence, 'inputs.json'), JSON.stringify(hashes, null, 2));
const dexFiles = execFileSync('unzip', ['-Z1', apk], { encoding: 'utf8' })
  .split('\n')
  .filter((name) => /^classes\d*\.dex$/.test(name));
assert.ok(dexFiles.length > 0, 'The minified APK must contain DEX.');
const descriptor = 'Lcom/margelo/nitro/crumbsdk/reactnative/CrumbReactNative;';
let classFound = false;
let defaultConstructorFound = false;
const extracted = join(evidence, 'dex');
mkdirSync(extracted);
try {
  for (const dexFile of dexFiles) {
    const path = join(extracted, dexFile);
    const output = openSync(path, 'w');
    try {
      execFileSync('unzip', ['-p', apk, dexFile], {
        stdio: ['ignore', output, 'pipe'],
      });
    } finally {
      closeSync(output);
    }
    const dump = spawn(dexdump, [path]);
    const completed = once(dump, 'close');
    let stderr = '';
    dump.stderr.on('data', (chunk) => {
      stderr = (stderr + chunk).slice(-4000);
    });
    const result = await inspectDexDump(
      createInterface({ input: dump.stdout, crlfDelay: Infinity }),
      descriptor
    );
    const [code] = await completed;
    assert.equal(code, 0, stderr);
    if (result.classFound) classFound = true;
    if (result.defaultConstructorFound) defaultConstructorFound = true;
  }
} finally {
  rmSync(extracted, { recursive: true, force: true });
}
assert.ok(classFound, `R8 removed or renamed the JNI class ${descriptor}`);
assert.ok(defaultConstructorFound, 'R8 removed the declared public <init>()V.');
console.log(`PASS minified APK defines ${descriptor} with public <init>()V`);
