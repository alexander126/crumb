const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const os = require('node:os');
const { test } = require('node:test');
const { setupPlan, applyPlan } = require('../../tools/setup.cjs');
const { prepareRelease, readRelease } = require('../../tools/release.cjs');
const { configureXcodeProject } = require('../../plugin/build-hooks.cjs');
const { execFileSync } = require('node:child_process');

function app(t, extra = {}) {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'crumb-setup-test-'));
  t.after(() => fs.rmSync(root, { recursive: true, force: true }));
  fs.writeFileSync(
    path.join(root, 'package.json'),
    JSON.stringify({
      dependencies: { 'react-native': '0.83.10', expo: '55.0.31', ...extra },
    })
  );
  fs.writeFileSync(
    path.join(root, 'app.json'),
    JSON.stringify({
      expo: { name: 'Synthetic', plugins: ['existing-plugin'] },
    })
  );
  return root;
}

test('Expo setup preserves plugins and Metro options, and applying twice changes nothing', (t) => {
  const root = app(t);
  const original =
    'module.exports = { resolver: { assetExts: ["custom"] } };\n';
  fs.writeFileSync(path.join(root, 'metro.config.js'), original);
  const plan = setupPlan(root, {
    sourceMaps: true,
    uploadUrl: 'https://example.invalid',
  });
  assert.equal(fs.existsSync(path.join(root, 'crumb.config.json')), false);
  applyPlan(plan);
  assert.ok(
    fs
      .readFileSync(path.join(root, 'metro.config.js'), 'utf8')
      .startsWith(original)
  );
  assert.deepEqual(
    JSON.parse(fs.readFileSync(path.join(root, 'app.json'))).expo.plugins,
    ['existing-plugin', '@crumbsdk/react-native']
  );
  assert.equal(setupPlan(root).changes.length, 0);
});

test('a concurrent user edit stops the entire setup transaction', (t) => {
  const root = app(t);
  const plan = setupPlan(root, { sourceMaps: false });
  fs.writeFileSync(path.join(root, 'app.json'), 'changed by user');
  assert.throws(() => applyPlan(plan), /changed after preview/);
  assert.equal(fs.existsSync(path.join(root, 'crumb.config.json')), false);
});

test('dynamic Expo and ESM Metro configurations receive a manual path without replacement', (t) => {
  const root = app(t);
  fs.writeFileSync(
    path.join(root, 'app.config.ts'),
    'export default () => ({})'
  );
  fs.writeFileSync(path.join(root, 'metro.config.mjs'), 'export default {}');
  const plan = setupPlan(root, {
    sourceMaps: true,
    uploadUrl: 'https://example.invalid',
  });
  assert.ok(plan.instructions.some((value) => value.includes('dynamic Expo')));
  assert.ok(plan.instructions.some((value) => value.includes('withCrumb')));
  assert.deepEqual(
    plan.changes.map((change) => change.name),
    ['crumb.config.json', '.gitignore']
  );
});

test('upload configuration rejects credential-bearing destinations and secret fields', (t) => {
  const root = app(t);
  for (const origin of [
    'http://example.invalid',
    'https://secret@example.invalid',
    'https://example.invalid?token=secret',
  ]) {
    assert.throws(
      () => setupPlan(root, { sourceMaps: true, uploadUrl: origin }),
      /HTTPS/
    );
  }
  fs.writeFileSync(
    path.join(root, 'crumb.config.json'),
    JSON.stringify({
      version: 1,
      sourceMaps: { enabled: false, token: 'synthetic' },
    })
  );
  assert.throws(() => setupPlan(root), /credentials/);
  for (const invalid of ['null', '[]', '{"secret":"DO_NOT_ECHO"']) {
    fs.writeFileSync(path.join(root, 'crumb.config.json'), invalid);
    assert.throws(
      () => setupPlan(root),
      (error) => {
        assert.ok(!error.message.includes('DO_NOT_ECHO'));
        return true;
      }
    );
  }
});

test('turning source maps off leaves Android bundling free of generated release identity', (t) => {
  const root = app(t);
  applyPlan(setupPlan(root, { sourceMaps: false }));
  const manifest = prepareRelease(path.join(root, 'build'));
  const output = execFileSync(
    process.execPath,
    [
      path.resolve(__dirname, '../../tools/node.cjs'),
      manifest,
      '-e',
      'process.stdout.write(process.env.CRUMB_RELEASE_MANIFEST || "disabled")',
    ],
    { cwd: root, encoding: 'utf8' }
  );
  assert.equal(output, 'disabled');
});

test('Metro identity is included before app startup and preserves existing serializers', async (t) => {
  const root = app(t);
  const manifest = prepareRelease(path.join(root, 'build'));
  const previous = process.env.CRUMB_RELEASE_MANIFEST;
  t.after(() => {
    if (previous === undefined) delete process.env.CRUMB_RELEASE_MANIFEST;
    else process.env.CRUMB_RELEASE_MANIFEST = previous;
  });
  process.env.CRUMB_RELEASE_MANIFEST = manifest;
  const { withCrumb } = require('../../metro.cjs');
  const serializer = () => 'existing';
  const result = await withCrumb(
    Promise.resolve({
      serializer: {
        customSerializer: serializer,
        getPolyfills: () => ['existing.js'],
      },
    })
  );
  assert.equal(result.serializer.customSerializer, serializer);
  assert.deepEqual(result.serializer.getPolyfills({ platform: 'ios' }), [
    'existing.js',
    readRelease(manifest).polyfill,
  ]);
  const context = {};
  require('node:vm').runInNewContext(
    fs.readFileSync(readRelease(manifest).polyfill, 'utf8'),
    context
  );
  assert.equal(
    context.__CRUMB_BUNDLE_VERSION__,
    readRelease(manifest).bundleVersion
  );
});

test('Xcode wrapper preserves original phase and is idempotent with shell-sensitive contents', () => {
  const original =
    'echo "custom setting"\n/bin/sh "$REACT_NATIVE_PATH/scripts/react-native-xcode.sh"\n';
  const phases = { phase: { shellScript: JSON.stringify(original) } };
  const project = {
    hash: { project: { objects: { PBXShellScriptBuildPhase: phases } } },
  };
  configureXcodeProject(project);
  const first = phases.phase.shellScript;
  assert.ok(JSON.parse(first).includes(original));
  configureXcodeProject(project);
  assert.equal(phases.phase.shellScript, first);
});
