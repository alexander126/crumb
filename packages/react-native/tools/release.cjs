const fs = require('node:fs');
const path = require('node:path');
const { randomUUID, createHash } = require('node:crypto');

function prepareRelease(directory) {
  fs.mkdirSync(directory, { recursive: true });
  const bundleVersion = randomUUID();
  const polyfill = path.join(directory, 'crumb-release.js');
  fs.writeFileSync(
    polyfill,
    `globalThis.__CRUMB_BUNDLE_VERSION__ = ${JSON.stringify(bundleVersion)};\n`
  );
  const manifest = path.join(directory, 'release.json');
  fs.writeFileSync(
    manifest,
    JSON.stringify({ version: 1, bundleVersion, polyfill })
  );
  return manifest;
}

function readRelease(file) {
  const value = JSON.parse(fs.readFileSync(file, 'utf8'));
  if (
    value.version !== 1 ||
    typeof value.bundleVersion !== 'string' ||
    !/^[A-Za-z0-9][A-Za-z0-9._+-]{0,127}$/.test(value.bundleVersion) ||
    typeof value.polyfill !== 'string' ||
    !path.isAbsolute(value.polyfill)
  ) {
    throw new Error(
      'Crumb release metadata is invalid. Rebuild using the configured Crumb build hook.'
    );
  }
  return value;
}

function hashFile(file) {
  return createHash('sha256').update(fs.readFileSync(file)).digest('hex');
}

function verifyMapIdentity(file, bundleVersion) {
  if (fs.statSync(file).size > 25 * 1024 * 1024)
    throw new Error('Source map exceeds the 25 MiB upload limit.');
  const map = JSON.parse(fs.readFileSync(file, 'utf8'));
  function contains(value, depth = 0) {
    if (!value || depth > 8) return false;
    return (
      (Array.isArray(value.sourcesContent) &&
        value.sourcesContent.some(
          (source) =>
            typeof source === 'string' &&
            source.includes('__CRUMB_BUNDLE_VERSION__') &&
            source.includes(JSON.stringify(bundleVersion))
        )) ||
      (Array.isArray(value.sections) &&
        value.sections.some((section) => contains(section.map, depth + 1)))
    );
  }
  if (!contains(map))
    throw new Error(
      'The final map does not contain this build’s Crumb identity. Check the Metro integration and rebuild; no artifacts were uploaded.'
    );
}

module.exports = { prepareRelease, readRelease, hashFile, verifyMapIdentity };
