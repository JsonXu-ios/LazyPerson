import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import { Search, Star, Zap } from "lucide-react";
import { api } from "./api";
import { IndicatorTabs } from "./components/IndicatorTabs";
import { KlineChart } from "./components/KlineChart";
import { StatusBar } from "./components/StatusBar";
import { MoneyGrabPanel } from "./components/MoneyGrabPanel";
import { StockSummary } from "./components/StockSummary";
import { WatchlistPanel } from "./components/WatchlistPanel";
import type { DataQuality, KlinePayload, Quote, SymbolItem, WatchlistItem } from "./types";
import { computeAutoDrawing, loadLineColors, saveLineColors, type AutoLineColorMap } from "./utils/autoDrawing";
import { sliceDailyPayloadByCalendarDays } from "./utils/calendarWindow";
import { normalizeError, qualityText } from "./utils/format";

const periods = ["day", "1m", "5m", "15m", "30m", "60m"];
type SortKey = "custom" | "pct" | "amount" | "price";
type PanelKey = "a_share" | "us" | "gold" | "crypto";
type WatchSignal = {
  symbol: string;
  name: string;
};

const marketPanels: Array<{
  key: PanelKey;
  label: string;
  fallback: string;
  windowDays: number;
  windowMode?: "calendar" | "bars";
  lineStep: number;
  majorLineStep?: number;
  majorLineMinPercent?: number;
  majorLineAnchor?: number;
  showLevelPrices?: boolean;
  extendLevelsBeyond100?: boolean;
}> = [
  {
    key: "a_share",
    label: "A 股",
    fallback: "002138",
    windowDays: 90,
    windowMode: "calendar",
    lineStep: 10,
    majorLineStep: 30,
    majorLineAnchor: 20,
    showLevelPrices: true,
    extendLevelsBeyond100: true,
  },
  {
    key: "us",
    label: "美股",
    fallback: "SPY",
    windowDays: 180,
    windowMode: "bars",
    lineStep: 5,
    majorLineStep: 10,
    showLevelPrices: true,
    extendLevelsBeyond100: true,
  },
  {
    key: "gold",
    label: "黄金",
    fallback: "GC=F",
    windowDays: 180,
    windowMode: "bars",
    lineStep: 5,
    majorLineStep: 10,
    showLevelPrices: true,
    extendLevelsBeyond100: true,
  },
  {
    key: "crypto",
    label: "比特币",
    fallback: "BTC-USD",
    windowDays: 180,
    windowMode: "bars",
    lineStep: 5,
    majorLineStep: 10,
    showLevelPrices: true,
    extendLevelsBeyond100: true,
  },
];

const defaultSelectedByPanel: Record<PanelKey, string> = {
  a_share: "002138",
  us: "SPY",
  gold: "GC=F",
  crypto: "BTC-USD",
};

