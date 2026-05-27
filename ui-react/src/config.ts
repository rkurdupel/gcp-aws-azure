declare global {
  interface Window {
    __COIN_OPS_CONFIG__?: {
      proxyUrl?: string;
      historyUrl?: string;
    };
  }
}

const runtimeConfig = typeof window !== 'undefined' ? window.__COIN_OPS_CONFIG__ : undefined;

export const PROXY_URL = runtimeConfig?.proxyUrl
  ?? ((import.meta as any).env.VITE_PROXY_URL as string)
  ?? '/api';

export const HISTORY_URL = runtimeConfig?.historyUrl
  ?? ((import.meta as any).env.VITE_HISTORY_URL as string)
  ?? '/history-api';

export const REFRESH_MS = 30_000;
export const PRICES_REFRESH_MS = 10_000;
