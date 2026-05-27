import {
  XAxis,
  YAxis,
  CartesianGrid,
  Tooltip,
  ResponsiveContainer,
  AreaChart,
  Area,
} from 'recharts';

import type { PriceHistory } from '@/src/types';

const COIN_LABELS: Record<string, string> = {
  bitcoin: 'Bitcoin (BTC)',
  ethereum: 'Ethereum (ETH)',
  usd_uah: 'USD / UAH',
};

interface PriceChartModalProps {
  coin: string;
  data: PriceHistory[];
  onClose: () => void;
}

export function PriceChartModal({ coin, data, onClose }: PriceChartModalProps) {
  const label = COIN_LABELS[coin] ?? coin;
  const isUAH = coin === 'usd_uah';
  const chartData = data.map((point) => ({
    time: new Date(point.fetched_at).toLocaleString([], { month: 'numeric', day: 'numeric', hour: '2-digit', minute: '2-digit' }),
    price: point.price_usd,
  }));

  return (
    <div
      className="fixed inset-0 z-50 flex items-center justify-center bg-black/60 backdrop-blur-sm"
      onClick={onClose}
    >
      <div
        className="glass rounded-2xl p-6 w-full max-w-2xl mx-4"
        onClick={(event) => event.stopPropagation()}
      >
        <div className="flex items-center justify-between mb-6">
          <h2 className="text-lg font-bold">{label} — Price History</h2>
          <button
            className="text-muted hover:text-white transition-colors text-lg leading-none"
            onClick={onClose}
          >
            ✕
          </button>
        </div>

        {data.length === 0 ? (
          <div className="h-48 flex items-center justify-center text-muted text-sm">
            Loading chart data…
          </div>
        ) : (
          <ResponsiveContainer width="100%" height={260}>
            <AreaChart data={chartData} margin={{ top: 4, right: 4, bottom: 20, left: 4 }}>
              <defs>
                <linearGradient id="priceGrad" x1="0" y1="0" x2="0" y2="1">
                  <stop offset="5%" stopColor="#6366f1" stopOpacity={0.3} />
                  <stop offset="95%" stopColor="#6366f1" stopOpacity={0} />
                </linearGradient>
              </defs>
              <CartesianGrid strokeDasharray="3 3" stroke="rgba(255,255,255,0.05)" />
              <XAxis dataKey="time" minTickGap={30} tickMargin={10} tick={{ fontSize: 10, fill: '#71717a' }} tickLine={false} axisLine={false} />
              <YAxis
                domain={['auto', 'auto']}
                tick={{ fontSize: 10, fill: '#71717a' }}
                tickLine={false}
                axisLine={false}
                tickFormatter={(value: number) => isUAH ? `₴${value.toFixed(1)}` : `$${value.toLocaleString()}`}
                width={isUAH ? 50 : 70}
              />
              <Tooltip
                isAnimationActive={false}
                contentStyle={{ background: '#0f0f0f', border: '1px solid rgba(255,255,255,0.1)', borderRadius: 8, fontSize: 12 }}
                formatter={(value: number) => [isUAH ? `₴${value.toFixed(2)}` : `$${value.toLocaleString()}`, 'Price']}
              />
              <Area isAnimationActive={false} activeDot={{ r: 4 }} type="monotone" dataKey="price" stroke="#6366f1" strokeWidth={2} fill="url(#priceGrad)" dot={false} />
            </AreaChart>
          </ResponsiveContainer>
        )}
      </div>
    </div>
  );
}
