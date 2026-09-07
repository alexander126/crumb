import { useEffect } from 'react';
import NativeCrumbReactNative from './NativeCrumbReactNative';

export interface CrumbScreenOptions {
  /** Static names from root to focused screen, never route parameters. Maximum eight. */
  readonly route?: readonly string[];
}

interface ScreenContext {
  readonly name: string;
  readonly route: readonly string[];
  readonly source: 'manual' | 'react_navigation' | 'expo_router';
}

/** Compatible with a React Navigation container ref; no navigation dependency required. */
export interface CrumbNavigationRef {
  isReady(): boolean;
  getRootState(): unknown;
  addListener(event: 'ready' | 'state', listener: () => void): () => void;
}

let owner: object | null = null;
let screenJson = 'null';

/** Snapshot before crossing the async native UI dispatch boundary. */
export function currentScreenJson(): string {
  return screenJson;
}

function validLabel(value: unknown): value is string {
  // UTF-8 bytes, including surrogate pairs, without requiring TextEncoder in Hermes.
  if (
    typeof value !== 'string' ||
    !value.trim() ||
    value.length > 128 ||
    // Reject control characters in untrusted screen labels.
    // eslint-disable-next-line no-control-regex
    /[\u0000-\u001f\u007f-\u009f?#]|:\/\//.test(value)
  )
    return false;
  let bytes = 0;
  for (const char of value) {
    const point = char.codePointAt(0) ?? 0;
    bytes += point <= 0x7f ? 1 : point <= 0x7ff ? 2 : point <= 0xffff ? 3 : 4;
  }
  return bytes <= 128;
}

function publish(context: ScreenContext | null, token: object): void {
  owner = token;
  screenJson = JSON.stringify(context);
  NativeCrumbReactNative.setScreenContext(screenJson);
}

function release(token: object): void {
  if (owner === token) publish(null, token);
}

/** Supply a static screen name. Call with null when the app no longer has an active screen. */
export function setScreen(
  name: string | null,
  options?: CrumbScreenOptions
): void {
  const token = {};
  if (name === null) {
    publish(null, token);
    return;
  }
  const route = options?.route ?? [name];
  if (
    !validLabel(name) ||
    route.length < 1 ||
    route.length > 8 ||
    !route.every(validLabel)
  ) {
    publish(null, token);
    throw new Error(
      'Crumb screen names must be static labels of at most 128 UTF-8 bytes, with one to eight route names and no URL, query or fragment.'
    );
  }
  publish({ name, route: [...route], source: 'manual' }, token);
}

function record(value: unknown): value is Record<string, unknown> {
  return value !== null && typeof value === 'object' && !Array.isArray(value);
}

/** Register once at the container; handles initial ready, nested state changes and cleanup. */
export function trackReactNavigation(ref: CrumbNavigationRef): () => void {
  const token = {};
  let active = true;
  const update = () => {
    if (!active) return;
    try {
      if (!ref.isReady()) {
        publish(null, token);
        return;
      }
      let state: unknown = ref.getRootState();
      const route: string[] = [];
      while (record(state) && Array.isArray(state.routes)) {
        if (route.length === 8 || !Number.isInteger(state.index)) {
          publish(null, token);
          return;
        }
        const focused: unknown = state.routes[Number(state.index)];
        if (!record(focused) || !validLabel(focused.name)) {
          publish(null, token);
          return;
        }
        route.push(focused.name);
        state = focused.state;
      }
      const name = route[route.length - 1];
      publish(name ? { name, route, source: 'react_navigation' } : null, token);
    } catch {
      publish(null, token);
    }
  };
  const ready = ref.addListener('ready', update);
  const state = ref.addListener('state', update);
  update();
  return () => {
    active = false;
    ready();
    state();
    release(token);
  };
}

/** Pass Expo Router useSegments(), never usePathname() or search parameters. */
export function useExpoRouterScreen(segments: readonly string[]): void {
  const key = JSON.stringify(segments);
  useEffect(() => {
    const token = {};
    // Reconstruct only validated strings; dynamic segments remain templates such as [id].
    const value: unknown = JSON.parse(key);
    const route = Array.isArray(value) && value.length === 0 ? ['/'] : value;
    const name = Array.isArray(route)
      ? '/' + route.filter((part) => part !== '/').join('/')
      : '';
    if (
      Array.isArray(route) &&
      route.length <= 8 &&
      route.every(validLabel) &&
      validLabel(name)
    ) {
      publish({ name, route, source: 'expo_router' }, token);
    } else {
      publish(null, token);
    }
    return () => release(token);
  }, [key]);
}
