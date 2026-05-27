import { fireEvent, render, screen } from '@testing-library/react';
import { describe, expect, it, vi } from 'vitest';

import { MarketCard } from './MarketCard';

describe('MarketCard', () => {
  it('shows market text, values, and calls onClick when pressed', () => {
    const onClick = vi.fn();

    render(
      <MarketCard
        market={{
          slug: 'btc-100k',
          question: 'Will Bitcoin hit 100k?',
          yes_price: 0.62,
          no_price: 0.38,
          volume_24h: 24000,
          category: '',
          end_date: '2026-01-01T00:00:00Z',
          fetched_at: '2026-01-01T00:00:00Z',
        }}
        onClick={onClick}
      />,
    );

    expect(screen.getByText('Crypto')).toBeInTheDocument();
    expect(screen.getByText('Will Bitcoin hit 100k?')).toBeInTheDocument();
    expect(screen.getByText('YES 62.0%')).toBeInTheDocument();
    expect(screen.getByText('NO 38.0%')).toBeInTheDocument();
    expect(screen.getByText('24K Vol')).toBeInTheDocument();

    fireEvent.click(screen.getByText('Will Bitcoin hit 100k?'));

    expect(onClick).toHaveBeenCalledTimes(1);
  });
});
