const fs = require('node:fs');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const { randomUUID } = require('node:crypto');
const {
  prepareRelease,
  readRelease,
  verifyMapIdentity,
} = require('./release.cjs');
const { uploadRelease } = require('./upload.cjs');
const { readConfig } = require('./config.cjs');

function validateTargets(value) {
  if (!Array.isArray(value) || value.length === 0 || value.length > 100)
    throw new Error(
      'Supply between 1 and 100 explicit native release targets.'
    );
  const seen = new Set();
  for (const target of value) {
    if (
      !target ||
      !['ios', 'android'].includes(target.platform) ||
      Object.keys(target).some(
        (key) => !['platform', 'appVersion', 'nativeBuild'].includes(key)
      ) ||
      ![target.appVersion, target.nativeBuild].every(
        (item) =>
          typeof item === 'string' &&
          /^[A-Za-z0-9][A-Za-z0-9._+-]{0,63}$/.test(item)
      )
    ) {
      throw new Error(
        'Each target must contain platform (ios/android), appVersion and nativeBuild from an eligible built binary.'
      );
    }
    const key = JSON.stringify([
      target.platform,
      target.appVersion,
      target.nativeBuild,
    ]);
    if (seen.has(key)) throw new Error('Duplicate native release target.');
    seen.add(key);
  }
  return value;
}

function exportArtifacts(directory, targets) {
  const metadata = JSON.parse(
    fs.readFileSync(path.join(directory, 'metadata.json'), 'utf8')
  );
  if (
    metadata.version !== 0 ||
    metadata.bundler !== 'metro' ||
    !metadata.fileMetadata
  )
    throw new Error(
      'Unsupported Expo export metadata. Use the advanced uploader for this export format.'
    );
  return targets.map((target) => {
    const name = metadata.fileMetadata[target.platform]?.bundle;
    if (typeof name !== 'string' || path.isAbsolute(name))
      throw new Error('The export is missing a native platform bundle.');
    const bundle = path.resolve(directory, name);
    if (!bundle.startsWith(path.resolve(directory) + path.sep))
      throw new Error('The export bundle must be inside the export directory.');
    const sourceMap = bundle + '.map';
    for (const file of [bundle, sourceMap]) {
      if (
        !fs.statSync(file).isFile() ||
        !fs.realpathSync(file).startsWith(fs.realpathSync(directory) + path.sep)
      )
        throw new Error(
          'Export artifacts must be regular files inside the export directory.'
        );
    }
    return { ...target, bundle, sourceMap };
  });
}

function exportRelease(root, output, targetsFile, options = {}) {
  if (!readConfig(root).sourceMaps.enabled)
    throw new Error(
      'Enable source maps with crumb setup before preparing an export.'
    );
  const targets = validateTargets(
    JSON.parse(fs.readFileSync(targetsFile, 'utf8'))
  );
  const directory = path.resolve(root, output);
  if (fs.existsSync(directory))
    throw new Error(
      'Choose a new export directory. Crumb does not overwrite an existing export.'
    );
  const manifest = prepareRelease(
    path.join(root, '.crumb', 'exports', randomUUID())
  );
  const expo = require.resolve('expo/bin/cli', { paths: [root] });
  const args = [expo, 'export', '--source-maps', '--output-dir', directory];
  for (const platform of new Set(targets.map((target) => target.platform)))
    args.push('--platform', platform);
  const result = spawnSync(process.execPath, args, {
    cwd: root,
    stdio: 'inherit',
    env: { ...process.env, CRUMB_RELEASE_MANIFEST: manifest },
  });
  if (result.error || result.status !== 0)
    throw new Error(
      'Expo export failed. Fix the build error before uploading or publishing an update.'
    );
  const artifacts = exportArtifacts(directory, targets);
  for (const artifact of artifacts)
    verifyMapIdentity(artifact.sourceMap, readRelease(manifest).bundleVersion);
  for (const artifact of artifacts)
    uploadRelease(
      { root, manifest, ...artifact },
      { dryRun: options.dryRun, strict: true }
    );
  console.log(
    'Crumb: export retained. Publish this exact directory with EAS --input-dir and --skip-bundler; do not rebuild it.'
  );
}

module.exports = { validateTargets, exportArtifacts, exportRelease };
