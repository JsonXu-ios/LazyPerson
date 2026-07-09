export type DataQuality = {
  source: string;
  from_cache: boolean;
  updated_at: string | null;
  stale: boolean;
  fallback: boolean;
  message: string;
  warnings: string[];
};

export type ApiResponse<T> = {
  data: T;
  quality?: DataQuality | null;
};

export type SymbolItem = {
  symbol: string;
  market: string;
  name: string;
  display: string;
};

export type Quote = {
  symbol: string;
  market: string;
  name: string;
  trade_time: string | null;
  price: number | null;
  open: number | null;
  high: number | null;
  low: number | null;
  pre_close: number | null;
  pct_chg: number | null;
  change: number | null;
  volume: number | null;
  amount: number | null;
  turnover: number | null;
};

export type WatchlistItem = {
  symbol: string;
  market: string;
  name: string;
  group_name: string;
  sort_order: number;
  note: string;
};

export type KlineBar = {
  time: string;
  open: number | null;
  high: number | null;
  low: number | null;
  close: number | null;
  volume: number | null;
  amount: number | null;
  pct_chg: number | null;
  turnover: number | null;
};

export type KlinePayload = {
  symbol: string;
  period: string;
  adjust: string;
  bars: KlineBar[];
  indicators: Record<string, Record<string, Array<number | null>>>;
};

export type MoneyFlowItem = {
  time: string;
  main_net_inflow: number | null;
  super_large_net_inflow: number | null;
  large_net_inflow: number | null;
  medium_net_inflow: number | null;
  small_net_inflow: number | null;
};

export type MoneyFlowPayload = {
  symbol: string;
  items: MoneyFlowItem[];
};
