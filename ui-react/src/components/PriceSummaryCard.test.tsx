import { fireEvent, render, screen } from '@testing-library/react';
import { describe, expect, it, vi } from 'vitest';

import { PriceSummaryCard } from './PriceSummaryCard';

describe('PriceSummaryCard', () => {
  it('shows fallback text when price, change, and history are missing', () => {
    render(
      <PriceSummaryCard
        title="Bitcoin"
        symbol="BTC"
        data={[]}
        accentClassName="from-orange-500/20 via-amber-400/10 to-transparent"
        onClick={vi.fn()}
      />,
    );

    expect(screen.getByText('Bitcoin')).toBeInTheDocument();
    expect(screen.getByText('--')).toBeInTheDocument();
    expect(screen.getByText('No change data')).toBeInTheDocument();
    expect(screen.getByText('Waiting for price history.')).toBeInTheDocument();
  });

  it('shows title and values, and calls onClick when pressed', () => {
    const onClick = vi.fn();

    render(
      <PriceSummaryCard
        title="Bitcoin"
        symbol="BTC"
        price={105000}
        change={2.5}
        data={[
          {
            fetched_at: '2026-01-01T00:00:00Z',
            price_usd: 103500,
            change_24h: 2.1,
          },
        ]}
        accentClassName="from-orange-500/20 via-amber-400/10 to-transparent"
        onClick={onClick}
      />,
    );

    expect(screen.getByText('BTC')).toBeInTheDocument();
    expect(screen.getByText('Bitcoin')).toBeInTheDocument();
    expect(screen.getByText((_, element) => element?.textContent === `$${(105000).toLocaleString()}`)).toBeInTheDocument();
    expect(screen.getByText('+2.50% 24h')).toBeInTheDocument();
    expect(screen.getByText('Tap for full chart')).toBeInTheDocument();

    fireEvent.click(screen.getByRole('button'));

    expect(onClick).toHaveBeenCalledTimes(1);
  });
});
