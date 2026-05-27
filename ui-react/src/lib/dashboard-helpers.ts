import type { HistoryPoint, MarketSnapshot } from '../types';

export function getMarketCategoryLabel(market: MarketSnapshot): string {
  const explicitCategory = market.category?.trim();
  if (explicitCategory) return explicitCategory;

  const source = `${market.question} ${market.slug}`.toLowerCase();

  if (/(bitcoin|btc|ethereum|eth|solana|sol|crypto|doge|xrp|token|coin|polymarket)/.test(source)) {
    return 'Crypto';
  }
  if (/(trump|biden|election|president|senate|house|democrat|republican|vote|politic)/.test(source)) {
    return 'Politics';
  }
  if (/(iran|israel|russia|ukraine|war|ceasefire|conflict|china|taiwan|nato|us conflict)/.test(source)) {
    return 'Geopolitics';
  }
  if (/(fed|inflation|cpi|rate cut|recession|economy|gdp|tariff)/.test(source)) {
    return 'Macro';
  }
  if (/(nba|nfl|mlb|nhl|soccer|football|tennis|f1|formula 1|playoff|championship)/.test(source)) {
    return 'Sports';
  }

  return 'Uncategorized';
}

export function normalizeHistoryPoint(point: HistoryPoint) {
  const yesPrice = Math.max(0, Math.min(1, point.yes_price));
  const noPrice = Math.max(0, Math.min(1, 1 - yesPrice));

  return {
    ...point,
    yes_price: yesPrice,
    no_price: noPrice,
  };
}

export function filterMarkets(
  markets: MarketSnapshot[],
  searchQuery: string,
  selectedCategory: string | null,
) {
  const normalizedSearchQuery = searchQuery.toLowerCase();

  return markets.filter((market) => {
    const normalizedCategory = getMarketCategoryLabel(market);
    const matchesSearch =
      market.question.toLowerCase().includes(normalizedSearchQuery) ||
      normalizedCategory.toLowerCase().includes(normalizedSearchQuery);
    const matchesCategory = selectedCategory ? normalizedCategory === selectedCategory : true;

    return matchesSearch && matchesCategory;
  });
}

export function formatCompactCurrency(value: number) {
  if (value >= 1_000_000_000) return `${(value / 1_000_000_000).toFixed(1)}B`;
  if (value >= 1_000_000) return `${(value / 1_000_000).toFixed(1)}M`;
  if (value >= 1_000) return `${(value / 1_000).toFixed(1)}K`;
  return value.toFixed(0);
}

export function formatChartTime(value: string) {
  return new Date(value).toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' });
}
