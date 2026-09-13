const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const os = require('node:os');
const { test } = require('node:test');
const { prepareRelease, readRelease } = require('../../tools/release.cjs');
const { uploadRelease, retryUpload } = require('../../tools/upload.cjs');
const {
  exportArtifacts,
  validateTargets,
} = require('../../tools/expo-export.cjs');

function fixture(t) {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'crumb-build-test-'));
  t.after(() => fs.rmSync(root, { recursive: true, force: true }));
  fs.writeFileSync(
    path.join(root, 'crumb.config.json'),
    JSON.stringify({
      version: 1,
      sourceMaps: { enabled: true, uploadUrl: 'https://example.invalid' },
    })
  );
  const manifest = prepareRelease(path.join(root, 'build'));
  const bundle = path.join(root, 'bundle');
  const sourceMap = path.join(root, 'bundle.map');
  fs.writeFileSync(bundle, 'throw Error("synthetic")');
  fs.writeFileSync(
    sourceMap,
    JSON.stringify({
      version: 3,
      sources: ['crumb-release.js'],
      sourcesContent: [fs.readFileSync(readRelease(manifest).polyfill, 'utf8')],
      names: [],
      mappings: 'AAAA',
    })
  );
  return {
    root,
    manifest,
    bundle,
    sourceMap,
    platform: 'ios',
    appVersion: '1.0',
    nativeBuild: '1',
  };
}

test('the included uploader validates both platforms and retains immutable retry artifacts', (t) => {
  const input = fixture(t);
  for (const platform of ['ios', 'android']) {
    assert.equal(
      uploadRelease({ ...input, platform }, { dryRun: true, strict: true })
        .status,
      'dry_run'
    );
  }
  const archive = path.join(
    path.dirname(input.manifest),
    'retained',
    readRelease(input.manifest).bundleVersion,
    'ios'
  );
  const retained = JSON.parse(
    fs.readFileSync(path.join(archive, 'upload-ios-1.0-1.json'))
  );
  fs.writeFileSync(input.bundle, 'new build');
  prepareRelease(path.dirname(input.manifest));
  assert.equal(
    uploadRelease(retained, { dryRun: true, strict: true, retained: true })
      .status,
    'dry_run'
  );
  fs.writeFileSync(retained.bundle, 'modified retained bytes');
  assert.throws(
    () => retryUpload(path.join(archive, 'upload-ios-1.0-1.json')),
    /Retained artifacts have changed/
  );
});

test('incorrect build maps warn by default and fail strict builds before contacting an upload service', (t) => {
  const input = fixture(t);
  prepareRelease(path.dirname(input.manifest));
  assert.equal(uploadRelease(input).status, 'unavailable');
  assert.throws(
    () => uploadRelease(input, { strict: true }),
    /does not contain this build/
  );
});

test('disabled uploads do not need files or credentials', (t) => {
  const input = fixture(t);
  fs.writeFileSync(
    path.join(input.root, 'crumb.config.json'),
    JSON.stringify({ version: 1, sourceMaps: { enabled: false } })
  );
  fs.unlinkSync(input.bundle);
  assert.equal(uploadRelease(input).status, 'disabled');
});

test('a missing credential warns, retains retry files, and fails strict mode without network access', (t) => {
  const input = fixture(t);
  const previous = process.env.CRUMB_SOURCE_MAP_TOKEN;
  delete process.env.CRUMB_SOURCE_MAP_TOKEN;
  t.after(() => {
    if (previous !== undefined) process.env.CRUMB_SOURCE_MAP_TOKEN = previous;
  });
  assert.equal(uploadRelease(input).status, 'unavailable');
  assert.throws(
    () => uploadRelease(input, { strict: true }),
    /retry --receipt/
  );
  const archive = path.join(
    path.dirname(input.manifest),
    'retained',
    readRelease(input.manifest).bundleVersion,
    'ios'
  );
  assert.ok(fs.existsSync(path.join(archive, 'upload-ios-1.0-1.json')));
});

test('Expo artifacts come from the export manifest and explicit native targets', (t) => {
  const input = fixture(t);
  fs.writeFileSync(
    path.join(input.root, 'metadata.json'),
    JSON.stringify({
      version: 0,
      bundler: 'metro',
      fileMetadata: { ios: { bundle: 'bundle' } },
    })
  );
  const targets = validateTargets([
    { platform: 'ios', appVersion: '1.0', nativeBuild: '1' },
    { platform: 'ios', appVersion: '1.0', nativeBuild: '2' },
  ]);
  const results = exportArtifacts(input.root, targets);
  assert.equal(results.length, 2);
  assert.equal(results[0].bundle, input.bundle);
  assert.equal(results[1].nativeBuild, '2');
  assert.throws(() => validateTargets([...targets, targets[0]]), /Duplicate/);
  fs.writeFileSync(
    path.join(input.root, 'metadata.json'),
    JSON.stringify({
      version: 0,
      bundler: 'metro',
      fileMetadata: { ios: { bundle: '../outside' } },
    })
  );
  assert.throws(
    () => exportArtifacts(input.root, targets),
    /inside the export/
  );
});
