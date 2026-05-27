/**
 * @license
 * SPDX-License-Identifier: Apache-2.0
 */

import React, { useState, useEffect, useMemo, useRef } from 'react';
import {
  TrendingUp,
  History as HistoryIcon,
  Users,
  Activity,
  Search,
  RefreshCw,
  ChevronRight,
  ArrowUpRight,
  ArrowDownRight,
  ExternalLink,
  Filter,
  BarChart3,
  LayoutGrid,
  PieChart as PieChartIcon,
  Zap,
  ShieldAlert,
  Globe
} from 'lucide-react';
import { motion, AnimatePresence } from 'motion/react';
import {
  XAxis,
  YAxis,
  CartesianGrid,
  Tooltip,
  ResponsiveContainer,
  AreaChart,
  Area
} from 'recharts';
import { HeroCurrencyChart } from '@/src/components/HeroCurrencyChart';
import { MarketCard } from '@/src/components/MarketCard';
import { PriceChartModal } from '@/src/components/PriceChartModal';
import { PriceSummaryCard } from '@/src/components/PriceSummaryCard';
import { cn } from '@/src/lib/utils';
import {
  filterMarkets,
  formatCompactCurrency,
  getMarketCategoryLabel,
  normalizeHistoryPoint,
} from '@/src/lib/dashboard-helpers';
import { MarketSnapshot, Whale, HistoryPoint, Prices, PriceHistory } from './types';
import { PROXY_URL, HISTORY_URL, REFRESH_MS, PRICES_REFRESH_MS } from './config';

const LIVE_FETCH_OPTIONS: RequestInit = {
  cache: 'no-store',
};

function getSessionId(): string {
  const name = 'coinops_sid=';
  const cookie = document.cookie.split(';').find(c => c.trim().startsWith(name));
  if (cookie) return cookie.trim().slice(name.length);
  const id = crypto.randomUUID?.() ?? Math.random().toString(36).slice(2) + Date.now().toString(36);
  document.cookie = `coinops_sid=${id}; max-age=86400; path=/`;
  return id;
}

