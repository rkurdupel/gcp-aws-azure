import type { Key } from 'react';
import { ChevronRight, Activity } from 'lucide-react';
import { motion } from 'motion/react';

import { getMarketCategoryLabel } from '@/src/lib/dashboard-helpers';
import type { MarketSnapshot } from '@/src/types';

interface MarketCardProps {
  key?: Key;
  market: MarketSnapshot;
  onClick: () => void;
}

export function MarketCard({ market, onClick }: MarketCardProps) {
  const categoryLabel = getMarketCategoryLabel(market);
  const yesPct = (market.yes_price * 100).toFixed(1);
  const noPct = (market.no_price * 100).toFixed(1);

  return (
    <motion.div
      whileHover={{ y: -4 }}
      onClick={onClick}
      className="glass rounded-2xl p-5 cursor-pointer group transition-all hover:border-accent/50"
    >
      <div className="flex items-start justify-between mb-4">
        <span className="text-[10px] font-bold uppercase tracking-widest text-accent bg-accent/10 px-2 py-0.5 rounded">
          {categoryLabel}
        </span>
        <div className="flex items-center gap-1 text-muted text-[10px]">
          <Activity size={12} />
          <span>{Math.floor(market.volume_24h / 1000)}K Vol</span>
        </div>
      </div>

      <h3 className="text-sm font-medium leading-relaxed mb-6 group-hover:text-accent transition-colors line-clamp-2 h-10">
        {market.question}
      </h3>

      <div className="space-y-4">
        <div className="flex items-center justify-between text-xs mb-1">
          <span className="text-yes font-semibold">YES {yesPct}%</span>
          <span className="text-no font-semibold">NO {noPct}%</span>
        </div>

        <div className="h-2 bg-zinc-800 rounded-full overflow-hidden flex">
          <motion.div
            initial={{ width: 0 }}
            animate={{ width: `${yesPct}%` }}
            className="h-full bg-yes"
          />
          <motion.div
            initial={{ width: 0 }}
            animate={{ width: `${noPct}%` }}
            className="h-full bg-no"
          />
        </div>

        <div className="flex items-center justify-between pt-2 border-t border-border/50">
          <div className="text-[10px] text-muted">
            Ends {new Date(market.end_date).toLocaleDateString()}
          </div>
          <div className="flex items-center gap-1 text-accent text-[10px] font-bold">
            ANALYZE <ChevronRight size={12} />
          </div>
        </div>
      </div>
    </motion.div>
  );
}
