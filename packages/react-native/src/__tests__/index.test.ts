jest.mock('react-native-nitro-modules', () => {
  const nativeMock = {
    start: jest.fn<void, [string]>(),
    installReporter: jest.fn<Promise<boolean>, []>(() => Promise.resolve(true)),
    show: jest.fn<Promise<boolean>, []>(() => Promise.resolve(true)),
    addLog: jest.fn<void, [string]>(),
    clearLogs: jest.fn<void, []>(),
  };
  return {
    NitroModules: {
      createHybridObject: () => nativeMock,
    },
    nativeMock,
  };
});

import Crumb from '../index';

const mockNative = (
  jest.requireMock('react-native-nitro-modules') as {
    nativeMock: {
      start: jest.Mock<void, [string]>;
      installReporter: jest.Mock<Promise<boolean>, []>;
      show: jest.Mock<Promise<boolean>, []>;
      addLog: jest.Mock<void, [string]>;
      clearLogs: jest.Mock<void, []>;
    };
  }
).nativeMock;

describe('Crumb React Native adapter', () => {
  beforeEach(() => {
    Crumb.disableConsoleCapture();
    Crumb.clearLogs();
    jest.clearAllMocks();
  });

  afterEach(() => {
    Crumb.disableConsoleCapture();
  });

  it('starts the native SDK with the typed configuration', async () => {
    await Crumb.start({
      projectKey: 'crumb_sdk_test',
      environment: 'test',
      invocation: ['programmatic'],
      release: { bundleVersion: 'ota-42' },
    });

    expect(mockNative.start).toHaveBeenCalledTimes(1);
    expect(
      JSON.parse(mockNative.start.mock.calls[0]?.[0] ?? '{}')
    ).toMatchObject({
      projectKey: 'crumb_sdk_test',
      environment: 'test',
      invocation: ['programmatic'],
      release: { bundleVersion: 'ota-42' },
    });
  });

  it('passes the privacy precedence configuration to the native owner', async () => {
    await Crumb.start({
      projectKey: 'crumb_sdk_test',
      environment: 'test',
      reporter: { theme: 'dark', visibleFields: ['category', 'description'] },
      evidence: ['screenshot', 'logs', 'custom_context'],
      application: { name: 'Example app' },
      customContext: {
        values: { account_tier: 'trial' },
        allowedKeys: ['account_tier'],
      },
      workspacePolicy: {
        url: 'https://policy.example.invalid/sdk/v1/policy',
        timeoutMs: 2000,
      },
    });

    expect(
      JSON.parse(mockNative.start.mock.calls[0]?.[0] ?? '{}')
    ).toMatchObject({
      reporter: { theme: 'dark', visibleFields: ['category', 'description'] },
      evidence: ['screenshot', 'logs', 'custom_context'],
      application: { name: 'Example app' },
      customContext: {
        values: { account_tier: 'trial' },
        allowedKeys: ['account_tier'],
      },
      workspacePolicy: {
        url: 'https://policy.example.invalid/sdk/v1/policy',
        timeoutMs: 2000,
      },
    });
  });

  it('mirrors bounded structured logs to native storage', async () => {
    await Crumb.start({
      projectKey: 'crumb_sdk_test',
      environment: 'test',
    });
    mockNative.addLog.mockClear();

    const metadata: Record<string, unknown> = { attempt: 2 };
    metadata.circular = metadata;
    Crumb.log('error', 'Checkout failed', metadata);

    expect(mockNative.addLog).toHaveBeenCalledTimes(1);
    const entry = JSON.parse(mockNative.addLog.mock.calls[0]?.[0] ?? '{}');
    expect(entry).toMatchObject({
      level: 'error',
      source: 'react-native',
      category: 'javascript',
    });
    expect(entry.message).toContain('Checkout failed');
    expect(entry.message).toContain('[Circular]');
  });

  it('captures console errors without swallowing the host console method', async () => {
    const originalConsoleError = console.error;
    const consoleError = jest
      .spyOn(console, 'error')
      .mockImplementation(() => undefined);
    await Crumb.start({
      projectKey: 'crumb_sdk_test',
      environment: 'test',
      diagnostics: { logs: { captureConsole: true } },
    });
    mockNative.addLog.mockClear();

    console.error('Network failed', new Error('offline'));

    expect(consoleError).toHaveBeenCalledTimes(1);
    expect(mockNative.addLog).toHaveBeenCalledTimes(1);
    expect(
      JSON.parse(mockNative.addLog.mock.calls[0]?.[0] ?? '{}')
    ).toMatchObject({
      level: 'error',
      category: 'console',
    });

    Crumb.disableConsoleCapture();
    consoleError.mockRestore();
    expect(console.error).toBe(originalConsoleError);
  });

  it('delegates reporter installation and presentation', async () => {
    await expect(Crumb.installReporter()).resolves.toBe(true);
    await expect(Crumb.show()).resolves.toBe(true);
  });

  it('rejects empty required configuration values before crossing native', async () => {
    await expect(
      Crumb.start({ projectKey: ' ', environment: 'test' })
    ).rejects.toThrow('projectKey');
    expect(mockNative.start).not.toHaveBeenCalled();
  });

  it('rejects invalid buffer limits before they can stall pruning', async () => {
    await expect(
      Crumb.start({
        projectKey: 'crumb_sdk_test',
        environment: 'test',
        diagnostics: { logs: { maximumEntries: -1 } },
      })
    ).rejects.toThrow('maximumEntries');
    expect(mockNative.start).not.toHaveBeenCalled();
  });

  it('rejects a policy endpoint that can carry credentials or query values', async () => {
    await expect(
      Crumb.start({
        projectKey: 'crumb_sdk_test',
        environment: 'test',
        workspacePolicy: {
          url: 'https://user:pass@policy.example.invalid/policy?x=1',
        },
      })
    ).rejects.toThrow('workspacePolicy.url');
    expect(mockNative.start).not.toHaveBeenCalled();
  });

  it('requires the description field to remain visible', async () => {
    await expect(
      Crumb.start({
        projectKey: 'crumb_sdk_test',
        environment: 'test',
        reporter: { visibleFields: ['category'] },
      })
    ).rejects.toThrow('visibleFields');
    expect(mockNative.start).not.toHaveBeenCalled();
  });
});
