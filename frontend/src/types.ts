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
  /** 从顶部下来：波段峰值曾站上某条主线，现价已跌破 */
  from_top: boolean;
  /** 近一年有分红（含已公告的今年分红） */
  dividend_recent?: boolean;
  /** 最新报告期归母净利润≥0 */
  profit_ok?: boolean;
  /** 估市值：最新报告期年化营收×10 > 总市值 */
  revenue_ok?: boolean;
  /** 估市值倍数 = 年化营收×10 ÷ 总市值 */
  revenue_ratio?: number | null;
  /** 日/周/月三周期 lon、lonma 整体向上且 lonma 不压在 lon 上方 */
  lon_ok?: boolean;
  /** 一路北上：90日整体向上，低点在窗口前1/3、最高点在后1/3 */
  north_ok?: boolean;
  /** 证监会行业分类 */
  industry?: string;
  /** 所属概念板块（最多6个） */
  concepts?: string[];
  /** 所属概念中有今日涨幅前列的热点板块 */
  hot_sector?: boolean;
  /** 当日换手率% */
  turnover?: number | null;
  /** 近3日涨幅% */
  chg3?: number | null;
  /** 近5日涨幅% */
  chg5?: number | null;

};

export type FundamentalValuation = {
  price?: number | null;
  /** 市盈率（动态） */
  pe?: number | null;
  pe_ttm?: number | null;
  pb?: number | null;
  /** 总市值（元） */
  market_cap?: number | null;
  float_market_cap?: number | null;
};

export type FundamentalReport = {
  report_date: string;
  /** 例："2025年 年报" */
  report_type: string;
  notice_date: string;
  eps: number | null;
  deduct_eps: number | null;
  bps: number | null;
  revenue: number | null;
  revenue_yoy: number | null;
  parent_netprofit: number | null;
  parent_netprofit_yoy: number | null;
  deduct_parent_netprofit: number | null;
  /** 净利润（含少数股东）= 利润总额 - 所得税 */
  netprofit: number | null;
  total_profit: number | null;
  income_tax: number | null;
  roe: number | null;
  gross_margin: number | null;
  operating_cashflow_ps: number | null;
};

export type FundamentalDividend = {
  report_date: string;
  plan: string;
  progress: string;
  /** 每 10 股税前派息（元） */
  pretax_bonus: number | null;
  bonus_ratio: number | null;
  it_ratio: number | null;
  /** 股息率（小数） */
  dividend_ratio: number | null;
  plan_notice_date: string;
  equity_record_date: string;
  ex_dividend_date: string;
};

export type Fundamentals = {
  symbol: string;
  name: string;
  valuation: FundamentalValuation;
  reports: FundamentalReport[];
  dividends: FundamentalDividend[];
  warnings: string[];
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

export type SectorBoard = {
  code: string;
  name: string;
  pct_chg: number | null;
  amount: number | null;
  up_count: number | null;
  down_count: number | null;
  leader: string;
  leader_pct: number | null;
  kind: "industry" | "concept";
  source: string;
};

export type HotSectors = {
  industries: SectorBoard[];
  concepts: SectorBoard[];
};

export type SectorConstituent = {
  symbol: string;
  name: string;
  price: number | null;
  pct_chg: number | null;
  amount: number | null;
  market_cap: number | null;
};

export type StockIndustry = {
  symbol: string;
  industry: string;
  concepts: string[];
};
