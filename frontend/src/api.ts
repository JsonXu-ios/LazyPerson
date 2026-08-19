import type {
  ApiResponse,
  HotSectors,
  PopularStock,
  SectorConstituent,
  StockIndustry,
  Fundamentals,
  KlinePayload,
  MoneyFlowPayload,
  MoneyGrabStatus,
  Quote,
  SymbolItem,
  WatchlistItem,
  ZeroBaseStatus,
} from "./types";

async function request<T>(url: string, init?: RequestInit): Promise<ApiResponse<T>> {
  const response = await fetch(url, {
    headers: { "Content-Type": "application/json" },
    ...init,
  });
  if (!response.ok) {
    const detail = await response.json().catch(() => ({ detail: response.statusText }));
    const message =
      typeof detail.detail === "string"
        ? detail.detail
        : detail.detail?.message || detail.message || response.statusText;
    throw new Error(message);
  }
  return response.json();
}

export const api = {
  health: () => request<{ status: string; version: string }>("/api/health"),
  searchSymbols: (q: string) =>
    request<SymbolItem[]>(`/api/symbols/search?q=${encodeURIComponent(q)}&limit=8`),
  listWatchlist: () => request<WatchlistItem[]>("/api/watchlist"),
  addWatchlist: (symbol: string, groupName = "default") =>
    request<{ ok: boolean }>("/api/watchlist", {
      method: "POST",
      body: JSON.stringify({ symbol, group_name: groupName }),
    }),
  removeWatchlist: (symbol: string) =>
    request<{ ok: boolean }>(`/api/watchlist/${encodeURIComponent(symbol)}`, { method: "DELETE" }),
  realtimeQuotes: (symbols: string[], refresh = false) =>
    request<Quote[]>(
      `/api/quotes/realtime?symbols=${symbols.map(encodeURIComponent).join(",")}&refresh=${refresh}`,
    ),
  kline: (symbol: string, period: string, refresh = false, limit?: number) =>
    request<KlinePayload>(
      `/api/kline/${encodeURIComponent(
        symbol,
      )}?period=${period}&indicators=macd,lon&refresh=${refresh}&limit=${limit || (["day", "week", "month"].includes(period) ? 140 : 1000)}`,
    ),
  fundamentals: (symbol: string, refresh = false) =>
    request<Fundamentals>(`/api/fundamentals/${encodeURIComponent(symbol)}?refresh=${refresh}`),
  moneyFlow: (symbol: string, refresh = false) =>
    request<MoneyFlowPayload>(`/api/money-flow/${encodeURIComponent(symbol)}?refresh=${refresh}`),
  startMoneyGrabScan: (refresh = false, minMarketCap?: number, limitUpOnly = false) =>
    request<MoneyGrabStatus>(
      `/api/moneygrab/scan?refresh=${refresh}${minMarketCap != null ? `&min_market_cap=${minMarketCap}` : ""}${
        limitUpOnly ? "&limit_up=true" : ""
      }`,
      { method: "POST" },
    ),
  getMoneyGrabScanStatus: () => request<MoneyGrabStatus>("/api/moneygrab/scan/status"),
  // 零帧起手：独立于八档局的一次扫描（不套市值/涨停参数）
  startZeroBaseScan: (refresh = false) =>
    request<ZeroBaseStatus>(`/api/zero-base/scan?refresh=${refresh}`, { method: "POST" }),
  getZeroBaseScanStatus: () => request<ZeroBaseStatus>("/api/zero-base/scan/status"),
  popularStocks: (limit = 100, refresh = false) =>
    request<PopularStock[]>(`/api/popularity?limit=${limit}&refresh=${refresh}`),
  hotSectors: (limit = 20, refresh = false) =>
    request<HotSectors>(`/api/sectors/hot?limit=${limit}&refresh=${refresh}`),
  sectorConstituents: (code: string, limit = 60) =>
    request<SectorConstituent[]>(`/api/sectors/${encodeURIComponent(code)}/constituents?limit=${limit}`),
  stockIndustry: (symbol: string) =>
    request<StockIndustry>(`/api/stock/${encodeURIComponent(symbol)}/industry`),
};
