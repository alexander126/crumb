#!/usr/bin/env node
const path = require('node:path');
const fs = require('node:fs');
const { spawnSync, execFileSync } = require('node:child_process');
const { readConfig, isStrict } = require('./config.cjs');
const { prepareRelease } = require('./release.cjs');
const { uploadRelease } = require('./upload.cjs');

function plistValue(env, key) {
  const candidates = [
    env.TARGET_BUILD_DIR && env.INFOPLIST_PATH
      ? path.resolve(env.TARGET_BUILD_DIR, env.INFOPLIST_PATH)
      : undefined,
    env.INFOPLIST_FILE
      ? path.resolve(env.PROJECT_DIR, env.INFOPLIST_FILE)
      : undefined,
  ];
  for (const file of candidates) {
    if (!file || !fs.existsSync(file)) continue;
    try {
      const value = execFileSync(
        '/usr/libexec/PlistBuddy',
        ['-c', `Print :${key}`, file],
        { encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'] }
      ).trim();
      return value.replace(
        /\$\(([^)]+)\)|\$\{([^}]+)\}/g,
        (expression, a, b) => env[a || b] || expression
      );
    } catch {
      /* Try the build's other plist source. */
    }
  }
  return undefined;
}

function main() {
  const env = { ...process.env };
  const root = path.resolve(
    env.PROJECT_ROOT || path.join(env.PROJECT_DIR || process.cwd(), '..')
  );
  const config = readConfig(root);
  const enabled =
    config.sourceMaps.enabled &&
    !/Debug/i.test(env.CONFIGURATION || '') &&
    env.SKIP_BUNDLING !== '1';
  let manifest;
  if (enabled) {
    if (!env.DERIVED_FILE_DIR)
      throw new Error('Run the Crumb iOS hook from an Xcode build.');
    manifest = prepareRelease(
      path.join(env.DERIVED_FILE_DIR, 'crumb', env.TARGET_NAME || 'app')
    );
    env.CRUMB_RELEASE_MANIFEST = manifest;
    env.SOURCEMAP_FILE = path.join(path.dirname(manifest), 'bundle.map');
  }
  const [command, ...args] = process.argv.slice(2);
  if (!command)
    throw new Error('The original Xcode bundle command is required.');
  const build = spawnSync(command, args, { env, stdio: 'inherit' });
  if (build.error || build.status !== 0) {
    process.exitCode = build.status || 1;
    return;
  }
  if (!manifest) return;
  const bundle = path.join(
    env.CONFIGURATION_BUILD_DIR,
    env.UNLOCALIZED_RESOURCES_FOLDER_PATH,
    `${env.BUNDLE_NAME || 'main'}.jsbundle`
  );
  uploadRelease(
    {
      root,
      manifest,
      platform: 'ios',
      appVersion: plistValue(env, 'CFBundleShortVersionString'),
      nativeBuild: plistValue(env, 'CFBundleVersion'),
      bundle,
      sourceMap: env.SOURCEMAP_FILE,
    },
    { strict: isStrict(config) }
  );
}

if (require.main === module) {
  try {
    main();
  } catch (error) {
    console.error(`Crumb: ${error.message}`);
    process.exitCode = 1;
  }
}
module.exports = { plistValue };
