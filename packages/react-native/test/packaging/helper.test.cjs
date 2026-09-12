const assert = require('node:assert/strict');
const { test } = require('node:test');
const { execFileSync } = require('node:child_process');
const {
  cpSync,
  mkdirSync,
  mkdtempSync,
  writeFileSync,
  rmSync,
} = require('node:fs');
const { tmpdir } = require('node:os');
const { join, resolve } = require('node:path');

test('Podfile helper reports a missing bundle and a mismatched version', () => {
  const temporary = mkdtempSync(join(tmpdir(), 'crumb-helper-'));
  try {
    mkdirSync(join(temporary, 'scripts'));
    cpSync(
      resolve(__dirname, '../../scripts/ios.rb'),
      join(temporary, 'scripts/ios.rb')
    );
    writeFileSync(
      join(temporary, 'package.json'),
      JSON.stringify({ crumbNativeVersion: '1.0.0' })
    );
    const run = () =>
      execFileSync(
        'ruby',
        ['-r', join(temporary, 'scripts/ios.rb'), '-e', 'crumb_native_pods!'],
        { stdio: 'pipe' }
      );
    assert.throws(run, (error) =>
      error.stderr.toString().includes('bundled iOS files are missing')
    );
    for (const file of [
      'VERSION',
      'CrumbSDKCore.podspec',
      'CrumbSDKUI.podspec',
      'packages/ios/Sources/CrumbCore/CrumbConfiguration.swift',
      'PLCrashReporter/PLCrashReporter.podspec',
      'PLCrashReporter/CrashReporter.xcframework/Info.plist',
    ]) {
      const path = join(temporary, 'native/ios', file);
      mkdirSync(require('node:path').dirname(path), { recursive: true });
      writeFileSync(path, '0.0.0');
    }
    assert.throws(run, (error) =>
      error.stderr.toString().includes('version does not match')
    );
  } finally {
    rmSync(temporary, { recursive: true, force: true });
  }
});
