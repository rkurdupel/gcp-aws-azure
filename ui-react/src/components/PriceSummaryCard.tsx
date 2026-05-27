import { ChevronRight } from 'lucide-react';
import {
  XAxis,
  YAxis,
  Tooltip,
  ResponsiveContainer,
  AreaChart,
  Area,
} from 'recharts';

import { cn } from '@/src/lib/utils';
import type { PriceHistory } from '@/src/types';

interface PriceSummaryCardProps {
  title: string;
  symbol: string;
  price?: number;
  change?: number;
  data: PriceHistory[];
  accentClassName: string;
  onClick: () => void;
}

export function PriceSummaryCard({
  title,
  symbol,
  price,
  change,
  data,
  accentClassName,
  onClick,
}: PriceSummaryCardProps) {
  const isPositive = (change ?? 0) >= 0;
  const chartData = data.map((point) => ({
    time: point.fetched_at,
    price: point.price_usd,
  }));
  const latestHistoryPrice = data.length > 0 ? data[data.length - 1].price_usd : undefined;
  const displayPrice = typeof price === 'number' && price > 0 ? price : latestHistoryPrice;

  return (
    <button
      onClick={onClick}
      className="glass rounded-[24px] p-6 text-left overflow-hidden relative group hover:border-accent/40 transition-all"
    >
      <div className={cn("absolute inset-0 bg-gradient-to-br opacity-100", accentClassName)} />
      <div className="relative space-y-5">
        <div className="flex items-start justify-between gap-4">
          <div>
            <p className="text-[11px] uppercase tracking-[0.24em] text-muted">{symbol}</p>
            <h3 className="text-2xl font-semibold mt-2">{title}</h3>
          </div>
          <ChevronRight size={18} className="text-muted group-hover:text-white transition-colors" />
        </div>

        <div className="flex items-end justify-between gap-4">
          <div>
            <p className="text-4xl font-bold tracking-tight">
              {typeof displayPrice === 'number' ? `$${displayPrice.toLocaleString()}` : '--'}
            </p>
            <p className={cn("mt-2 text-sm font-medium", isPositive ? "text-yes" : "text-no")}>
              {typeof change === 'number' ? `${isPositive ? '+' : ''}${change.toFixed(2)}% 24h` : 'No change data'}
            </p>
          </div>
          <div className="text-right text-xs text-zinc-300">
            <p>Tap for full chart</p>
          </div>
        </div>

        <div className="h-32">
          {chartData.length === 0 ? (
            <div className="h-full flex items-center justify-center text-sm text-muted">
              Waiting for price history.
            </div>
          ) : (
            <ResponsiveContainer width="100%" height="100%">
              <AreaChart data={chartData} margin={{ top: 8, right: 0, bottom: 4, left: 0 }}>
                <defs>
                  <linearGradient id={`priceCardGradient-${symbol}`} x1="0" y1="0" x2="0" y2="1">
                    <stop offset="5%" stopColor={isPositive ? '#22c55e' : '#ef4444'} stopOpacity={0.25} />
                    <stop offset="95%" stopColor={isPositive ? '#22c55e' : '#ef4444'} stopOpacity={0.02} />
                  </linearGradient>
                </defs>
                <XAxis hide dataKey="time" />
                <YAxis hide domain={['auto', 'auto']} />
                <Tooltip
                  isAnimationActive={false}
                  labelFormatter={(label) => new Date(label).toLocaleString()}
                  formatter={(value: number) => [`$${value.toLocaleString()}`, title]}
                  contentStyle={{
                    backgroundColor: 'rgba(24, 24, 27, 0.92)',
                    border: '1px solid rgba(255,255,255,0.08)',
                    borderRadius: '12px',
                  }}
                />
                <Area
                  isAnimationActive={false}
                  activeDot={{ r: 3 }}
                  type="monotone"
                  dataKey="price"
                  stroke={isPositive ? '#22c55e' : '#ef4444'}
                  strokeWidth={2}
                  fill={`url(#priceCardGradient-${symbol})`}
                />
              </AreaChart>
            </ResponsiveContainer>
          )}
        </div>
      </div>
    </button>
  );
}
