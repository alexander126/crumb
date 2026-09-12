import { createHash } from 'node:crypto';
import { execFileSync } from 'node:child_process';
import {
  cpSync,
  copyFileSync,
  readdirSync,
  statSync,
  existsSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  rmSync,
  writeFileSync,
} from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const packageRoot = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const root = resolve(packageRoot, '../..');
const output = join(packageRoot, 'native/ios');
const dependency = {
  version: '1.12.0',
  url: 'https://github.com/microsoft/plcrashreporter/releases/download/1.12.0/PLCrashReporter-Static-1.12.0.xcframework.zip',
  sha256: '9e7124d63316a5e354fdeec631a3d669b1eaa533d3767a0089a05ab0eedc02b5',
};
const metadata = JSON.parse(
  readFileSync(join(packageRoot, 'package.json'), 'utf8')
);
const version = readFileSync(join(root, 'VERSION'), 'utf8').trim();
if (metadata.crumbNativeVersion !== version) {
  throw new Error(
    'React Native crumbNativeVersion must match the native VERSION before packaging.'
  );
}
for (const manifest of ['Package.swift', 'CrumbSDKCore.podspec']) {
  if (
    !readFileSync(join(root, manifest), 'utf8').includes(
      `"${dependency.version}"`
    )
  ) {
    throw new Error(
      `PLCrashReporter pin differs from ${manifest}; review the archive and checksum together.`
    );
  }
}

// This script runs only when preparing a release/development checkout, never on
// consumer install. The archive is integrity-checked before anything is extracted.
const temporary = mkdtempSync(join(tmpdir(), 'crumb-ios-package-'));
try {
  const archive = join(temporary, 'dependency.zip');
  const cachedArchive = process.env.CRUMB_PLCRASH_ARCHIVE;
  let bytes;
  if (cachedArchive) {
    bytes = readFileSync(cachedArchive);
  } else {
    const response = await fetch(dependency.url, {
      signal: AbortSignal.timeout(120_000),
    });
    if (!response.ok)
      throw new Error(`PLCrashReporter download failed (${response.status}).`);
    bytes = Buffer.from(await response.arrayBuffer());
  }
  if (createHash('sha256').update(bytes).digest('hex') !== dependency.sha256) {
    throw new Error(
      'PLCrashReporter archive checksum mismatch; refusing to package it.'
    );
  }
  writeFileSync(archive, bytes);
  execFileSync('unzip', ['-q', archive, '-d', temporary]);
  rmSync(output, { recursive: true, force: true });
  mkdirSync(output, { recursive: true });
  cpSync(
    join(root, 'packages/ios/Sources'),
    join(output, 'packages/ios/Sources'),
    { recursive: true }
  );
  for (const file of [
    'VERSION',
    'LICENSE',
    'CrumbSDKCore.podspec',
    'CrumbSDKUI.podspec',
  ]) {
    cpSync(join(root, file), join(output, file));
  }
  // Dereference the official framework symlinks because npm omits symlinks.
  // Preserve the complete official XCFramework, privacy manifest and license.
  const thirdParty = join(output, 'PLCrashReporter');
  mkdirSync(thirdParty);
  function copyRealFiles(source, destination) {
    if (statSync(source).isDirectory()) {
      mkdirSync(destination, { recursive: true });
      for (const name of readdirSync(source)) {
        copyRealFiles(join(source, name), join(destination, name));
      }
    } else {
      copyFileSync(source, destination);
    }
  }
  copyRealFiles(
    join(temporary, 'PLCrashReporter/CrashReporter.xcframework'),
    join(thirdParty, 'CrashReporter.xcframework')
  );
  cpSync(
    join(temporary, 'PLCrashReporter/LICENSE.txt'),
    join(thirdParty, 'LICENSE.txt')
  );
  cpSync(
    join(packageRoot, 'scripts/PLCrashReporter.podspec'),
    join(thirdParty, 'PLCrashReporter.podspec')
  );
  writeFileSync(
    join(output, 'provenance.json'),
    JSON.stringify(
      { nativeVersion: version, PLCrashReporter: dependency },
      null,
      2
    ) + '\n'
  );
  if (
    !existsSync(
      join(thirdParty, 'CrashReporter.xcframework/PrivacyInfo.xcprivacy')
    )
  ) {
    throw new Error('Official PLCrashReporter privacy manifest is missing.');
  }
  console.log(
    `Prepared Crumb ${version} and PLCrashReporter ${dependency.version} for local iOS installation.`
  );
} finally {
  rmSync(temporary, { recursive: true, force: true });
}