export function App() {
  const [watchlist, setWatchlist] = useState<WatchlistItem[]>([]);
  const [quotes, setQuotes] = useState<Quote[]>([]);
  const [activePanel, setActivePanel] = useState<PanelKey>("a_share");
  const [selectedByPanel, setSelectedByPanel] = useState<Record<PanelKey, string>>(defaultSelectedByPanel);
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
  const [lineColors, setLineColors] = useState<AutoLineColorMap>(() => loadLineColors());
  const [drawer, setDrawer] = useState<"watchlist" | "summary" | "moneygrab" | null>(null);
  const [watchSignals, setWatchSignals] = useState<{ drawdown: WatchSignal[]; uptrend: WatchSignal[] }>({
    drawdown: [],
    uptrend: [],
  });
  const quotesRequestRef = useRef(0);
  const detailRequestRef = useRef(0);
  const signalRequestRef = useRef(0);

  const panelWatchlist = useMemo(
    () => watchlist.filter((item) => panelForAsset(item) === activePanel),
    [activePanel, watchlist],
  );
  const panelResults = useMemo(
    () => results.filter((item) => panelForAsset(item) === activePanel),
    [activePanel, results],
  );
  const selected = selectedByPanel[activePanel];
  const activePanelConfig = panelConfig(activePanel);
  const activePanelLabel = activePanelConfig.label;
  const symbols = useMemo(() => panelWatchlist.map((item) => item.symbol), [panelWatchlist]);
  const quoteTargets = useMemo(() => (symbols.length ? symbols : selected ? [selected] : []), [selected, symbols]);
  const selectedQuote = quotes.find((quote) => quote.symbol === selected);
  const displayKline = useMemo(
    () => sliceDailyPayloadByCalendarDays(kline, activePanelConfig.windowDays, activePanelConfig.windowMode || "calendar"),
    [activePanelConfig.windowDays, activePanelConfig.windowMode, kline],
  );
  const latestBar = displayKline?.bars[displayKline.bars.length - 1];
  const autoDrawing = useMemo(() => {
    if (displayKline?.period !== "day") return null;
    return computeAutoDrawing(
      displayKline?.bars || [],
      activePanelConfig.windowDays,
      activePanelConfig.lineStep,
      Boolean(activePanelConfig.extendLevelsBeyond100),
    );
  }, [activePanelConfig.extendLevelsBeyond100, activePanelConfig.lineStep, activePanelConfig.windowDays, displayKline]);

  const loadWatchlist = useCallback(async () => {
    const response = await api.listWatchlist();
    setWatchlist(response.data);
    setSelectedByPanel((current) => fillSelectedPanels(current, response.data));
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
    const dayLimit = panelConfig(activePanel).windowDays === 180 ? 240 : 140;
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
  }, [activePanel]);

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
    if (!panelWatchlist.length) return;
    if (panelWatchlist.some((item) => item.symbol === selected)) return;
    if (selected) return;
    selectPanelSymbol(panelWatchlist[0].symbol);
  }, [panelWatchlist, selected]);

  useEffect(() => {
    setQuery("");
    setResults([]);
    setPeriod("day");
    setQuotes([]);
    setKline(null);
    setQuoteQuality(null);
    setKlineQuality(null);
    setDrawer(null);
  }, [activePanel]);

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
    if (!panelWatchlist.length) {
      setWatchSignals({ drawdown: [], uptrend: [] });
      return;
    }

    const requestId = ++signalRequestRef.current;
    Promise.allSettled(
      panelWatchlist.map(async (item) => {
        const config = panelConfig(panelForAsset(item));
        const response = await api.kline(item.symbol, "day", false, config.windowDays === 180 ? 240 : 140);
        return analyzeWatchSignal(item, response.data);
      }),
    ).then((results) => {
      if (requestId !== signalRequestRef.current) return;
      const drawdown: WatchSignal[] = [];
      const uptrend: WatchSignal[] = [];
      results.forEach((result) => {
        if (result.status !== "fulfilled") return;
        if (result.value.drawdown) drawdown.push(result.value.signal);
        if (result.value.uptrend) uptrend.push(result.value.signal);
      });
      setWatchSignals({ drawdown, uptrend });
    });
  }, [panelWatchlist]);

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
      await api.addWatchlist(symbol, activePanel);
      selectPanelSymbol(symbol);
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
      const nextPanelSymbols = response.data
        .filter((item) => panelForAsset(item) === activePanel)
        .map((item) => item.symbol);
      await loadQuotesFor(nextPanelSymbols, false);
      loadQuotesFor(nextPanelSymbols, true).catch((exc) => setNotice(normalizeError(exc)));
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
        const next = response.data.find((item) => item.symbol !== symbol && panelForAsset(item) === activePanel);
        selectPanelSymbol(next?.symbol || "");
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

  function updateLineColor(label: string, color: string) {
    const next = { ...lineColors, [label]: color };
    setLineColors(next);
    saveLineColors(next);
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
          <div className="market-panel-switch">
            {marketPanels.map((item) => {
              const count = watchlist.filter((asset) => panelForAsset(asset) === item.key).length;
              return (
                <button
                  className={activePanel === item.key ? "active" : ""}
                  key={item.key}
                  onClick={() => setActivePanel(item.key)}
                >
                  <strong>{item.label}</strong>
                  <span>{count} 个</span>
                </button>
              );
            })}
          </div>
          <div className="workbench-head">
            <div>
              <h2>{selectedQuote?.name || selected || activePanelLabel}</h2>
              <span>{activePanelLabel} · {selected || "暂无标的"} · {qualityText(klineQuality)}</span>
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
              {activePanel === "a_share" && (
                <button className="terminal-button" onClick={() => setDrawer("moneygrab")}>
                  <Zap size={15} />
                  抢钱流
                </button>
              )}
              <div className="period-switch">
                {periods.map((item) => (
                  <button className={period === item ? "active" : ""} key={item} onClick={() => setPeriod(item)}>
                    {item === "day" ? "日 K" : item}
                  </button>
                ))}
              </div>
            </div>
          </div>

          {(watchSignals.drawdown.length > 0 || watchSignals.uptrend.length > 0) && (
            <div className="watch-signal-strip">
              {watchSignals.drawdown.length > 0 && (
                <SignalGroup label="大涨回撤" tone="warn" items={watchSignals.drawdown} selected={selected} onSelect={selectSignal} />
              )}
              {watchSignals.uptrend.length > 0 && (
                <SignalGroup label="上升±3%" tone="rise" items={watchSignals.uptrend} selected={selected} onSelect={selectSignal} />
              )}
            </div>
          )}

          <KlineChart
            symbol={selected}
            payload={displayKline}
            autoDrawing={autoDrawing}
            lineColors={lineColors}
            windowDays={activePanelConfig.windowDays}
            windowMode={activePanelConfig.windowMode || "calendar"}
            majorLineStep={activePanelConfig.majorLineStep}
            majorLineMinPercent={activePanelConfig.majorLineMinPercent}
            majorLineAnchor={activePanelConfig.majorLineAnchor}
            showLevelPrices={Boolean(activePanelConfig.showLevelPrices)}
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
                results={panelResults}
                watchlist={panelWatchlist}
                quotes={quotes}
                selected={selected}
                sortKey={sortKey}
                panelLabel={activePanelLabel}
                onQueryChange={setQuery}
                onSortChange={setSortKey}
                onAdd={addSymbol}
                onRemove={removeSymbol}
                onSelect={(symbol) => {
                  selectPanelSymbol(symbol);
                  setPeriod("day");
                  setDrawer(null);
                }}
              />
            ) : drawer === "moneygrab" ? (
              <MoneyGrabPanel
                onSelect={(symbol) => {
                  selectPanelSymbol(symbol);
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
                lineColors={lineColors}
                onLineColorChange={updateLineColor}
                onRefresh={refreshAll}
                onRemove={() => removeSymbol(selected)}
              />
            )}
          </div>
        </div>
      )}
    </main>
  );

  function selectSignal(symbol: string) {
    selectPanelSymbol(symbol);
    setPeriod("day");
  }

  function selectPanelSymbol(symbol: string) {
    setSelectedByPanel((current) => ({ ...current, [activePanel]: symbol }));
  }
}

