import {
  XAxis,
  YAxis,
  CartesianGrid,
  Tooltip,
  ResponsiveContainer,
  AreaChart,
  Area,
} from 'recharts';

import { formatChartTime } from '@/src/lib/dashboard-helpers';
import type { PriceHistory } from '@/src/types';

interface HeroCurrencyChartProps {
  title: string;
  data: PriceHistory[];
  formatter: (value: number) => string;
}

export function HeroCurrencyChart({
  title,
  data,
  formatter,
}: HeroCurrencyChartProps) {
  const chartData = data.map((point) => ({
    time: point.fetched_at,
    price: point.price_usd,
  }));

  return (
    <div className="glass-dark rounded-[24px] p-5 min-h-[320px]">
      <div className="flex items-center justify-between mb-5">
        <div>
          <p className="text-xs uppercase tracking-[0.24em] text-muted">Trend</p>
          <h2 className="text-lg font-semibold mt-1">{title}</h2>
        </div>
        <div className="text-right text-xs text-muted">
          <p>{data.length > 0 ? `${data.length} points` : 'No points yet'}</p>
        </div>
      </div>

      {chartData.length === 0 ? (
        <div className="h-[240px] flex items-center justify-center text-sm text-muted">
          Waiting for price history.
        </div>
      ) : (
        <ResponsiveContainer width="100%" height={240}>
          <AreaChart data={chartData} margin={{ top: 10, right: 4, bottom: 20, left: 0 }}>
            <defs>
              <linearGradient id="heroCurrencyGradient" x1="0" y1="0" x2="0" y2="1">
                <stop offset="5%" stopColor="#6366f1" stopOpacity={0.35} />
                <stop offset="95%" stopColor="#6366f1" stopOpacity={0.02} />
              </linearGradient>
            </defs>
            <CartesianGrid strokeDasharray="3 3" stroke="rgba(255,255,255,0.06)" vertical={false} />
            <XAxis
              dataKey="time"
              minTickGap={28}
              tickMargin={10}
              tickFormatter={formatChartTime}
              tick={{ fontSize: 11, fill: '#71717a' }}
              tickLine={false}
              axisLine={false}
            />
            <YAxis
              domain={['auto', 'auto']}
              tickFormatter={(value: number) => formatter(value)}
              tick={{ fontSize: 11, fill: '#71717a' }}
              tickLine={false}
              axisLine={false}
              width={62}
            />
            <Tooltip
              isAnimationActive={false}
              labelFormatter={(label) => new Date(label).toLocaleString()}
              formatter={(value: number) => [formatter(value), title]}
              contentStyle={{
                backgroundColor: 'rgba(24, 24, 27, 0.92)',
                border: '1px solid rgba(255,255,255,0.08)',
                borderRadius: '12px',
              }}
            />
            <Area
              isAnimationActive={false}
              activeDot={{ r: 4 }}
              type="monotone"
              dataKey="price"
              stroke="#818cf8"
              strokeWidth={2}
              fill="url(#heroCurrencyGradient)"
            />
          </AreaChart>
        </ResponsiveContainer>
      )}
    </div>
  );
}
