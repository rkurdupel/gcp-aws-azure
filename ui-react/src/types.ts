export interface MarketSnapshot {
  slug: string;
  question: string;
  yes_price: number;
  no_price: number;
  volume_24h: number;
  category: string;
  end_date: string;
  fetched_at: string;
}

export interface WhalePosition {
  market: string;
  slug?: string;
  outcome: string;
  current_value: number;
  size: number;
  avg_price: number;
}

export interface Whale {
  pseudonym: string;
  address: string;
  pnl: number;
  volume: number;
  rank: number;
  positions: WhalePosition[];
}

export interface HistoryPoint {
  fetched_at: string;
  yes_price: number;
  no_price: number;
  volume_24h: number;
}

export interface Prices {
  btc_usd: number;
  eth_usd: number;
  btc_24h_change: number;
  eth_24h_change: number;
  usd_uah: number;
  fetched_at: string;
}

export interface PriceHistory {
  price_usd: number;
  change_24h: number | null;
  fetched_at: string;
}
