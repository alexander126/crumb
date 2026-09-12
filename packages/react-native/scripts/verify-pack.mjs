import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import {
  lstatSync,
  mkdirSync,
  writeFileSync,
  mkdtempSync,
  readFileSync,
  readdirSync,
  rmSync,
} from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const temporary = mkdtempSync(join(tmpdir(), 'crumb-packed-'));
try {
  execFileSync(process.execPath, ['scripts/prepare-ios.mjs'], {
    cwd: root,
    stdio: 'inherit',
  });
  execFileSync(
    'npm',
    ['pack', '--ignore-scripts', '--pack-destination', temporary, '--json'],
    {
      cwd: root,
      stdio: 'pipe',
      env: { ...process.env, npm_config_cache: join(temporary, 'npm-cache') },
    }
  );
  const archive = readdirSync(temporary).find((name) => name.endsWith('.tgz'));
  assert.ok(archive);
  execFileSync('tar', ['-xzf', join(temporary, archive), '-C', temporary]);
  const packed = join(temporary, 'package');
  function compareTree(source, destination) {
    for (const entry of readdirSync(source, { withFileTypes: true })) {
      const original = join(source, entry.name);
      const copy = join(destination, entry.name);
      assert.ok(
        !lstatSync(copy).isSymbolicLink(),
        `npm must contain real files: ${copy}`
      );
      if (entry.isDirectory()) compareTree(original, copy);
      else
        assert.deepEqual(
          readFileSync(copy),
          readFileSync(original),
          `Packed file differs: ${copy}`
        );
    }
  }
  compareTree(join(root, 'native'), join(packed, 'native'));
  compareTree(
    resolve(root, '../ios/Sources'),
    join(packed, 'native/ios/packages/ios/Sources')
  );
  for (const file of [
    'lib/module/index.js',
    'lib/typescript/src/index.d.ts',
    'nitrogen/generated/ios/CrumbReactNative+autolinking.rb',
    'scripts/ios.rb',
    'app.plugin.js',
    'plugin/podfile.cjs',
    'LICENSE',
  ]) {
    assert.ok(readFileSync(join(packed, file)).length > 0, `Missing ${file}`);
  }
  const metadata = JSON.parse(
    readFileSync(join(packed, 'package.json'), 'utf8')
  );
  assert.equal(
    readFileSync(join(packed, 'native/ios/VERSION'), 'utf8').trim(),
    metadata.crumbNativeVersion
  );
  if (process.argv.includes('--ios')) {
    const consumer = join(temporary, 'consumer');
    const specs = join(temporary, 'empty-specs');
    mkdirSync(consumer);
    mkdirSync(specs);
    writeFileSync(
      join(specs, 'README.md'),
      'Empty local spec repository: no public registry allowed.\n'
    );
    execFileSync('git', ['init', '--quiet', specs]);
    execFileSync('git', ['-C', specs, 'add', 'README.md']);
    execFileSync('git', [
      '-C',
      specs,
      '-c',
      'user.name=Crumb Test',
      '-c',
      'user.email=test@example.invalid',
      '-c',
      'commit.gpgsign=false',
      'commit',
      '--quiet',
      '-m',
      'Empty specs fixture',
    ]);
    writeFileSync(
      join(consumer, 'Podfile'),
      `source "file://${specs}"
install! 'cocoapods', :integrate_targets => false
platform :ios, '15.1'
use_frameworks! :linkage => :static
require ${JSON.stringify(join(packed, 'scripts/ios'))}
target 'Consumer' do
  crumb_native_pods!
end
`
    );
    execFileSync('pod', ['install', '--project-directory=' + consumer], {
      stdio: 'inherit',
      env: {
        ...process.env,
        CP_HOME_DIR: join(temporary, 'cocoapods'),
        COCOAPODS_DISABLE_STATS: 'true',
      },
    });
    const lock = readFileSync(join(consumer, 'Podfile.lock'), 'utf8');
    assert.ok(
      !lock.includes('SPEC REPOS:'),
      'A native dependency was resolved from a spec repository'
    );
    execFileSync(
      'xcodebuild',
      [
        '-project',
        join(consumer, 'Pods/Pods.xcodeproj'),
        '-scheme',
        'CrumbSDKUI',
        '-configuration',
        'Debug',
        '-sdk',
        'iphonesimulator',
        '-destination',
        'generic/platform=iOS Simulator',
        '-derivedDataPath',
        join(temporary, 'build'),
        'CODE_SIGNING_ALLOWED=NO',
        'build',
        '-quiet',
      ],
      { stdio: 'inherit' }
    );
    console.log(
      'Packed native iOS consumer installed with an empty spec repository and built for iOS Simulator.'
    );
  }
  console.log(
    'Packed artifact verified: native sources, versions, generated bridge, JS/types, third-party frameworks, licenses, resources and setup helpers.'
  );
} finally {
  rmSync(temporary, { recursive: true, force: true });
}
