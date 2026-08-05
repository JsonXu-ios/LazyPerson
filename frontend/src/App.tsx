import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import { Flame, Search, Star, Zap } from "lucide-react";
import { api } from "./api";
import { IndicatorTabs } from "./components/IndicatorTabs";
import { KlineChart } from "./components/KlineChart";
import { StatusBar } from "./components/StatusBar";
import { MoneyGrabPanel } from "./components/MoneyGrabPanel";
import { HotSectorPanel } from "./components/HotSectorPanel";
import { StockSummary } from "./components/StockSummary";
import { WatchlistPanel } from "./components/WatchlistPanel";
import type { DataQuality, KlinePayload, Quote, SymbolItem, WatchlistItem } from "./types";
import { computeAutoDrawing } from "./utils/autoDrawing";
import { sliceDailyPayloadByCalendarDays } from "./utils/calendarWindow";
import { normalizeError, qualityText } from "./utils/format";

const periods = ["day", "week", "month"];
const periodLabels: Record<string, string> = { day: "日 K", week: "周 K", month: "月 K" };
type SortKey = "custom" | "pct" | "amount" | "price";

/// 只做沪深 A 股。画线参数与 app/lib/logic/market_panels.dart::aShareConfig 一致。
const A_SHARE_GROUP = "a_share";
const aShareConfig = {
  label: "A 股",
  fallback: "002138",
  windowDays: 90,
  windowMode: "calendar" as const,
  lineStep: 10,
  majorLineStep: 30,
  majorLineAnchor: 20,
  showLevelPrices: true,
  extendLevelsBeyond100: true,
};

