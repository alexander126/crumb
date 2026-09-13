import { withBuildRelease } from '../build-release';

afterEach(() => {
  globalThis.__CRUMB_BUNDLE_VERSION__ = undefined;
});

test('unconfigured apps keep their manual release and crash opt-in unchanged', () => {
  const config = {
    projectKey: 'test',
    environment: 'test',
    release: { bundleVersion: 'manual' },
  };
  expect(withBuildRelease(config)).toBe(config);
});

test('generated build identity reaches runtime configuration without changing native version defaults', () => {
  globalThis.__CRUMB_BUNDLE_VERSION__ = 'build-123';
  const config = { projectKey: 'test', environment: 'test' };
  expect(withBuildRelease(config)).toEqual({
    ...config,
    release: { bundleVersion: 'build-123' },
  });
  expect(config).not.toHaveProperty('release');
});

test('manual and generated bundle identities must agree', () => {
  globalThis.__CRUMB_BUNDLE_VERSION__ = 'build-123';
  const config = {
    projectKey: 'test',
    environment: 'test',
    release: { bundleVersion: 'old-update' },
  };
  expect(() => withBuildRelease(config)).toThrow('conflicts');
  expect(
    withBuildRelease({ ...config, release: { bundleVersion: 'build-123' } })
      .release?.bundleVersion
  ).toBe('build-123');
});