function SignalGroup({
  label,
  tone,
  items,
  selected,
  onSelect,
}: {
  label: string;
  tone: "warn" | "rise";
  items: WatchSignal[];
  selected: string;
  onSelect: (symbol: string) => void;
}) {
  return (
    <div className={`watch-signal-group ${tone}`}>
      <span>{label}</span>
      {items.map((item) => (
        <button className={selected === item.symbol ? "active" : ""} key={item.symbol} onClick={() => onSelect(item.symbol)}>
          {item.name || item.symbol}
        </button>
      ))}
    </div>
  );
}

function fillSelectedPanels(current: Record<PanelKey, string>, rows: WatchlistItem[]) {
  const next = { ...current };
  marketPanels.forEach((panel) => {
    const currentAsset = rows.find((item) => item.symbol === next[panel.key] && panelForAsset(item) === panel.key);
    const firstAsset = rows.find((item) => panelForAsset(item) === panel.key);
    next[panel.key] = currentAsset?.symbol || firstAsset?.symbol || panel.fallback;
  });
  return next;
}

function panelConfig(panel: PanelKey) {
  return marketPanels.find((item) => item.key === panel) || marketPanels[0];
}

function panelForAsset(item: Pick<WatchlistItem | SymbolItem, "symbol" | "market"> & { group_name?: string; note?: string }): PanelKey {
  const group = item.group_name;
  if (group === "a_share" || group === "us" || group === "gold" || group === "crypto") return group;

  const symbol = item.symbol.toUpperCase();
  const market = item.market.toUpperCase();
  const note = item.note || "";
  if (market === "CRYPTO" || symbol.endsWith("-USD") || note.includes("比特币")) return "crypto";
  if (
    market === "FUT" ||
    market === "FX" ||
    symbol === "GC=F" ||
    symbol === "GLD" ||
    symbol === "XAUUSD=X" ||
    note.includes("黄金")
  ) {
    return "gold";
  }
  if (market === "US" || /^[A-Z]{1,5}$/.test(symbol)) return "us";
  return "a_share";
}

function analyzeWatchSignal(item: WatchlistItem, payload: KlinePayload) {
  const config = panelConfig(panelForAsset(item));
  const sliced = sliceDailyPayloadByCalendarDays(payload, config.windowDays, config.windowMode || "calendar");
  const bars = (sliced?.bars || []).filter((bar) => bar.high !== null && bar.low !== null && bar.close !== null);
  const latest = bars[bars.length - 1];
  const signal = { symbol: item.symbol, name: item.name || item.symbol };
  if (!latest || bars.length < 20) {
    return { signal, drawdown: false, uptrend: false };
  }

  const drawdown = hasLargeRiseThenDrawdown(bars);
  const auto = computeAutoDrawing(bars, config.windowDays, config.lineStep, Boolean(config.extendLevelsBeyond100));
  const latestPct = latest.pct_chg ?? 0;
  const uptrend = Math.abs(latestPct) <= 3
    && !!auto?.trendSegments.some((segment) => segment.direction === "up" && segment.end.index >= bars.length - 12);
  return { signal, drawdown, uptrend };
}

function hasLargeRiseThenDrawdown(bars: KlinePayload["bars"]) {
  let troughPrice = Number(bars[0]?.low);
  let troughIndex = 0;
  let bestPeakPrice = 0;
  let bestPeakIndex = -1;
  let bestRisePct = 0;

  bars.forEach((bar, index) => {
    const low = Number(bar.low);
    const high = Number(bar.high);
    if (Number.isFinite(low) && low < troughPrice) {
      troughPrice = low;
      troughIndex = index;
    }
    if (!Number.isFinite(high) || index <= troughIndex || troughPrice <= 0) return;
    const risePct = ((high - troughPrice) / troughPrice) * 100;
    if (risePct > bestRisePct) {
      bestRisePct = risePct;
      bestPeakPrice = high;
      bestPeakIndex = index;
    }
  });

  const latestClose = Number(bars[bars.length - 1]?.close);
  if (bestPeakIndex < 0 || !Number.isFinite(latestClose) || bestPeakPrice <= 0) return false;
  const drawdownPct = ((bestPeakPrice - latestClose) / bestPeakPrice) * 100;
  return bestRisePct >= 30 && drawdownPct >= 20;
}