export function App() {
  const [watchlist, setWatchlist] = useState<WatchlistItem[]>([]);
  const [quotes, setQuotes] = useState<Quote[]>([]);
  const [selected, setSelected] = useState(aShareConfig.fallback);
  const [query, setQuery] = useState("");
  const [results, setResults] = useState<SymbolItem[]>([]);
  const [period, setPeriod] = useState("day");
  const [sortKey, setSortKey] = useState<SortKey>("custom");
  const [kline, setKline] = useState<KlinePayload | null>(null);
  const [quoteQuality, setQuoteQuality] = useState<DataQuality | null>(null);
  const [klineQuality, setKlineQuality] = useState<DataQuality | null>(null);
  const [backendStatus, setBackendStatus] = useState("连接中");
  const [notice, setNotice] = useState("");
  const [loading, setLoading] = useState(false);
  const [drawer, setDrawer] = useState<"watchlist" | "summary" | "moneygrab" | "sectors" | null>(null);
  const quotesRequestRef = useRef(0);
  const detailRequestRef = useRef(0);

  const aShareResults = useMemo(() => results.filter((item) => isAShareSymbol(item.symbol)), [results]);
  const symbols = useMemo(() => watchlist.map((item) => item.symbol), [watchlist]);
  const quoteTargets = useMemo(() => {
    const targets = new Set(symbols);
    if (selected) targets.add(selected);  // 非自选股（如八档局点入）也要拉行情，否则没有名称
    return [...targets];
  }, [selected, symbols]);
  const selectedQuote = quotes.find((quote) => quote.symbol === selected);
  // 八档局点进来的标的通常不在自选里，资产信息面板据此显示"加入"还是"移除"
  const selectedInWatchlist = watchlist.some((item) => item.symbol === selected);
  const displayKline = useMemo(
    () => sliceDailyPayloadByCalendarDays(kline, aShareConfig.windowDays, aShareConfig.windowMode),
    [kline],
  );
  const latestBar = displayKline?.bars[displayKline.bars.length - 1];
  const autoDrawing = useMemo(() => {
    if (displayKline?.period !== "day") return null;
    return computeAutoDrawing(
      displayKline?.bars || [],
      aShareConfig.windowDays,
      aShareConfig.lineStep,
      aShareConfig.extendLevelsBeyond100,
    );
  }, [displayKline]);

  const loadWatchlist = useCallback(async () => {
    const response = await api.listWatchlist();
    setWatchlist(response.data);
    setSelected((current) => fillSelected(current, response.data));
  }, []);

  const loadQuotesFor = useCallback(async (targets: string[], refresh = false) => {
    if (!targets.length) return;
    const requestId = ++quotesRequestRef.current;
    const response = await api.realtimeQuotes(targets, refresh);
    if (requestId !== quotesRequestRef.current) return;
    setQuotes(response.data);
    setQuoteQuality(response.quality || null);
    if (response.quality?.fallback || response.quality?.stale) {
      setNotice(response.quality.message || qualityText(response.quality));
    }
  }, []);

  const loadQuotes = useCallback(async (refresh = false) => {
    await loadQuotesFor(quoteTargets, refresh);
  }, [loadQuotesFor, quoteTargets]);

  const loadDetailFor = useCallback(async (symbol: string, nextPeriod: string, refresh = false, clearBeforeLoad = true) => {
    if (!symbol) return;
    const requestId = ++detailRequestRef.current;
    if (clearBeforeLoad) {
      setKline(null);
      setKlineQuality(null);
    }
    const dayLimit = aShareConfig.windowDays === 180 ? 240 : 140;
    const klineResponse = await Promise.resolve(api.kline(symbol, nextPeriod, refresh, nextPeriod === "day" ? dayLimit : 1000))
      .then((value) => ({ status: "fulfilled" as const, value }))
      .catch((reason) => ({ status: "rejected" as const, reason }));
    if (requestId !== detailRequestRef.current) return;
    if (klineResponse.status === "fulfilled") {
      setKline(klineResponse.value.data);
      setKlineQuality(klineResponse.value.quality || null);
    } else {
      setNotice(normalizeError(klineResponse.reason));
    }
  }, []);

  const loadDetail = useCallback(async (refresh = false) => {
    await loadDetailFor(selected, period, refresh);
  }, [loadDetailFor, period, selected]);

  useEffect(() => {
    api.health()
      .then((response) => setBackendStatus(`后端 ${response.data.version}`))
      .catch(() => setBackendStatus("后端未连接"));
    loadWatchlist().catch((exc) => setNotice(normalizeError(exc)));
  }, [loadWatchlist]);

  useEffect(() => {
    if (!watchlist.length || selected) return;
    setSelected(watchlist[0].symbol);
  }, [selected, watchlist]);

  useEffect(() => {
    loadQuotes(false)
      .then(() => loadQuotes(true))
      .catch((exc) => setNotice(normalizeError(exc)));
  }, [loadQuotes]);

  useEffect(() => {
    if (!selected) return;
    loadDetailFor(selected, period, false, true)
      .then(() => loadDetailFor(selected, period, true, false))
      .catch((exc) => {
        setNotice(normalizeError(exc));
        loadDetailFor(selected, period, true, false).catch((refreshExc) => setNotice(normalizeError(refreshExc)));
      });
  }, [loadDetailFor, period, selected]);

  useEffect(() => {
    if (!query.trim()) {
      setResults([]);
      return;
    }
    const timer = window.setTimeout(() => {
      api.searchSymbols(query.trim())
        .then((response) => setResults(response.data))
        .catch((exc) => setNotice(normalizeError(exc)));
    }, 260);
    return () => window.clearTimeout(timer);
  }, [query]);

  async function addSymbol(symbol: string) {
    setLoading(true);
    try {
      await api.addWatchlist(symbol, A_SHARE_GROUP);
      setSelected(symbol);
      setPeriod("day");
      setQuery("");
      setResults([]);
      setDrawer(null);
      const response = await api.listWatchlist();
      setWatchlist(response.data);
      await loadDetailFor(symbol, "day", false, true).catch((exc) => {
        setNotice(normalizeError(exc));
      });
      loadDetailFor(symbol, "day", true, false).catch((exc) => setNotice(normalizeError(exc)));
      const nextSymbols = response.data.map((item) => item.symbol);
      await loadQuotesFor(nextSymbols, false);
      loadQuotesFor(nextSymbols, true).catch((exc) => setNotice(normalizeError(exc)));
    } catch (exc) {
      setNotice(normalizeError(exc));
    } finally {
      setLoading(false);
    }
  }

  async function removeSymbol(symbol: string) {
    setLoading(true);
    try {
      await api.removeWatchlist(symbol);
      const response = await api.listWatchlist();
      setWatchlist(response.data);
      setQuotes((current) => current.filter((quote) => quote.symbol !== symbol));
      if (selected === symbol) {
        const next = response.data.find((item) => item.symbol !== symbol);
        setSelected(next?.symbol || "");
        if (!next) setKline(null);
      }
    } catch (exc) {
      setNotice(normalizeError(exc));
    } finally {
      setLoading(false);
    }
  }

  async function refreshAll() {
    setLoading(true);
    setNotice("");
    try {
      await Promise.all([loadQuotes(true), loadDetail(true)]);
    } catch (exc) {
      setNotice(normalizeError(exc));
    } finally {
      setLoading(false);
    }
  }

  return (
    <main className="app-shell v2">
      <StatusBar
        backendStatus={backendStatus}
        quoteQuality={quoteQuality}
        klineQuality={klineQuality}
        loading={loading}
        onRefresh={refreshAll}
      />

      {notice && (
        <div className="notice v2">
          <span>{notice}</span>
          <button onClick={() => setNotice("")}>关闭</button>
        </div>
      )}

      <section className="terminal-layout chart-first">
        <section className="chart-workbench">
          <div className="workbench-head">
            <div>
              <h2>{selectedQuote?.name || selected || aShareConfig.label}</h2>
              <span className="workbench-sub">
                {selected || "暂无标的"} · {selectedQuote?.market || "--"} · {qualityText(klineQuality)}
              </span>
            </div>
            <div className="workbench-actions">
              <button className="terminal-button" onClick={() => setDrawer("watchlist")}>
                <Search size={15} />
                自选资产
              </button>
              <button className="terminal-button" onClick={() => setDrawer("summary")}>
                <Star size={15} />
                资产信息
              </button>
              <button className="terminal-button accent" onClick={() => setDrawer("moneygrab")}>
                <Zap size={15} />
                八档局
              </button>
              <button className="terminal-button" onClick={() => setDrawer("sectors")}>
                <Flame size={15} />
                热点板块
              </button>
              <div className="period-switch">
                {periods.map((item) => (
                  <button className={period === item ? "active" : ""} key={item} onClick={() => setPeriod(item)}>
                    {periodLabels[item] || item}
                  </button>
                ))}
              </div>
            </div>
          </div>

          <KlineChart
            symbol={selected}
            payload={displayKline}
            autoDrawing={autoDrawing}
            windowDays={aShareConfig.windowDays}
            windowMode={aShareConfig.windowMode}
            majorLineStep={aShareConfig.majorLineStep}
            majorLineAnchor={aShareConfig.majorLineAnchor}
            showLevelPrices={aShareConfig.showLevelPrices}
          />
          <IndicatorTabs kline={displayKline} />
        </section>
      </section>

      {drawer && (
        <div className="drawer-backdrop" onClick={() => setDrawer(null)}>
          <div className={`side-drawer ${drawer}`} onClick={(event) => event.stopPropagation()}>
            <button className="drawer-close" onClick={() => setDrawer(null)} title="关闭">
              <span aria-hidden="true">×</span>
            </button>
            {drawer === "watchlist" ? (
              <WatchlistPanel
                query={query}
                results={aShareResults}
                watchlist={watchlist}
                quotes={quotes}
                selected={selected}
                sortKey={sortKey}
                onQueryChange={setQuery}
                onSortChange={setSortKey}
                onAdd={addSymbol}
                onRemove={removeSymbol}
                onSelect={(symbol) => {
                  setSelected(symbol);
                  setPeriod("day");
                  setDrawer(null);
                }}
              />
            ) : drawer === "sectors" ? (
              <HotSectorPanel
                onSelect={(symbol) => {
                  setSelected(symbol);
                  setPeriod("day");
                  setDrawer(null);
                }}
              />
            ) : drawer === "moneygrab" ? (
              <MoneyGrabPanel
                onSelect={(symbol) => {
                  setSelected(symbol);
                  setPeriod("day");
                  setDrawer(null);
                }}
              />
            ) : (
              <StockSummary
                symbol={selected}
                quote={selectedQuote}
                latestBar={latestBar}
                quoteQuality={quoteQuality}
                klineQuality={klineQuality}
                autoDrawing={autoDrawing}
                inWatchlist={selectedInWatchlist}
                onRefresh={refreshAll}
                onAdd={() => addSymbol(selected)}
                onRemove={() => removeSymbol(selected)}
              />
            )}
          </div>
        </div>
      )}
    </main>
  );
}

/// 选中标的失效（被删/首次加载）时落到自选首项，再退到内置标的
function fillSelected(current: string, rows: WatchlistItem[]) {
  if (rows.some((item) => item.symbol === current)) return current;
  return rows[0]?.symbol || aShareConfig.fallback;
}

/// 沪深 A 股 = 6 位数字代码（与后端 utils.is_a_share_symbol 同口径）
function isAShareSymbol(symbol: string) {
  return /^\d{6}$/.test(symbol);
}

