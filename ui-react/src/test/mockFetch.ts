import { vi } from 'vitest';

type MockRoute = {
  match: string | RegExp;
  response?: unknown;
  ok?: boolean;
  reject?: Error;
};

function matchesRoute(url: string, match: string | RegExp) {
  if (typeof match === 'string') {
    return url.includes(match);
  }

  return match.test(url);
}

export function mockFetch(routes: MockRoute[]) {
  return vi.spyOn(globalThis, 'fetch').mockImplementation(async (input) => {
    const url = typeof input === 'string' ? input : input.toString();
    const route = routes.find((item) => matchesRoute(url, item.match));

    if (!route) {
      throw new Error(`Unhandled fetch in test: ${url}`);
    }

    if (route.reject) {
      return Promise.reject(route.reject);
    }

    return {
      ok: route.ok ?? true,
      json: async () => route.response,
    } as Response;
  });
}
