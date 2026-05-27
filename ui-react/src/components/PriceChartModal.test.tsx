import { fireEvent, render, screen } from '@testing-library/react';
import { describe, expect, it, vi } from 'vitest';

import { PriceChartModal } from './PriceChartModal';

describe('PriceChartModal', () => {
  it('shows loading text when chart data is empty', () => {
    render(
      <PriceChartModal
        coin="bitcoin"
        data={[]}
        onClose={vi.fn()}
      />,
    );

    expect(screen.getByText('Bitcoin (BTC) — Price History')).toBeInTheDocument();
    expect(screen.getByText('Loading chart data…')).toBeInTheDocument();
  });

  it('shows the title with data and closes from button and backdrop clicks', () => {
    const onClose = vi.fn();
    const { container } = render(
      <PriceChartModal
        coin="ethereum"
        data={[
          {
            fetched_at: '2026-01-01T00:00:00Z',
            price_usd: 3200,
            change_24h: 1.2,
          },
        ]}
        onClose={onClose}
      />,
    );

    expect(screen.getByText('Ethereum (ETH) — Price History')).toBeInTheDocument();

    fireEvent.click(screen.getByRole('button'));
    expect(onClose).toHaveBeenCalledTimes(1);

    fireEvent.click(container.firstChild as HTMLElement);
    expect(onClose).toHaveBeenCalledTimes(2);
  });
});
