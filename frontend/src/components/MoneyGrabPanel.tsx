import { useCallback, useEffect, useRef, useState } from "react";
import { api } from "../api";
import type { MoneyGrabHit, MoneyGrabStatus } from "../types";
import { normalizeError } from "../utils/format";

const POLL_MS = 2000;
const GROUP_NAMES = ["一", "二", "三", "四", "五", "六", "七", "八"];
const MARKET_CAP_MIN = 40; // 亿元
const TURNOVER_MIN = 3;   // 当日换手率%
const CHG3_MIN = 7;       // 近3日涨幅%
const CHG5_MIN = 14;      // 近5日涨幅%
const SWING_MIN = 40;     // 90日内低点后最高涨幅%（不到就是没动过）

// 档位分界 20/40/70/100/130/160/190/220：一档[20,40)、二档[40,70)、三档[70,100)…
const GROUP_LOWER = [20, 40, 70, 100, 130, 160, 190, 220];

function groupThreshold(group: number) {
  return GROUP_LOWER[Math.min(Math.max(group, 1), 8) - 1];
}

function zoneLower(group: number) {
  return groupThreshold(group);
}

function zoneUpper(group: number) {
  return group >= 8 ? Infinity : GROUP_LOWER[group];
}

export function MoneyGrabPanel({ onSelect }: { onSelect: (symbol: string) => void }) {
  const [status, setStatus] = useState<MoneyGrabStatus | null>(null);
  const [error, setError] = useState("");
  const [activeGroup, setActiveGroup] = useState(1);
  const [capFilter, setCapFilter] = useState(true);
  const [limitUpFilter, setLimitUpFilter] = useState(true);
  // 跌破曾站上主线的默认不显示，勾选后并入列表（扫描已带标记，切换无需重扫）
  const [showFromTop, setShowFromTop] = useState(false);
  // 基本面/技术面筛选（展示层，命中已带标记，切换无需重扫）
  const [dividendFilter, setDividendFilter] = useState(false);   // 近一年有分红
  const [profitFilter, setProfitFilter] = useState(false);       // 归母净利≥0
  const [revenueFilter, setRevenueFilter] = useState(false);     // 估市值：年化营收×10>总市值
  const [revenue2xFilter, setRevenue2xFilter] = useState(false); // 估市值超2倍
  const [lonFilter, setLonFilter] = useState(false);             // 日/周/月 LON 多头
  const [northFilter, setNorthFilter] = useState(false);         // 一路北上：低点在前高点在后
  const [hotFilter, setHotFilter] = useState(false);             // 只看今日热点概念板块内的
  const [popularFilter, setPopularFilter] = useState(false);     // 只看东财人气榜 TOP100
  const [popularSet, setPopularSet] = useState<Set<string> | null>(null); // 榜单代码（打开时才拉）
  const [popularLoading, setPopularLoading] = useState(false);
  const [turnoverFilter, setTurnoverFilter] = useState(false);   // 当日换手率>3%
  const [chg3Filter, setChg3Filter] = useState(false);           // 近3日涨幅>7%
  const [chg5Filter, setChg5Filter] = useState(false);           // 近5日涨幅>14%
  const [swingFilter, setSwingFilter] = useState(true);          // 90日波动≥40%，默认开
  const timerRef = useRef<number | null>(null);

  const loadStatus = useCallback(async () => {
    try {
      const response = await api.getMoneyGrabScanStatus();
      setStatus(response.data);
      setError("");
      return response.data;
    } catch (exc) {
      setError(normalizeError(exc));
      return null;
    }
  }, []);

  useEffect(() => {
    loadStatus();
    return () => {
      if (timerRef.current !== null) window.clearInterval(timerRef.current);
    };
  }, [loadStatus]);

  useEffect(() => {
    if (status?.status !== "running") {
      if (timerRef.current !== null) {
        window.clearInterval(timerRef.current);
        timerRef.current = null;
      }
      return;
    }
    if (timerRef.current === null) {
      timerRef.current = window.setInterval(loadStatus, POLL_MS);
    }
  }, [status?.status, loadStatus]);

  async function startScan() {
    try {
      // 涨停是展示层过滤（每条命中带 limit_up 标记），扫描本身不过滤，勾选切换即时生效
      const response = await api.startMoneyGrabScan(false, capFilter ? MARKET_CAP_MIN : undefined);
      setStatus(response.data);
      setError("");
    } catch (exc) {
      setError(normalizeError(exc));
    }
  }

  const running = status?.status === "running";
  const progress = status && status.total > 0 ? Math.round((status.done / status.total) * 100) : 0;
  const visibleHits = (status?.hits || []).filter(
    (hit) =>
      (!limitUpFilter || hit.limit_up) &&
      (showFromTop || !hit.from_top) &&
      (!dividendFilter || hit.dividend_recent === true) &&
      (!profitFilter || hit.profit_ok === true) &&
      (!revenueFilter || hit.revenue_ok === true) &&
      (!revenue2xFilter || (hit.revenue_ratio ?? 0) > 2) &&
      (!lonFilter || hit.lon_ok === true) &&
      (!northFilter || hit.north_ok === true) &&
      (!hotFilter || hit.hot_sector === true) &&
      (!popularFilter || (popularSet?.has(hit.symbol) ?? false)) &&
      (!turnoverFilter || (hit.turnover ?? -1) > TURNOVER_MIN) &&
      (!chg3Filter || (hit.chg3 ?? -999) > CHG3_MIN) &&
      (!chg5Filter || (hit.chg5 ?? -999) > CHG5_MIN) &&
      (!swingFilter || hit.max_pct >= SWING_MIN),
  );
  const groupCounts = new Map<number, number>();
  const groupHits = new Map<number, MoneyGrabHit[]>();
  visibleHits.forEach((hit) => {
    groupCounts.set(hit.group, (groupCounts.get(hit.group) || 0) + 1);
    const list = groupHits.get(hit.group) || [];
    list.push(hit);
    groupHits.set(hit.group, list);
  });
  const activeHits = (groupHits.get(activeGroup) || []).slice().sort((a, b) => b.over - a.over);
  const hasAnyHits = (status?.hits.length || 0) > 0;

  return (
    <div className="moneygrab-panel">
      <h3>八档局 · A股档位扫描</h3>
      <div className="moneygrab-actions">
        <button className="terminal-button" disabled={running} onClick={startScan}>
          {running ? "扫描中…" : status?.status === "done" ? "重新扫描" : "开始扫描"}
        </button>
        <label className="moneygrab-filter">
          <input
            type="checkbox"
            checked={capFilter}
            disabled={running}
            onChange={(event) => setCapFilter(event.target.checked)}
          />
          总市值 &gt; {MARKET_CAP_MIN} 亿
        </label>
        <label className="moneygrab-filter" title="展示过滤：勾选只看最后一天（今日）涨停的，取消显示全部，无需重扫">
          <input
            type="checkbox"
            checked={limitUpFilter}
            onChange={(event) => setLimitUpFilter(event.target.checked)}
          />
          今日涨停
        </label>
        <label className="moneygrab-filter" title="展示过滤：曾进过更高档、现在回落到低档区间的（如冲到45%后跌回35%），勾选后并入列表；重新站上该档下沿即自动恢复">
          <input type="checkbox" checked={showFromTop} onChange={(event) => setShowFromTop(event.target.checked)} />
          含异常回落
        </label>
        <label className="moneygrab-filter" title="近一年有分红（含已公告的今年分红）">
          <input
            type="checkbox"
            checked={dividendFilter}
            onChange={(event) => setDividendFilter(event.target.checked)}
          />
          分红
        </label>
        <label className="moneygrab-filter" title="最新报告期归母净利润≥0">
          <input
            type="checkbox"
            checked={profitFilter}
            onChange={(event) => setProfitFilter(event.target.checked)}
          />
          净利润
        </label>
        <label className="moneygrab-filter" title="最新报告期营收年化（一季报×4/半年报×2/三季报×4÷3/年报×1）×10 > 总市值">
          <input
            type="checkbox"
            checked={revenueFilter}
            onChange={(event) => setRevenueFilter(event.target.checked)}
          />
          估市值
        </label>
        <label className="moneygrab-filter" title="估市值倍数 > 2：年化营收×10 超过总市值 2 倍以上（等价于市销率 < 5）">
          <input
            type="checkbox"
            checked={revenue2xFilter}
            onChange={(event) => setRevenue2xFilter(event.target.checked)}
          />
          估市值2倍
        </label>
        <label className="moneygrab-filter" title="日线、周线、月线上 LON 与 LONMA 都向上，且 LONMA 不压在 LON 上方">
          <input
            type="checkbox"
            checked={lonFilter}
            onChange={(event) => setLonFilter(event.target.checked)}
          />
          LON
        </label>
        <label className="moneygrab-filter" title="从低到高：最高点出现在90日波段低点之后（排除先见高点再跌下来反弹的），且中间震荡回落不超过30%">
          <input
            type="checkbox"
            checked={northFilter}
            onChange={(event) => setNorthFilter(event.target.checked)}
          />
          一路北上
        </label>
        <label className="moneygrab-filter" title={`当日换手率 > ${TURNOVER_MIN}%`}>
          <input
            type="checkbox"
            checked={turnoverFilter}
            onChange={(event) => setTurnoverFilter(event.target.checked)}
          />
          换手&gt;{TURNOVER_MIN}%
        </label>
        <label className="moneygrab-filter" title={`近3个交易日累计涨幅 > ${CHG3_MIN}%`}>
          <input
            type="checkbox"
            checked={chg3Filter}
            onChange={(event) => setChg3Filter(event.target.checked)}
          />
          3日&gt;{CHG3_MIN}%
        </label>
        <label className="moneygrab-filter" title={`近5个交易日累计涨幅 > ${CHG5_MIN}%`}>
          <input
            type="checkbox"
            checked={chg5Filter}
            onChange={(event) => setChg5Filter(event.target.checked)}
          />
          5日&gt;{CHG5_MIN}%
        </label>
        <label className="moneygrab-filter" title={`90 日内低点之后收盘最高涨幅 ≥ ${SWING_MIN}%；从 0% 起一直没涨到过 ${SWING_MIN}% 的去掉`}>
          <input
            type="checkbox"
            checked={swingFilter}
            onChange={(event) => setSwingFilter(event.target.checked)}
          />
          波动≥{SWING_MIN}%
        </label>
        <label
          className="moneygrab-filter"
          title={`东方财富人气榜 TOP100 里的${popularSet ? `（当前 ${popularSet.size} 只）` : ""}`}
        >
          <input
            type="checkbox"
            checked={popularFilter}
            onChange={async (event) => {
              const on = event.target.checked;
              setPopularFilter(on);
              if (!on || popularSet || popularLoading) return;
              setPopularLoading(true);
              try {
                const response = await api.popularStocks(100);
                setPopularSet(new Set(response.data.map((row) => row.symbol)));
              } catch {
                // 拿不到榜单：开关保持打开但一只都不显示，和 app 端一致
              } finally {
                setPopularLoading(false);
              }
            }}
          />
          人气股{popularLoading ? "…" : ""}
        </label>
        <label className="moneygrab-filter" title="所属概念板块中有今日涨幅前列的热点板块">
          <input
            type="checkbox"
            checked={hotFilter}
            onChange={(event) => setHotFilter(event.target.checked)}
          />
          热点板块
        </label>
        {status && (running || status.status === "done") && (
          <span className="moneygrab-meta">
            {status.trade_date} · 命中 {visibleHits.length} / 全部 {status.hits.length}
            {status.status === "done" ? ` · 扫描 ${status.total}` : "（边扫边出）"}
            {status.min_market_cap != null ? ` · 市值>${status.min_market_cap}亿` : " · 未过滤市值"}
          </span>
        )}
      </div>
      {error && <p className="moneygrab-error">{error}</p>}
      {status?.status === "failed" && <p className="moneygrab-error">扫描失败：{status.error}</p>}
      {running && (
        <div className="moneygrab-progress">
          <div className="moneygrab-progress-bar" style={{ width: `${progress}%` }} />
          <span>
            {status?.stage === "snapshot" || !status?.total
              ? "正在拉取全市场行情快照…"
              : `拉取日线并计算档位 ${status.done} / ${status.total}（首次扫描需建立本地缓存，之后会快很多）`}
          </span>
        </div>
      )}
      {(hasAnyHits || status?.status === "done") && (
        <>
          <div className="moneygrab-tabs">
            {GROUP_NAMES.map((cn, index) => {
              const group = index + 1;
              const count = groupCounts.get(group) || 0;
              return (
                <button
                  key={group}
                  className={activeGroup === group ? "active" : ""}
                  onClick={() => setActiveGroup(group)}
                  title={group === 8 ? `收盘过 ${zoneLower(group)}% 入八档` : `收盘过 ${zoneLower(group)}% 入档，区间 ${zoneLower(group)}~${zoneUpper(group)}%`}
                >
                  {cn}档 {group === 8 ? `${zoneLower(group)}%+` : `${zoneLower(group)}~${zoneUpper(group)}%`}
                  <em>{count}</em>
                </button>
              );
            })}
          </div>
          <div className="moneygrab-table-wrap">
            <table className="moneygrab-table">
              <thead>
                <tr>
                  <th>代码</th>
                  <th>名称</th>
                  <th>最新价</th>
                  <th>90日低点</th>
                  <th>涨幅</th>
                  <th>波段高</th>
                  <th>低点日</th>
                  <th>过线日</th>
                  <th>超出</th>
                  <th>估值倍</th>
                  <th>换手</th>
                  <th>3日</th>
                  <th>5日</th>
                  <th>行业/概念</th>
                  <th>形态</th>
                </tr>
              </thead>
              <tbody>
                {activeHits.map((hit) => (
                  <tr key={hit.symbol} onClick={() => onSelect(hit.symbol)}>
                    <td>{hit.symbol}</td>
                    <td>{hit.name}</td>
                    <td>{hit.price.toFixed(2)}</td>
                    <td>{hit.low90.toFixed(2)}</td>
                    <td className="moneygrab-pct">{hit.pct.toFixed(1)}%</td>
                    <td>{hit.max_pct.toFixed(1)}%</td>
                    <td>{hit.low_date.slice(5)}</td>
                    <td>{hit.cross_date.slice(5)}</td>
                    <td className="moneygrab-over">+{hit.over.toFixed(1)}%</td>
                    <td>{hit.revenue_ratio != null ? `${hit.revenue_ratio.toFixed(2)}x` : "-"}</td>
                    <td>{hit.turnover != null ? `${hit.turnover.toFixed(1)}%` : "-"}</td>
                    <td>{hit.chg3 != null ? `${hit.chg3.toFixed(1)}%` : "-"}</td>
                    <td>{hit.chg5 != null ? `${hit.chg5.toFixed(1)}%` : "-"}</td>
                    <td className="moneygrab-sector" title={[hit.industry, ...(hit.concepts || [])].filter(Boolean).join(" · ")}>
                      {hit.hot_sector && <span className="moneygrab-hot">热</span>}
                      {(hit.concepts || []).slice(0, 2).join(" ") || hit.industry || "-"}
                    </td>
                    <td className="moneygrab-shape">
                      {hit.from_top && <span title="曾进过更高档、现已回落（重新站上该档下沿即恢复）">回落</span>}
                    </td>
                  </tr>
                ))}
                {!activeHits.length && (
                  <tr>
                    <td colSpan={15}>{running ? "本档暂无命中（扫描中…）" : "本档无命中"}</td>
                  </tr>
                )}
              </tbody>
            </table>
          </div>
        </>
      )}
    </div>
  );
}
