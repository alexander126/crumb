const fs = require('node:fs');
const path = require('node:path');

function readConfig(root) {
  const file = path.join(root, 'crumb.config.json');
  if (!fs.existsSync(file))
    return { version: 1, sourceMaps: { enabled: false } };
  let config;
  try {
    config = JSON.parse(fs.readFileSync(file, 'utf8'));
  } catch {
    throw new Error(
      'Could not read crumb.config.json. Check that it contains valid JSON without credentials.'
    );
  }
  if (
    !config ||
    typeof config !== 'object' ||
    Array.isArray(config) ||
    config.version !== 1 ||
    !config.sourceMaps ||
    typeof config.sourceMaps !== 'object' ||
    Array.isArray(config.sourceMaps) ||
    Object.keys(config).some(
      (key) => !['version', 'sourceMaps'].includes(key)
    ) ||
    Object.keys(config.sourceMaps).some(
      (key) => !['enabled', 'uploadUrl', 'strict'].includes(key)
    ) ||
    typeof config.sourceMaps.enabled !== 'boolean' ||
    (config.sourceMaps.strict !== undefined &&
      typeof config.sourceMaps.strict !== 'boolean')
  ) {
    throw new Error(
      'Invalid crumb.config.json. Use crumb setup; keep credentials only in the build environment.'
    );
  }
  if (config.sourceMaps.enabled) validateOrigin(config.sourceMaps.uploadUrl);
  return config;
}

function validateOrigin(value) {
  let url;
  try {
    url = new URL(value);
  } catch {
    throw new Error(
      'Supply the HTTPS upload origin shown in your Crumb integration instructions.'
    );
  }
  if (
    url.protocol !== 'https:' ||
    url.username ||
    url.password ||
    url.search ||
    url.hash ||
    url.pathname !== '/'
  ) {
    throw new Error(
      'The upload origin must use HTTPS without a path, credentials, query, or fragment.'
    );
  }
  return url.origin;
}

function isStrict(config, env = process.env) {
  return (
    env.CRUMB_SOURCE_MAP_STRICT === '1' || config.sourceMaps.strict === true
  );
}

module.exports = { readConfig, validateOrigin, isStrict };