export default function App() {
  const [activeTab, setActiveTab] = useState<'home' | 'live' | 'history' | 'whales' | 'insights'>('home');
  const [markets, setMarkets] = useState<MarketSnapshot[]>([]);
  const [whales, setWhales] = useState<Whale[]>([]);
  const [runtimeStatus, setRuntimeStatus] = useState<{ live: boolean; backend: string }>({
    live: false,
    backend: 'unknown',
  });
  const [selectedMarket, setSelectedMarket] = useState<MarketSnapshot | null>(null);
  const [historyData, setHistoryData] = useState<HistoryPoint[]>([]);
  const [isLoading, setIsLoading] = useState(true);
  const [searchQuery, setSearchQuery] = useState('');
  const [selectedCategory, setSelectedCategory] = useState<string | null>(null);
  const [prices, setPrices] = useState<Prices | null>(null);
  const [priceHistoryData, setPriceHistoryData] = useState<PriceHistory[]>([]);
  const [homepagePriceHistory, setHomepagePriceHistory] = useState<Record<string, PriceHistory[]>>({});
  const [activePriceCoin, setActivePriceCoin] = useState<string | null>(null);
  const [timeFilter, setTimeFilter] = useState<'1H' | '4H' | '24H'>('4H');
  const [restoredMarketSlug, setRestoredMarketSlug] = useState<string | null>(null);
  const sidRef = useRef<string>('');
  const isInitialLoad = useRef<boolean>(true);

  const loadData = async (forceLoading = false) => {
    if (isInitialLoad.current || forceLoading) setIsLoading(true);
    try {
      const [marketsRes, whalesRes] = await Promise.all([
        fetch(PROXY_URL + '/current', LIVE_FETCH_OPTIONS),
        fetch(PROXY_URL + '/whales', LIVE_FETCH_OPTIONS),
      ]);
      if (marketsRes.ok) setMarkets(await marketsRes.json() as MarketSnapshot[]);
      if (whalesRes.ok) setWhales(await whalesRes.json() as Whale[]);
    } catch {
      // backend unreachable — keep existing data
    } finally {
      if (isInitialLoad.current || forceLoading) {
        setIsLoading(false);
        isInitialLoad.current = false;
      }
    }
  };

  const loadPrices = async () => {
    try {
      const res = await fetch(PROXY_URL + '/prices', LIVE_FETCH_OPTIONS);
      if (res.ok) setPrices(await res.json() as Prices);
    } catch {
      // silent fail — prices are optional
    }
  };

  const loadRuntimeStatus = async () => {
    try {
      const res = await fetch(PROXY_URL + '/health', LIVE_FETCH_OPTIONS);
      if (!res.ok) {
        setRuntimeStatus(current => ({ ...current, live: false }));
        return;
      }

      const data = await res.json() as { status?: string; runtime_backend?: string };
      setRuntimeStatus({
        live: data.status === 'ok',
        backend: data.runtime_backend || 'unknown',
      });
    } catch {
      setRuntimeStatus(current => ({ ...current, live: false }));
    }
  };

  const loadHomepagePriceHistory = async () => {
    try {
      const coins = ['usd_uah', 'bitcoin', 'ethereum'] as const;
      const results = await Promise.all(
        coins.map(async (coin) => {
          const res = await fetch(`${HISTORY_URL}/prices/history/${coin}?limit=72`, LIVE_FETCH_OPTIONS);
          if (!res.ok) return [coin, []] as const;
          const data = await res.json() as PriceHistory[];
          return [coin, data.reverse()] as const;
        })
      );
      setHomepagePriceHistory(Object.fromEntries(results));
    } catch {
      setHomepagePriceHistory({});
    }
  };

  const fetchMarketHistory = async (slug: string) => {
    try {
      const res = await fetch(`${HISTORY_URL}/history/${slug}?limit=500`, LIVE_FETCH_OPTIONS);
      if (res.ok) {
        const data = await res.json() as HistoryPoint[];
        setHistoryData(data.reverse());
      } else {
        setHistoryData([]);
      }
    } catch {
      setHistoryData([]);
    }
  };

  const fetchPriceHistory = async (coin: string, limit = 200) => {
    try {
      const res = await fetch(`${HISTORY_URL}/prices/history/${coin}?limit=${limit}`, LIVE_FETCH_OPTIONS);
      if (res.ok) {
        const data = await res.json() as PriceHistory[];
        setPriceHistoryData(data.reverse());
      }
    } catch { /* silent */ }
  };

  const openPriceChart = async (coin: string) => {
    if (coin !== activePriceCoin) {
      setPriceHistoryData([]);
      saveState(sidRef.current, activeTab, coin, selectedMarket?.slug ?? null);
    }
    setActivePriceCoin(coin);
    fetchPriceHistory(coin);
  };

  const saveState = async (sid: string, tab: string, coin: string | null = activePriceCoin, marketSlug: string | null = selectedMarket?.slug ?? null) => {
    try {
      await fetch(`${PROXY_URL}/state?sid=${sid}`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ active_tab: tab, active_price_coin: coin, active_market_slug: marketSlug }),
      });
    } catch { /* silent */ }
  };

  const restoreState = async (sid: string) => {
    try {
      const res = await fetch(`${PROXY_URL}/state?sid=${sid}`, LIVE_FETCH_OPTIONS);
      if (res.ok) {
        const state = await res.json() as { active_tab?: string, active_price_coin?: string, active_market_slug?: string };
        if (state.active_tab) setActiveTab(state.active_tab as typeof activeTab);
        if (state.active_price_coin) openPriceChart(state.active_price_coin);
        if (state.active_market_slug) setRestoredMarketSlug(state.active_market_slug);
      }
    } catch { /* silent */ }
  };

  const handleTabSwitch = (tab: typeof activeTab) => {
    setActiveTab(tab);
    saveState(sidRef.current, tab, activePriceCoin, selectedMarket?.slug ?? null);
  };

  useEffect(() => {
    sidRef.current = getSessionId();
    loadData();
    loadPrices();
    loadHomepagePriceHistory();
    loadRuntimeStatus();
    restoreState(sidRef.current);
    const marketTimer = setInterval(loadData, REFRESH_MS);
    const priceTimer = setInterval(loadPrices, PRICES_REFRESH_MS);
    const homepagePriceTimer = setInterval(loadHomepagePriceHistory, PRICES_REFRESH_MS);
    const runtimeTimer = setInterval(loadRuntimeStatus, REFRESH_MS);
    const refreshVisibleData = () => {
      if (document.visibilityState !== 'visible') return;
      loadData();
      loadPrices();
      loadHomepagePriceHistory();
      loadRuntimeStatus();
    };
    window.addEventListener('focus', refreshVisibleData);
    document.addEventListener('visibilitychange', refreshVisibleData);
    return () => {
      clearInterval(marketTimer);
      clearInterval(priceTimer);
      clearInterval(homepagePriceTimer);
      clearInterval(runtimeTimer);
      window.removeEventListener('focus', refreshVisibleData);
      document.removeEventListener('visibilitychange', refreshVisibleData);
    };
  }, []);

  useEffect(() => {
    if (!selectedMarket) return;

    const freshMarket = markets.find(market => market.slug === selectedMarket.slug);
    if (freshMarket && freshMarket.fetched_at !== selectedMarket.fetched_at) {
      setSelectedMarket(freshMarket);
    }
  }, [markets, selectedMarket]);

  useEffect(() => {
    if (activeTab !== 'history' || !selectedMarket) return;

    fetchMarketHistory(selectedMarket.slug);
    const historyTimer = setInterval(() => fetchMarketHistory(selectedMarket.slug), REFRESH_MS);
    return () => clearInterval(historyTimer);
  }, [activeTab, selectedMarket?.slug]);

  useEffect(() => {
    if (!activePriceCoin) return;

    fetchPriceHistory(activePriceCoin);
    const priceHistoryTimer = setInterval(() => fetchPriceHistory(activePriceCoin), PRICES_REFRESH_MS);
    return () => clearInterval(priceHistoryTimer);
  }, [activePriceCoin]);

  useEffect(() => {
    if (restoredMarketSlug && markets.length > 0 && !selectedMarket) {
      const market = markets.find(m => m.slug === restoredMarketSlug);
      if (market) {
        setSelectedMarket(market);
        fetchMarketHistory(market.slug);
      }
    }
  }, [restoredMarketSlug, markets, selectedMarket]);

  const chartHistoryData = useMemo(() => {
    if (!historyData.length) {
      if (!selectedMarket) return [];

      const now = Date.now();
      let windowHours = 4;
      if (timeFilter === '1H') windowHours = 1;
      if (timeFilter === '24H') windowHours = 24;

      const start = now - (windowHours * 60 * 60 * 1000);
      const midpoint = start + ((now - start) / 2);

      return [
        {
          fetched_at: new Date(start).toISOString(),
          yes_price: selectedMarket.yes_price,
          no_price: 1 - selectedMarket.yes_price,
          volume_24h: selectedMarket.volume_24h,
        },
        {
          fetched_at: new Date(midpoint).toISOString(),
          yes_price: selectedMarket.yes_price,
          no_price: 1 - selectedMarket.yes_price,
          volume_24h: selectedMarket.volume_24h,
        },
        {
          fetched_at: new Date(now).toISOString(),
          yes_price: selectedMarket.yes_price,
          no_price: 1 - selectedMarket.yes_price,
          volume_24h: selectedMarket.volume_24h,
        },
      ].map(normalizeHistoryPoint);
    }

    const latestPointTime = new Date(historyData[historyData.length - 1].fetched_at).getTime();
    let cutoffHours = 4;
    if (timeFilter === '1H') cutoffHours = 1;
    if (timeFilter === '24H') cutoffHours = 24;

    const cutoffTime = latestPointTime - (cutoffHours * 60 * 60 * 1000);
    const filteredData = historyData.filter(p => new Date(p.fetched_at).getTime() >= cutoffTime);

    return (filteredData.length > 1 ? filteredData : historyData).map(normalizeHistoryPoint);
  }, [historyData, selectedMarket, timeFilter]);

  const filteredMarkets = useMemo(() => {
    return filterMarkets(markets, searchQuery, selectedCategory);
  }, [markets, searchQuery, selectedCategory]);

  const categories = useMemo(() => {
    const cats = Array.from(new Set(markets.map(getMarketCategoryLabel)));
    return cats.sort();
  }, [markets]);

  const featuredMarkets = useMemo(() => {
    return [...filteredMarkets]
      .sort((a, b) => {
        if (b.volume_24h !== a.volume_24h) return b.volume_24h - a.volume_24h;
        return new Date(a.end_date).getTime() - new Date(b.end_date).getTime();
      })
      .slice(0, 6);
  }, [filteredMarkets]);

  const marketVolume24h = useMemo(() => {
    return filteredMarkets.reduce((sum, market) => sum + market.volume_24h, 0);
  }, [filteredMarkets]);

  const lastPriceUpdate = useMemo(() => {
    if (!prices?.fetched_at) return 'Waiting for data';
    return new Date(prices.fetched_at).toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' });
  }, [prices]);

  const runtimeBackendLabel = useMemo(() => {
    if (runtimeStatus.backend === 'postgres') return 'PostgreSQL';
    if (runtimeStatus.backend === 'external') return 'External';
    return 'Unknown';
  }, [runtimeStatus.backend]);

  const handleMarketClick = async (market: MarketSnapshot) => {
    setSelectedMarket(market);
    handleTabSwitch('history');
    saveState(sidRef.current, 'history', activePriceCoin, market.slug);
    fetchMarketHistory(market.slug);
  };

  return (
    <div className="flex h-screen bg-transparent overflow-hidden relative">
      {activePriceCoin && (
        <PriceChartModal
          coin={activePriceCoin}
          data={priceHistoryData}
          onClose={() => {
            setActivePriceCoin(null);
            saveState(sidRef.current, activeTab, null, selectedMarket?.slug ?? null);
          }}
        />
      )}
      {/* Decorative Background Elements */}
      <div className="absolute top-[-10%] left-[-10%] w-[40%] h-[40%] bg-accent/20 rounded-full blur-[120px] -z-10 animate-pulse" />
      <div className="absolute bottom-[-10%] right-[-10%] w-[40%] h-[40%] bg-purple-500/10 rounded-full blur-[120px] -z-10" />
      <div className="absolute top-[30%] right-[10%] w-[20%] h-[20%] bg-blue-500/10 rounded-full blur-[100px] -z-10" />

      {/* Sidebar */}
      <aside className="w-64 border-r border-white/10 bg-black/20 backdrop-blur-3xl flex flex-col z-20">
        <div className="p-6 flex items-center gap-3">
          <div className="w-8 h-8 bg-accent rounded-lg flex items-center justify-center shadow-lg shadow-accent/40">
            <Activity className="text-white w-5 h-5" />
          </div>
          <span className="font-bold text-xl tracking-tight bg-clip-text text-transparent bg-gradient-to-r from-white to-white/60">Coin-Ops</span>
        </div>

        <nav className="flex-1 px-4 space-y-2">
          <NavItem
            icon={<Globe size={20} />}
            label="Home"
            active={activeTab === 'home'}
            onClick={() => handleTabSwitch('home')}
          />
          <NavItem
            icon={<TrendingUp size={20} />}
            label="Live Markets"
            active={activeTab === 'live'}
            onClick={() => handleTabSwitch('live')}
          />
          <NavItem
            icon={<Users size={20} />}
            label="Whale Tracker"
            active={activeTab === 'whales'}
            onClick={() => handleTabSwitch('whales')}
          />
          <NavItem
            icon={<LayoutGrid size={20} />}
            label="Market Insights"
            active={activeTab === 'insights'}
            onClick={() => handleTabSwitch('insights')}
          />
          <NavItem
            icon={<HistoryIcon size={20} />}
            label="History"
            active={activeTab === 'history'}
            onClick={() => handleTabSwitch('history')}
          />
        </nav>

        <div className="p-4 border-t border-white/10">
          <div className="glass rounded-xl p-4 space-y-2">
            <div className="flex items-center justify-between text-xs text-muted">
              <span>Runtime Status</span>
              <div className="flex items-center gap-1.5">
                <div
                  className={cn(
                    'w-1.5 h-1.5 rounded-full shadow-[0_0_8px_rgba(34,197,94,0.6)]',
                    runtimeStatus.live ? 'bg-yes animate-pulse' : 'bg-red-400 shadow-[0_0_8px_rgba(248,113,113,0.6)]',
                  )}
                />
                <span className={runtimeStatus.live ? 'text-yes' : 'text-red-400'}>
                  {runtimeStatus.live ? 'Live' : 'Offline'}
                </span>
              </div>
            </div>
            <p className="text-[10px] text-muted leading-relaxed">
              Runtime backend: {runtimeBackendLabel}
            </p>
          </div>
        </div>
      </aside>

      {/* Main Content */}
      <main className="flex-1 flex flex-col overflow-hidden z-10">
        {/* Header */}
        <header className="h-16 border-b border-white/10 flex items-center justify-between gap-4 px-8 bg-black/10 backdrop-blur-xl sticky top-0 z-10">
          <div className="flex items-center gap-4 flex-1 min-w-0 max-w-xl">
            <div className="relative w-full">
              <Search className="absolute left-3 top-1/2 -translate-y-1/2 text-muted" size={18} />
              <input
                type="text"
                placeholder="Search markets, categories, or whales..."
                className="w-full bg-white/5 border border-white/10 rounded-lg py-2 pl-10 pr-4 text-sm focus:outline-none focus:border-accent/50 focus:bg-white/10 transition-all"
                value={searchQuery}
                onChange={(e) => setSearchQuery(e.target.value)}
              />
            </div>
          </div>

          {prices && (
            <div className="hidden lg:flex items-center gap-4 text-xs font-mono shrink-0 whitespace-nowrap">
              <button
                className="text-zinc-400 hover:text-white transition-colors cursor-pointer"
                onClick={() => openPriceChart('bitcoin')}
              >
                BTC <span className="text-white font-bold">${prices.btc_usd.toLocaleString()}</span>
                <span className={prices.btc_24h_change >= 0 ? 'text-yes ml-1' : 'text-no ml-1'}>
                  {prices.btc_24h_change >= 0 ? '+' : ''}{prices.btc_24h_change.toFixed(2)}%
                </span>
              </button>
              <button
                className="text-zinc-400 hover:text-white transition-colors cursor-pointer"
                onClick={() => openPriceChart('ethereum')}
              >
                ETH <span className="text-white font-bold">${prices.eth_usd.toLocaleString()}</span>
                <span className={prices.eth_24h_change >= 0 ? 'text-yes ml-1' : 'text-no ml-1'}>
                  {prices.eth_24h_change >= 0 ? '+' : ''}{prices.eth_24h_change.toFixed(2)}%
                </span>
              </button>
              <button
                className="text-zinc-400 hover:text-white transition-colors cursor-pointer"
                onClick={() => openPriceChart('usd_uah')}
              >
                UAH <span className="text-white font-bold">&#8372;{prices.usd_uah.toFixed(2)}</span>
              </button>
            </div>
          )}

          <div className="flex items-center gap-4 shrink-0">
            <div className="relative group">
              <button className="p-2 hover:bg-white/5 rounded-lg transition-colors text-muted flex items-center gap-2">
                <Filter size={20} />
                {selectedCategory && <span className="text-xs font-bold text-accent">{selectedCategory}</span>}
              </button>
              <div className="absolute right-0 top-full mt-2 w-48 bg-[#18181b] border border-white/10 rounded-lg shadow-xl opacity-0 invisible group-hover:opacity-100 group-hover:visible transition-all z-50">
                <button onClick={() => setSelectedCategory(null)} className="w-full text-left px-4 py-2 text-sm hover:bg-white/5 first:rounded-t-lg">All Categories</button>
                {categories.map(c => (
                  <button key={c} onClick={() => setSelectedCategory(c)} className="w-full text-left px-4 py-2 text-sm hover:bg-white/5 last:rounded-b-lg">{c}</button>
                ))}
              </div>
            </div>
            <button
              className="flex items-center gap-2 bg-accent hover:bg-accent/90 text-white px-4 py-2 rounded-lg text-sm font-medium transition-all shadow-lg shadow-accent/20"
              onClick={() => {
                loadData(true);
                loadPrices();
                loadHomepagePriceHistory();
                if (activePriceCoin) openPriceChart(activePriceCoin);
                if (selectedMarket && activeTab === 'history') fetchMarketHistory(selectedMarket.slug);
              }}
            >
              <RefreshCw size={16} className={cn(isLoading && "animate-spin")} />
              Refresh
            </button>
          </div>
        </header>

        {/* Scrollable Area */}
        <div className="flex-1 overflow-y-auto p-8 custom-scrollbar">
          <AnimatePresence mode="wait">
            {activeTab === 'home' && (
              <motion.div
                key="home"
                initial={{ opacity: 0, scale: 0.98 }}
                animate={{ opacity: 1, scale: 1 }}
                exit={{ opacity: 0, scale: 0.98 }}
                transition={{ duration: 0.3 }}
                className="space-y-8"
              >
                <div className="flex items-center justify-between">
                  <div>
                    <h1 className="text-2xl font-bold bg-clip-text text-transparent bg-gradient-to-br from-white to-white/60">Macro Snapshot</h1>
                    <p className="text-muted text-sm">UAH first, then crypto, then the busiest Polymarket setups.</p>
                  </div>
                  <div className="flex gap-2">
                    <Badge label={`Tracked: ${featuredMarkets.length}`} variant="accent" />
                    <Badge label={`Updated: ${lastPriceUpdate}`} variant="surface" />
                  </div>
                </div>

                <div className="glass rounded-[28px] p-6 md:p-8 overflow-hidden relative">
                  <div className="absolute inset-y-0 right-0 w-1/2 bg-gradient-to-l from-accent/10 to-transparent pointer-events-none" />
                  <div className="relative grid grid-cols-1 xl:grid-cols-[1.4fr_0.9fr] gap-8 items-start">
                    <div className="space-y-4">
                      <div className="flex items-center gap-2 text-[11px] uppercase tracking-[0.28em] text-accent">
                        <Globe size={14} />
                        UAH Currency
                      </div>
                      <div>
                        <p className="text-5xl md:text-6xl font-bold tracking-tight">
                          {prices ? `₴${prices.usd_uah.toFixed(2)}` : '--'}
                        </p>
                        <p className="mt-3 max-w-xl text-sm text-zinc-300 leading-relaxed">
                          Current USD to UAH reference with a short recent history curve. Use it as the anchor before checking crypto and prediction markets.
                        </p>
                      </div>
                      <div className="flex flex-wrap gap-3">
                        <button
                          onClick={() => openPriceChart('usd_uah')}
                          className="bg-accent hover:bg-accent/90 text-white px-4 py-2 rounded-lg text-sm font-medium transition-all shadow-lg shadow-accent/20"
                        >
                          Open UAH Chart
                        </button>
                        <div className="glass-dark rounded-xl px-4 py-2 text-sm text-zinc-300">
                          Last sync {lastPriceUpdate}
                        </div>
                      </div>
                    </div>

                    <HeroCurrencyChart
                      title="USD / UAH"
                      data={homepagePriceHistory.usd_uah ?? []}
                      formatter={(value) => `₴${value.toFixed(2)}`}
                    />
                  </div>
                </div>

                <div className="grid grid-cols-1 xl:grid-cols-2 gap-6">
                  <PriceSummaryCard
                    title="Bitcoin"
                    symbol="BTC"
                    price={prices?.btc_usd}
                    change={prices?.btc_24h_change}
                    data={homepagePriceHistory.bitcoin ?? []}
                    accentClassName="from-orange-500/20 via-amber-400/10 to-transparent"
                    onClick={() => openPriceChart('bitcoin')}
                  />
                  <PriceSummaryCard
                    title="Ethereum"
                    symbol="ETH"
                    price={prices?.eth_usd}
                    change={prices?.eth_24h_change}
                    data={homepagePriceHistory.ethereum ?? []}
                    accentClassName="from-sky-500/20 via-cyan-400/10 to-transparent"
                    onClick={() => openPriceChart('ethereum')}
                  />
                </div>

                <section className="space-y-5">
                  <div className="flex flex-col gap-3 md:flex-row md:items-end md:justify-between">
                    <div>
                      <h2 className="text-xl font-semibold text-white">Interesting Polymarket Markets</h2>
                      <p className="text-sm text-muted">A short list pulled from the current feed and ranked by 24h activity.</p>
                    </div>
                    <div className="flex flex-wrap gap-2">
                      <Badge label={`24h Vol: $${formatCompactCurrency(marketVolume24h)}`} variant="accent" />
                      <Badge label={`Categories: ${categories.length}`} variant="surface" />
                    </div>
                  </div>

                  <div className="grid grid-cols-1 md:grid-cols-2 xl:grid-cols-3 gap-6">
                    {isLoading ? (
                      Array.from({ length: 6 }).map((_, i) => <SkeletonCard key={i} />)
                    ) : featuredMarkets.length > 0 ? (
                      featuredMarkets.map((market) => (
                        <MarketCard
                          key={market.slug}
                          market={market}
                          onClick={() => handleMarketClick(market)}
                        />
                      ))
                    ) : (
                      <div className="glass rounded-2xl p-6 text-sm text-muted md:col-span-2 xl:col-span-3">
                        No markets match the current search or category filter.
                      </div>
                    )}
                  </div>
                </section>
              </motion.div>
            )}

            {activeTab === 'live' && (
              <motion.div
                key="live"
                initial={{ opacity: 0, scale: 0.98 }}
                animate={{ opacity: 1, scale: 1 }}
                exit={{ opacity: 0, scale: 0.98 }}
                transition={{ duration: 0.3 }}
                className="space-y-8"
              >
                <div className="flex items-center justify-between">
                  <div>
                    <h1 className="text-2xl font-bold bg-clip-text text-transparent bg-gradient-to-br from-white to-white/60">Live Markets</h1>
                    <p className="text-muted text-sm">Full real-time prediction market feed from Polymarket.</p>
                  </div>
                  <div className="flex gap-2">
                    <Badge label={`Results: ${filteredMarkets.length}`} variant="accent" />
                    <Badge label={`Categories: ${categories.length}`} variant="surface" />
                  </div>
                </div>

                <div className="grid grid-cols-1 md:grid-cols-2 xl:grid-cols-3 gap-6">
                  {isLoading ? (
                    Array.from({ length: 6 }).map((_, i) => <SkeletonCard key={i} />)
                  ) : filteredMarkets.length > 0 ? (
                    filteredMarkets.map((market) => (
                      <MarketCard
                        key={market.slug}
                        market={market}
                        onClick={() => handleMarketClick(market)}
                      />
                    ))
                  ) : (
                    <div className="glass rounded-2xl p-6 text-sm text-muted md:col-span-2 xl:col-span-3">
                      No markets match the current search or category filter.
                    </div>
                  )}
                </div>
              </motion.div>
            )}

            {activeTab === 'whales' && (
              <motion.div
                key="whales"
                initial={{ opacity: 0, scale: 0.98 }}
                animate={{ opacity: 1, scale: 1 }}
                exit={{ opacity: 0, scale: 0.98 }}
                transition={{ duration: 0.3 }}
                className="space-y-8"
              >
                <div>
                  <h1 className="text-2xl font-bold bg-clip-text text-transparent bg-gradient-to-br from-white to-white/60">Whale Tracker</h1>
                  <p className="text-muted text-sm">Monitoring the largest positions and PnL leaders</p>
                </div>

                <div className="space-y-4">
                  {whales.map((whale) => (
                    <WhaleRow key={whale.address} whale={whale} />
                  ))}
                </div>
              </motion.div>
            )}

            {activeTab === 'insights' && (
              <motion.div
                key="insights"
                initial={{ opacity: 0, scale: 0.98 }}
                animate={{ opacity: 1, scale: 1 }}
                exit={{ opacity: 0, scale: 0.98 }}
                transition={{ duration: 0.3 }}
                className="space-y-8"
              >
                <div>
                  <h1 className="text-2xl font-bold bg-clip-text text-transparent bg-gradient-to-br from-white to-white/60">Market Insights</h1>
                  <p className="text-muted text-sm">Bento-style analysis of current market trends and sentiment</p>
                </div>

                <div className="grid grid-cols-1 md:grid-cols-4 md:grid-rows-3 gap-4 h-[800px]">
                  {/* Bento Item 1: Sentiment Analysis */}
                  <div className="md:col-span-2 md:row-span-2 glass rounded-3xl p-6 flex flex-col">
                    <div className="flex items-center justify-between mb-6">
                      <h3 className="text-lg font-semibold flex items-center gap-2">
                        <Zap className="text-yellow-400" size={20} />
                        Sentiment Analysis
                      </h3>
                      <Badge label="Bullish" variant="accent" />
                    </div>
                    <div className="flex-1 flex items-center justify-center">
                      <div className="relative w-48 h-48">
                        <svg className="w-full h-full" viewBox="0 0 100 100">
                          <circle cx="50" cy="50" r="45" fill="none" stroke="rgba(255,255,255,0.05)" strokeWidth="10" />
                          <circle cx="50" cy="50" r="45" fill="none" stroke="#6366f1" strokeWidth="10" strokeDasharray="282.7" strokeDashoffset="70" strokeLinecap="round" className="transition-all duration-1000" />
                        </svg>
                        <div className="absolute inset-0 flex flex-col items-center justify-center">
                          <span className="text-4xl font-bold">75%</span>
                          <span className="text-[10px] text-muted uppercase tracking-widest">Positive</span>
                        </div>
                      </div>
                    </div>
                    <p className="text-xs text-muted mt-4 text-center leading-relaxed">
                      Social sentiment across major platforms indicates a strong bullish trend for upcoming crypto-related markets.
                    </p>
                  </div>

                  {/* Bento Item 2: Volume Spikes */}
                  <div className="md:col-span-2 md:row-span-1 glass rounded-3xl p-6">
                    <div className="flex items-center justify-between mb-4">
                      <h3 className="text-sm font-semibold flex items-center gap-2">
                        <TrendingUp className="text-yes" size={18} />
                        Volume Spikes
                      </h3>
                    </div>
                    <div className="space-y-3">
                      <div className="flex items-center justify-between text-xs">
                        <span className="text-zinc-400">BTC $100k Market</span>
                        <span className="text-yes font-bold">+450%</span>
                      </div>
                      <div className="h-1.5 bg-white/5 rounded-full overflow-hidden">
                        <div className="h-full bg-yes w-[85%]" />
                      </div>
                      <div className="flex items-center justify-between text-xs">
                        <span className="text-zinc-400">US Election Market</span>
                        <span className="text-zinc-500 font-bold">+120%</span>
                      </div>
                      <div className="h-1.5 bg-white/5 rounded-full overflow-hidden">
                        <div className="h-full bg-zinc-600 w-[40%]" />
                      </div>
                    </div>
                  </div>

                  {/* Bento Item 3: Risk Assessment */}
                  <div className="md:col-span-1 md:row-span-1 glass rounded-3xl p-6 flex flex-col justify-between">
                    <ShieldAlert className="text-no mb-2" size={24} />
                    <div>
                      <h3 className="text-sm font-semibold mb-1">Risk Level</h3>
                      <p className="text-2xl font-bold text-no">Moderate</p>
                    </div>
                    <p className="text-[10px] text-muted">Volatility index is currently at 42.5</p>
                  </div>

                  {/* Bento Item 4: Global Reach */}
                  <div className="md:col-span-1 md:row-span-1 glass rounded-3xl p-6 flex flex-col justify-between">
                    <Globe className="text-blue-400 mb-2" size={24} />
                    <div>
                      <h3 className="text-sm font-semibold mb-1">Active Regions</h3>
                      <p className="text-2xl font-bold">142</p>
                    </div>
                    <p className="text-[10px] text-muted">Top region: North America</p>
                  </div>

                  {/* Bento Item 5: Market Dominance */}
                  <div className="md:col-span-2 md:row-span-1 glass rounded-3xl p-6 flex items-center gap-6">
                    <div className="w-24 h-24 flex-shrink-0">
                      <PieChartIcon className="w-full h-full text-accent opacity-50" />
                    </div>
                    <div className="flex-1">
                      <h3 className="text-sm font-semibold mb-3">Category Dominance</h3>
                      <div className="flex flex-wrap gap-2">
                        <span className="px-2 py-1 bg-white/5 rounded text-[10px] text-zinc-300">Crypto 45%</span>
                        <span className="px-2 py-1 bg-white/5 rounded text-[10px] text-zinc-300">Politics 30%</span>
                        <span className="px-2 py-1 bg-white/5 rounded text-[10px] text-zinc-300">Sports 15%</span>
                        <span className="px-2 py-1 bg-white/5 rounded text-[10px] text-zinc-300">Other 10%</span>
                      </div>
                    </div>
                  </div>

                  {/* Bento Item 6: Quick Stats */}
                  <div className="md:col-span-2 md:row-span-1 glass rounded-3xl p-6 grid grid-cols-2 gap-4">
                    <div className="space-y-1">
                      <p className="text-[10px] text-muted uppercase tracking-widest">Total Liquidity</p>
                      <p className="text-xl font-bold">$42.8M</p>
                    </div>
                    <div className="space-y-1">
                      <p className="text-[10px] text-muted uppercase tracking-widest">New Users</p>
                      <p className="text-xl font-bold">+1.2K</p>
                    </div>
                    <div className="space-y-1">
                      <p className="text-[10px] text-muted uppercase tracking-widest">Avg Trade</p>
                      <p className="text-xl font-bold">$450</p>
                    </div>
                    <div className="space-y-1">
                      <p className="text-[10px] text-muted uppercase tracking-widest">Uptime</p>
                      <p className="text-xl font-bold text-yes">99.9%</p>
                    </div>
                  </div>
                </div>
              </motion.div>
            )}

            {activeTab === 'history' && (
              <motion.div
                key="history"
                initial={{ opacity: 0, scale: 0.98 }}
                animate={{ opacity: 1, scale: 1 }}
                exit={{ opacity: 0, scale: 0.98 }}
                transition={{ duration: 0.3 }}
                className="space-y-8"
              >
                <div className="flex items-center justify-between">
                  <div>
                    <h1 className="text-2xl font-bold bg-clip-text text-transparent bg-gradient-to-br from-white to-white/60">Market History</h1>
                    <p className="text-muted text-sm">
                      {selectedMarket ? selectedMarket.question : "Select a market to view historical trends"}
                    </p>
                  </div>
                  <div className="flex items-center gap-4">
                    {selectedMarket && (
                      <div className="flex bg-white/5 rounded-lg p-1 border border-white/10">
                        {(['1H', '4H', '24H'] as const).map((l) => (
                          <button
                            key={l}
                            onClick={() => setTimeFilter(l)}
                            className={cn(
                              "px-3 py-1 text-[10px] font-bold rounded-md transition-all",
                              timeFilter === l ? "bg-accent text-white shadow-sm" : "text-muted hover:text-white"
                            )}
                          >
                            {l}
                          </button>
                        ))}
                      </div>
                    )}
                    {selectedMarket && (
                      <button
                        onClick={() => handleTabSwitch('live')}
                        className="text-accent text-sm font-medium hover:underline flex items-center gap-1"
                      >
                        Back to Markets <ChevronRight size={16} />
                      </button>
                    )}
                  </div>
                </div>

                {selectedMarket ? (
                  <div className="space-y-6">
                    <div className="grid grid-cols-1 lg:grid-cols-3 gap-6">
                      <StatCard
                        label="Current Price"
                        value={`${(selectedMarket.yes_price * 100).toFixed(1)}%`}
                        subValue="YES Outcome"
                        trend="up"
                      />
                      <StatCard
                        label="24h Volume"
                        value={`$${(selectedMarket.volume_24h / 1000).toFixed(1)}K`}
                        subValue="+12.4% from yesterday"
                        trend="up"
                      />
                      <StatCard
                        label="End Date"
                        value={new Date(selectedMarket.end_date).toLocaleDateString()}
                        subValue="Time remaining: 24 days"
                      />
                    </div>

                    <div className="glass rounded-2xl p-6">
                      <h3 className="text-sm font-semibold text-muted mb-6 uppercase tracking-wider">Price Probability Trend</h3>
                      {historyData.length === 0 && selectedMarket ? (
                        <p className="text-xs text-muted mb-4">
                          History API has no stored points for this market yet. Showing the current snapshot as a flat fallback line.
                        </p>
                      ) : null}
                      {chartHistoryData.length === 0 ? (
                        <div className="h-[320px] flex items-center justify-center text-sm text-muted">
                          No history points available for this market yet.
                        </div>
                      ) : (
                        <div className="h-[320px] pt-2">
                        <ResponsiveContainer width="100%" height="100%">
                          <AreaChart data={chartHistoryData} margin={{ top: 12, right: 12, bottom: 8, left: 8 }}>
                            <defs>
                              <linearGradient id="colorYes" x1="0" y1="0" x2="0" y2="1">
                                <stop offset="5%" stopColor="#22c55e" stopOpacity={0.3}/>
                                <stop offset="95%" stopColor="#22c55e" stopOpacity={0}/>
                              </linearGradient>
                            </defs>
                            <CartesianGrid strokeDasharray="3 3" stroke="rgba(255,255,255,0.05)" vertical={false} />
                            <XAxis
                              dataKey="fetched_at"
                              minTickGap={30}
                              tickMargin={8}
                              tickFormatter={(str) => new Date(str).toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' })}
                              stroke="#52525b"
                              fontSize={12}
                              tickLine={false}
                              axisLine={false}
                            />
                            <YAxis
                              stroke="#52525b"
                              fontSize={12}
                              tickLine={false}
                              axisLine={false}
                              domain={[0, 1]}
                              ticks={[0, 0.25, 0.5, 0.75, 1]}
                              tickFormatter={(val) => `${(val * 100).toFixed(0)}%`}
                              width={40}
                            />
                            <Tooltip
                              isAnimationActive={false}
                              contentStyle={{ backgroundColor: 'rgba(24, 24, 27, 0.8)', backdropFilter: 'blur(12px)', border: '1px solid rgba(255,255,255,0.1)', borderRadius: '12px' }}
                              itemStyle={{ fontSize: '12px' }}
                              labelStyle={{ color: '#a1a1aa', marginBottom: '4px' }}
                              labelFormatter={(label) => new Date(label).toLocaleString()}
                            />
                            <Area
                              isAnimationActive={false}
                              activeDot={{ r: 4 }}
                              type="monotone"
                              dataKey="yes_price"
                              stroke="#22c55e"
                              strokeWidth={2}
                              fillOpacity={1}
                              fill="url(#colorYes)"
                              name="YES Price"
                            />
                          </AreaChart>
                        </ResponsiveContainer>
                        </div>
                      )}
                    </div>
                  </div>
                ) : (
                  <div className="flex flex-col items-center justify-center py-20 text-center space-y-4">
                    <div className="w-16 h-16 bg-white/5 rounded-full flex items-center justify-center text-muted">
                      <BarChart3 size={32} />
                    </div>
                    <div>
                      <h3 className="text-lg font-medium">No Market Selected</h3>
                      <p className="text-muted max-w-xs">Select a market from the Live tab to analyze its historical performance and trends.</p>
                    </div>
                    <button
                      onClick={() => handleTabSwitch('live')}
                      className="bg-accent text-white px-6 py-2 rounded-lg font-medium shadow-lg shadow-accent/20"
                    >
                      Browse Markets
                    </button>
                  </div>
                )}
              </motion.div>
            )}
          </AnimatePresence>
        </div>
      </main>
    </div>
  );
}

