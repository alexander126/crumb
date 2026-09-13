const fs = require('node:fs');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const { readConfig, isStrict } = require('./config.cjs');
const { readRelease, hashFile, verifyMapIdentity } = require('./release.cjs');

function uploaderPath() {
  return path.join(
    path.dirname(require.resolve('@crumbsdk/source-maps/package.json')),
    'dist/cli.js'
  );
}

function uploadRelease(
  { root, manifest, platform, appVersion, nativeBuild, bundle, sourceMap },
  options = {}
) {
  const config = readConfig(root);
  if (!config.sourceMaps.enabled) return { status: 'disabled' };
  const dryRun = options.dryRun || process.env.CRUMB_SOURCE_MAP_DRY_RUN === '1';
  try {
    const release = readRelease(manifest);
    verifyMapIdentity(sourceMap, release.bundleVersion);
    for (const value of [appVersion, nativeBuild]) {
      if (
        typeof value !== 'string' ||
        !/^[A-Za-z0-9][A-Za-z0-9._+-]{0,63}$/.test(value)
      ) {
        throw new Error(
          'The final native version/build could not be determined. Use the advanced uploader with the exact built release.'
        );
      }
    }
    if (!['ios', 'android'].includes(platform))
      throw new Error('The release platform must be ios or android.');
    const archive = options.retained
      ? path.dirname(manifest)
      : path.join(
          path.dirname(manifest),
          'retained',
          release.bundleVersion,
          platform
        );
    fs.mkdirSync(archive, { recursive: true });
    function retain(source, name) {
      const destination = path.join(archive, name);
      if (fs.existsSync(destination)) {
        if (hashFile(source) !== hashFile(destination))
          throw new Error(
            'Retained release artifacts conflict with this build. Use a new release identity.'
          );
      } else fs.copyFileSync(source, destination, fs.constants.COPYFILE_EXCL);
      return destination;
    }
    bundle = retain(bundle, 'bundle');
    sourceMap = retain(sourceMap, 'bundle.map');
    manifest = retain(manifest, 'release.json');
    const retained = {
      root,
      manifest,
      platform,
      appVersion,
      nativeBuild,
      bundle,
      sourceMap,
      bundleSha256: hashFile(bundle),
      sourceMapSha256: hashFile(sourceMap),
    };
    const receipt = path.join(
      path.dirname(manifest),
      `upload-${platform}-${appVersion}-${nativeBuild}.json`
    );
    fs.writeFileSync(receipt, JSON.stringify(retained, null, 2));
    const args = [
      uploaderPath(),
      'upload',
      '--platform',
      platform,
      '--app-version',
      appVersion,
      '--native-build',
      nativeBuild,
      '--bundle-version',
      release.bundleVersion,
      '--bundle',
      bundle,
      '--source-map',
      sourceMap,
      '--expected-bundle-sha256',
      retained.bundleSha256,
      '--expected-source-map-sha256',
      retained.sourceMapSha256,
      '--url',
      config.sourceMaps.uploadUrl,
    ];
    if (dryRun) args.push('--dry-run');
    const result = spawnSync(process.execPath, args, {
      encoding: 'utf8',
      timeout: 240000,
    });
    if (result.error || result.status !== 0) {
      throw new Error(
        `Source maps were not uploaded. Check CRUMB_SOURCE_MAP_TOKEN and the upload origin, then retry with crumb retry --receipt ${JSON.stringify(receipt)}.`
      );
    }
    const output = JSON.parse(result.stdout);
    if (output.status !== (dryRun ? 'dry_run' : 'verified'))
      throw new Error(
        'The uploader did not confirm the artifacts. Run crumb doctor and retry.'
      );
    console.log(
      dryRun
        ? 'Crumb: release artifacts validated locally; no upload performed.'
        : 'Crumb: source-map artifacts uploaded and verified. Confirm a test crash in the dashboard.'
    );
    return output;
  } catch (error) {
    if (options.strict || isStrict(config)) throw error;
    console.warn(`Crumb warning: ${error.message}`);
    return { status: 'unavailable' };
  }
}

function retryUpload(receipt) {
  const retained = JSON.parse(fs.readFileSync(receipt, 'utf8'));
  if (
    hashFile(retained.bundle) !== retained.bundleSha256 ||
    hashFile(retained.sourceMap) !== retained.sourceMapSha256
  ) {
    throw new Error(
      'Retained artifacts have changed. Restore the exact original files; do not upload a rebuilt bundle under the old identity.'
    );
  }
  return uploadRelease(retained, { strict: true, retained: true });
}

module.exports = { uploadRelease, retryUpload };
