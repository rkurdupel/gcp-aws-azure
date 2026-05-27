import { render, screen } from '@testing-library/react';
import { describe, expect, it } from 'vitest';

import { HeroCurrencyChart } from './HeroCurrencyChart';

describe('HeroCurrencyChart', () => {
  it('shows empty-state text when there is no price history', () => {
    render(
      <HeroCurrencyChart
        title="USD / UAH"
        data={[]}
        formatter={(value) => `₴${value.toFixed(2)}`}
      />,
    );

    expect(screen.getByText('USD / UAH')).toBeInTheDocument();
    expect(screen.getByText('No points yet')).toBeInTheDocument();
    expect(screen.getByText('Waiting for price history.')).toBeInTheDocument();
  });

  it('shows the title and chart wrapper when data exists', () => {
    const { container } = render(
      <HeroCurrencyChart
        title="USD / UAH"
        data={[
          {
            fetched_at: '2026-01-01T00:00:00Z',
            price_usd: 41.25,
            change_24h: 0.5,
          },
          {
            fetched_at: '2026-01-01T01:00:00Z',
            price_usd: 41.4,
            change_24h: 0.7,
          },
        ]}
        formatter={(value) => `₴${value.toFixed(2)}`}
      />,
    );

    expect(screen.getByText('USD / UAH')).toBeInTheDocument();
    expect(screen.getByText('2 points')).toBeInTheDocument();
    expect(screen.queryByText('Waiting for price history.')).not.toBeInTheDocument();
    expect(container.querySelector('.recharts-wrapper')).toBeInTheDocument();
  });
});
