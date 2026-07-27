import type {
  ApiResponse,
  KlinePayload,
  MoneyFlowPayload,
  MoneyGrabStatus,
  Quote,
  SymbolItem,
  WatchlistItem,
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
      )}?period=${period}&indicators=macd,lon&refresh=${refresh}&limit=${limit || (period === "day" ? 140 : 1000)}`,
    ),
  moneyFlow: (symbol: string, refresh = false) =>
    request<MoneyFlowPayload>(`/api/money-flow/${encodeURIComponent(symbol)}?refresh=${refresh}`),
  startMoneyGrabScan: (refresh = false, minMarketCap?: number) =>
    request<MoneyGrabStatus>(
      `/api/moneygrab/scan?refresh=${refresh}${minMarketCap != null ? `&min_market_cap=${minMarketCap}` : ""}`,
      { method: "POST" },
    ),
  getMoneyGrabScanStatus: () => request<MoneyGrabStatus>("/api/moneygrab/scan/status"),
};
