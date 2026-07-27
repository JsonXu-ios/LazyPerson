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

export type MoneyGrabHit = {
  symbol: string;
  name: string;
  price: number;
  low90: number;
  pct: number;
  group: number;
  threshold: number;
  over: number;
  max_pct: number;
  limit_up: boolean;
  low_date: string;
  cross_date: string;
};

export type MoneyGrabStatus = {
  status: "idle" | "running" | "done" | "failed";
  stage?: "snapshot" | "kline" | "";
  total: number;
  done: number;
  hits: MoneyGrabHit[];
  started_at: string | null;
  finished_at: string | null;
  error: string | null;
  trade_date: string | null;
  min_market_cap: number | null;
  limit_up_only: boolean;
};
