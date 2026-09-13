const { readRelease } = require('./tools/release.cjs');

/** Preserve existing Metro options and include non-secret release metadata before app startup. */
function withCrumb(config) {
  if (typeof config === 'function')
    return (...args) => withCrumb(config(...args));
  if (config && typeof config.then === 'function')
    return config.then(withCrumb);
  if (!config || typeof config !== 'object')
    throw new Error('Pass your existing Metro configuration to withCrumb.');
  const manifest = process.env.CRUMB_RELEASE_MANIFEST;
  if (!manifest) return config;
  const release = readRelease(manifest);
  const getPolyfills = config.serializer?.getPolyfills;
  return {
    ...config,
    serializer: {
      ...config.serializer,
      getPolyfills: (...args) => [
        ...new Set([
          ...(getPolyfills ? getPolyfills(...args) : []),
          release.polyfill,
        ]),
      ],
    },
    watchFolders: [
      ...new Set([
        ...(config.watchFolders || []),
        require('node:path').dirname(release.polyfill),
      ]),
    ],
  };
}

module.exports = { withCrumb };
