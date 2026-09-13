import type { CrumbConfiguration } from './types';

declare global {
  // Written by the release build polyfill before application modules execute.
  var __CRUMB_BUNDLE_VERSION__: unknown;
}

export function withBuildRelease(
  configuration: CrumbConfiguration
): CrumbConfiguration {
  const bundleVersion = globalThis.__CRUMB_BUNDLE_VERSION__;
  if (
    typeof bundleVersion !== 'string' ||
    !/^[A-Za-z0-9][A-Za-z0-9._+-]{0,127}$/.test(bundleVersion)
  ) {
    return configuration;
  }
  if (
    configuration.release?.bundleVersion !== undefined &&
    configuration.release.bundleVersion !== bundleVersion
  ) {
    throw new TypeError(
      'Crumb release.bundleVersion conflicts with the generated build identity. Remove the manual value or disable automatic source-map setup.'
    );
  }
  return {
    ...configuration,
    release: { ...configuration.release, bundleVersion },
  };
}
