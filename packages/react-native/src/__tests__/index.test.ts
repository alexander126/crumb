jest.mock('react-native-nitro-modules', () => {
  const nativeMock = {
    start: jest.fn<void, [string]>(),
    canCollectLogs: jest.fn<boolean, []>(() => true),
    installReporter: jest.fn<Promise<boolean>, []>(() => Promise.resolve(true)),
    show: jest.fn<Promise<boolean>, []>(() => Promise.resolve(true)),
    recordJavaScriptCrash: jest.fn<void, [string]>(),
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
      canCollectLogs: jest.Mock<boolean, []>;
      installReporter: jest.Mock<Promise<boolean>, []>;
      show: jest.Mock<Promise<boolean>, []>;
      recordJavaScriptCrash: jest.Mock<void, [string]>;
      addLog: jest.Mock<void, [string]>;
      clearLogs: jest.Mock<void, []>;
    };
  }
).nativeMock;

describe('Crumb React Native adapter', () => {
  const runtimeGlobal = globalThis as unknown as {
    ErrorUtils?: {
      getGlobalHandler: () => (...args: unknown[]) => unknown;
      setGlobalHandler: (handler: (...args: unknown[]) => unknown) => void;
    };
    onunhandledrejection?: ((event: unknown) => unknown) | null;
  };
  let hostErrorHandler: (...args: unknown[]) => unknown;
  let hostRejectionHandler: ((event: unknown) => unknown) | undefined;

  beforeEach(() => {
    Crumb.disableConsoleCapture();
    Crumb.disableJavaScriptCrashCapture();
    Crumb.clearLogs();
    jest.clearAllMocks();
    mockNative.canCollectLogs.mockReturnValue(true);
    hostErrorHandler = jest.fn(() => 'host-error');
    hostRejectionHandler = jest.fn(() => 'host-rejection');
    runtimeGlobal.ErrorUtils = {
      getGlobalHandler: () => hostErrorHandler,
      setGlobalHandler: (handler) => {
        hostErrorHandler = handler;
      },
    };
    runtimeGlobal.onunhandledrejection = hostRejectionHandler;
  });

  afterEach(() => {
    Crumb.disableConsoleCapture();
    Crumb.disableJavaScriptCrashCapture();
    delete runtimeGlobal.ErrorUtils;
    runtimeGlobal.onunhandledrejection = undefined;
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

  it('keeps JavaScript crash capture disabled unless explicitly enabled', async () => {
    const errorUtils = runtimeGlobal.ErrorUtils;
    const rejectionHandler = runtimeGlobal.onunhandledrejection;

    await Crumb.start({
      projectKey: 'crumb_sdk_test',
      environment: 'test',
    });

    expect(errorUtils?.getGlobalHandler()).toBe(hostErrorHandler);
    expect(runtimeGlobal.onunhandledrejection).toBe(rejectionHandler);
    expect(mockNative.recordJavaScriptCrash).not.toHaveBeenCalled();
  });

  it('captures fatal exceptions and rejections before calling existing handlers', async () => {
    await Crumb.start({
      projectKey: 'crumb_sdk_test',
      environment: 'test',
      javascriptCrashCapture: { enabled: true, maximumBreadcrumbs: 1 },
    });
    Crumb.log('notice', 'before failure');

    const fatalHandler = hostErrorHandler;
    const fatalError = new TypeError('Checkout failed');
    expect(fatalHandler(fatalError, true)).toBe('host-error');
    expect(mockNative.recordJavaScriptCrash).toHaveBeenCalledTimes(1);
    expect(
      JSON.parse(mockNative.recordJavaScriptCrash.mock.calls[0]?.[0] ?? '{}')
    ).toMatchObject({
      kind: 'fatal_exception',
      source: 'javascript',
      errorType: 'TypeError',
      message: 'Checkout failed',
      nativeTerminationWrapper: false,
      breadcrumbs: [{ message: 'before failure' }],
    });
    expect(hostErrorHandler).toBe(fatalHandler);

    const rejection = runtimeGlobal.onunhandledrejection;
    expect(rejection?.({ reason: new Error('Promise failed') })).toBe(
      'host-rejection'
    );
    expect(mockNative.recordJavaScriptCrash).toHaveBeenCalledTimes(2);
    expect(hostRejectionHandler).toHaveBeenCalledTimes(1);
  });

  it('does not capture non-fatal ErrorUtils notifications', async () => {
    const existingHandler = hostErrorHandler;
    await Crumb.start({
      projectKey: 'crumb_sdk_test',
      environment: 'test',
      javascriptCrashCapture: { enabled: true },
    });

    hostErrorHandler(new Error('handled'), false);

    expect(mockNative.recordJavaScriptCrash).not.toHaveBeenCalled();
    expect(existingHandler).toHaveBeenCalledTimes(1);
  });

  it('does not overwrite a host handler that changed after installation', async () => {
    await Crumb.start({
      projectKey: 'crumb_sdk_test',
      environment: 'test',
      javascriptCrashCapture: { enabled: true },
    });
    const replacementErrorHandler = jest.fn();
    hostErrorHandler = replacementErrorHandler;
    const replacementRejectionHandler = jest.fn();
    runtimeGlobal.onunhandledrejection = replacementRejectionHandler;

    Crumb.disableJavaScriptCrashCapture();

    expect(hostErrorHandler).toBe(replacementErrorHandler);
    expect(runtimeGlobal.onunhandledrejection).toBe(
      replacementRejectionHandler
    );
  });

  it('fails closed for console logs until native policy permits collection', async () => {
    mockNative.canCollectLogs.mockReturnValue(false);
    const consoleError = jest
      .spyOn(console, 'error')
      .mockImplementation(() => undefined);

    await Crumb.start({
      projectKey: 'crumb_sdk_test',
      environment: 'test',
      diagnostics: { logs: { captureConsole: true } },
      workspacePolicy: {
        url: 'https://policy.example.invalid/sdk/v1/policy',
      },
    });

    mockNative.addLog.mockClear();
    console.error('blocked before policy');
    expect(mockNative.addLog).not.toHaveBeenCalled();

    mockNative.canCollectLogs.mockReturnValue(true);
    console.error('allowed after policy');
    expect(mockNative.addLog).toHaveBeenCalledTimes(1);

    consoleError.mockRestore();
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
