import { describe, expect, it } from 'vitest';

import {
  filterMarkets,
  formatChartTime,
  formatCompactCurrency,
  getMarketCategoryLabel,
  normalizeHistoryPoint,
} from './dashboard-helpers';
import type { HistoryPoint, MarketSnapshot } from '../types';

describe('getMarketCategoryLabel', () => {
  it('returns the explicit category when present', () => {
    const market: MarketSnapshot = {
      slug: 'custom-market',
      question: 'Anything here',
      yes_price: 0.5,
      no_price: 0.5,
      volume_24h: 1000,
      category: 'Sports',
      end_date: '2026-01-01T00:00:00Z',
      fetched_at: '2026-01-01T00:00:00Z',
    };

    expect(getMarketCategoryLabel(market)).toBe('Sports');
  });

  it('detects categories from market text and falls back to Uncategorized', () => {
    const cryptoMarket: MarketSnapshot = {
      slug: 'btc-100k',
      question: 'Will Bitcoin hit 100k?',
      yes_price: 0.6,
      no_price: 0.4,
      volume_24h: 1000,
      category: '',
      end_date: '2026-01-01T00:00:00Z',
      fetched_at: '2026-01-01T00:00:00Z',
    };

    const politicsMarket: MarketSnapshot = {
      slug: 'election-winner',
      question: 'Who wins the presidential election?',
      yes_price: 0.5,
      no_price: 0.5,
      volume_24h: 1000,
      category: '',
      end_date: '2026-01-01T00:00:00Z',
      fetched_at: '2026-01-01T00:00:00Z',
    };

    const unknownMarket: MarketSnapshot = {
      slug: 'random-topic',
      question: 'Will the library open early tomorrow?',
      yes_price: 0.5,
      no_price: 0.5,
      volume_24h: 1000,
      category: '',
      end_date: '2026-01-01T00:00:00Z',
      fetched_at: '2026-01-01T00:00:00Z',
    };

    expect(getMarketCategoryLabel(cryptoMarket)).toBe('Crypto');
    expect(getMarketCategoryLabel(politicsMarket)).toBe('Politics');
    expect(getMarketCategoryLabel(unknownMarket)).toBe('Uncategorized');
  });
});

describe('normalizeHistoryPoint', () => {
  it('clamps yes_price and recalculates no_price from it', () => {
    const tooHigh: HistoryPoint = {
      fetched_at: '2026-01-01T00:00:00Z',
      yes_price: 1.4,
      no_price: 0,
      volume_24h: 1000,
    };

    const tooLow: HistoryPoint = {
      fetched_at: '2026-01-01T00:00:00Z',
      yes_price: -0.2,
      no_price: 0,
      volume_24h: 1000,
    };

    expect(normalizeHistoryPoint(tooHigh)).toMatchObject({
      yes_price: 1,
      no_price: 0,
    });

    expect(normalizeHistoryPoint(tooLow)).toMatchObject({
      yes_price: 0,
      no_price: 1,
    });
  });
});

describe('filterMarkets', () => {
  const markets: MarketSnapshot[] = [
    {
      slug: 'btc-market',
      question: 'Will Bitcoin reach 100k?',
      yes_price: 0.6,
      no_price: 0.4,
      volume_24h: 3000,
      category: '',
      end_date: '2026-01-01T00:00:00Z',
      fetched_at: '2026-01-01T00:00:00Z',
    },
    {
      slug: 'sports-market',
      question: 'Will Real Madrid win the final?',
      yes_price: 0.4,
      no_price: 0.6,
      volume_24h: 2000,
      category: 'Sports',
      end_date: '2026-01-01T00:00:00Z',
      fetched_at: '2026-01-01T00:00:00Z',
    },
    {
      slug: 'macro-market',
      question: 'Will inflation fall next quarter?',
      yes_price: 0.5,
      no_price: 0.5,
      volume_24h: 1500,
      category: '',
      end_date: '2026-01-01T00:00:00Z',
      fetched_at: '2026-01-01T00:00:00Z',
    },
  ];

  it('filters by search query', () => {
    expect(filterMarkets(markets, 'bitcoin', null)).toHaveLength(1);
    expect(filterMarkets(markets, 'sports', null)).toHaveLength(1);
  });

  it('filters by category', () => {
    const result = filterMarkets(markets, '', 'Sports');

    expect(result).toHaveLength(1);
    expect(result[0].slug).toBe('sports-market');
  });

  it('works with empty query and null category', () => {
    expect(filterMarkets(markets, '', null)).toHaveLength(3);
  });
});

describe('formatCompactCurrency', () => {
  it('formats small, thousand, million, and billion values', () => {
    expect(formatCompactCurrency(999)).toBe('999');
    expect(formatCompactCurrency(1500)).toBe('1.5K');
    expect(formatCompactCurrency(2500000)).toBe('2.5M');
    expect(formatCompactCurrency(3200000000)).toBe('3.2B');
  });
});

describe('formatChartTime', () => {
  it('returns a non-empty string', () => {
    const result = formatChartTime('2026-01-01T12:34:56Z');

    expect(typeof result).toBe('string');
    expect(result.length).toBeGreaterThan(0);
  });
});