function NavItem({ icon, label, active, onClick }: { icon: React.ReactNode, label: string, active: boolean, onClick: () => void }) {
  return (
    <button
      onClick={onClick}
      className={cn(
        "w-full flex items-center gap-3 px-4 py-3 rounded-xl transition-all duration-200 group",
        active
          ? "bg-accent text-white shadow-lg shadow-accent/20"
          : "text-muted hover:bg-surface hover:text-zinc-100"
      )}
    >
      <span className={cn("transition-transform duration-200", active ? "scale-110" : "group-hover:scale-110")}>
        {icon}
      </span>
      <span className="font-medium text-sm">{label}</span>
      {active && (
        <motion.div
          layoutId="active-pill"
          className="ml-auto w-1.5 h-1.5 rounded-full bg-white"
        />
      )}
    </button>
  );
}

interface WhaleRowProps {
  key?: React.Key;
  whale: Whale;
}

function WhaleRow({ whale }: WhaleRowProps) {
  const isProfit = whale.pnl >= 0;

  return (
    <div className="glass rounded-2xl p-5 hover:bg-surface transition-colors">
      <div className="flex flex-wrap items-center justify-between gap-4">
        <div className="flex items-center gap-4">
          <div className="w-10 h-10 rounded-full bg-zinc-800 flex items-center justify-center text-accent font-bold">
            {whale.rank}
          </div>
          <div>
            <h4 className="font-semibold">{whale.pseudonym}</h4>
            <p className="text-xs text-muted font-mono">{whale.address}</p>
          </div>
        </div>

        <div className="flex items-center gap-8">
          <div className="text-right">
            <p className="text-[10px] text-muted uppercase tracking-wider mb-1">PnL (Monthly)</p>
            <div className={cn("flex items-center gap-1 font-bold", isProfit ? "text-yes" : "text-no")}>
              {isProfit ? <ArrowUpRight size={16} /> : <ArrowDownRight size={16} />}
              ${Math.abs(whale.pnl / 1000).toFixed(1)}K
            </div>
          </div>
          <div className="text-right">
            <p className="text-[10px] text-muted uppercase tracking-wider mb-1">Total Volume</p>
            <p className="font-bold">${(whale.volume / 1000000).toFixed(1)}M</p>
          </div>
          <a href={`https://polymarket.com/profile/${whale.address}`} target="_blank" rel="noreferrer" className="p-2 hover:bg-zinc-800 rounded-lg transition-colors text-muted flex items-center">
            <ExternalLink size={18} />
          </a>
        </div>
      </div>

      <div className="mt-4 grid grid-cols-1 md:grid-cols-2 gap-3">
        {whale.positions.map((pos, i) => (
          <div key={i} className="bg-bg/50 border border-border/50 rounded-xl p-3 flex items-center justify-between">
            <div className="flex items-center gap-3">
              <div className={cn(
                "px-2 py-1 rounded text-[10px] font-bold",
                pos.outcome === 'YES' ? "bg-yes/10 text-yes" : "bg-no/10 text-no"
              )}>
                {pos.outcome}
              </div>
              <span className="text-xs font-medium truncate max-w-[150px]">{pos.market}</span>
            </div>
            <div className="text-right">
              <p className="text-[10px] font-bold">${(pos.current_value / 1000).toFixed(1)}K</p>
              <p className="text-[8px] text-muted">Avg: {(pos.avg_price * 100).toFixed(1)}&#162;</p>
            </div>
          </div>
        ))}
      </div>
    </div>
  );
}

