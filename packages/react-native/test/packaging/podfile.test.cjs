const assert = require('node:assert/strict');
const { test } = require('node:test');
const { configurePodfile } = require('../../plugin/podfile.cjs');

test('Expo registration stays inside the target and is idempotent', () => {
  const input =
    "platform :ios, '15.1'\ntarget 'Example' do\n  use_expo_modules!\n  use_react_native!\nend\n";
  const output = configurePodfile(input);
  assert.ok(
    output.indexOf('crumb_native_pods!') > output.indexOf("target 'Example'")
  );
  assert.ok(
    output.indexOf('crumb_native_pods!') < output.indexOf('use_react_native!')
  );
  assert.equal(configurePodfile(output), output);
});

test('unsupported Podfile layouts and manual duplicate pods fail with recovery', () => {
  assert.throws(
    () => configurePodfile('target "Example" do\nend'),
    /bare React Native setup/
  );
  for (const name of [
    'CrumbSDK',
    'CrumbSDKCore',
    'CrumbSDKUI',
    'PLCrashReporter',
  ]) {
    assert.throws(
      () => configurePodfile(`use_expo_modules!\npod '${name}'`),
      /Remove manual/
    );
  }
});