function StatCard({ label, value, subValue, trend }: { label: string, value: string, subValue: string, trend?: 'up' | 'down' }) {
  return (
    <div className="glass rounded-2xl p-6">
      <p className="text-xs text-muted uppercase tracking-widest mb-2">{label}</p>
      <div className="flex items-end gap-2 mb-1">
        <span className="text-3xl font-bold">{value}</span>
        {trend && (
          <span className={cn("text-xs font-bold mb-1 flex items-center", trend === 'up' ? "text-yes" : "text-no")}>
            {trend === 'up' ? <ArrowUpRight size={14} /> : <ArrowDownRight size={14} />}
            12%
          </span>
        )}
      </div>
      <p className="text-xs text-muted">{subValue}</p>
    </div>
  );
}

function Badge({ label, variant }: { label: string, variant: 'accent' | 'surface' }) {
  return (
    <span className={cn(
      "px-3 py-1 rounded-full text-[10px] font-bold tracking-wide",
      variant === 'accent' ? "bg-accent/20 text-accent border border-accent/20" : "bg-surface text-muted border border-border"
    )}>
      {label}
    </span>
  );
}

function SkeletonCard() {
  return (
    <div className="glass rounded-2xl p-5 animate-pulse">
      <div className="flex justify-between mb-4">
        <div className="w-16 h-4 bg-zinc-800 rounded" />
        <div className="w-12 h-4 bg-zinc-800 rounded" />
      </div>
      <div className="w-full h-4 bg-zinc-800 rounded mb-2" />
      <div className="w-2/3 h-4 bg-zinc-800 rounded mb-6" />
      <div className="space-y-4">
        <div className="flex justify-between">
          <div className="w-10 h-3 bg-zinc-800 rounded" />
          <div className="w-10 h-3 bg-zinc-800 rounded" />
        </div>
        <div className="w-full h-2 bg-zinc-800 rounded" />
      </div>
    </div>
  );
}
