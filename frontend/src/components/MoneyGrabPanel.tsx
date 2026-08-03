import { useCallback, useEffect, useRef, useState } from "react";
import { api } from "../api";
import type { MoneyGrabHit, MoneyGrabStatus } from "../types";
import { normalizeError } from "../utils/format";

const POLL_MS = 2000;
const GROUP_NAMES = ["一", "二", "三", "四", "五", "六", "七", "八"];
const MARKET_CAP_MIN = 40; // 亿元

function groupThreshold(group: number) {
  return 20 + 30 * (group - 1);
}

// 有效区：一档需站上30确认 [30,40)；二档及以上过主线即入 [50,70)、[80,100)…
function zoneLower(group: number) {
  return group === 1 ? 30 : groupThreshold(group);
}

function zoneUpper(group: number) {
  return group === 1 ? 40 : groupThreshold(group) + 20;
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
  const [lonFilter, setLonFilter] = useState(false);             // 日/周/月 LON 多头
  const [northFilter, setNorthFilter] = useState(false);         // 一路北上：低点在前高点在后
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
      (!lonFilter || hit.lon_ok === true) &&
      (!northFilter || hit.north_ok === true),
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
      <p className="moneygrab-desc">
        沪深主板（60/00）。90 日波段从低点起算：一档需站上 30% 确认（有效区 30~40%），40 是奇点；
        二档及以上过主线即入（50~70%、80~100%…）。跌破曾站上的主线（20/50/80/…）默认隐藏，收回主线上方自动恢复。
      </p>
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
        <label className="moneygrab-filter" title="展示过滤：跌破曾站上的主线（20/50/80/…），或盘中冲过奇点（40/70/100/…）后回落低于奇点−10 的，勾选后并入列表；收回自动恢复">
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
        <label className="moneygrab-filter" title="日线、周线、月线上 LON 与 LONMA 都向上，且 LONMA 不压在 LON 上方">
          <input
            type="checkbox"
            checked={lonFilter}
            onChange={(event) => setLonFilter(event.target.checked)}
          />
          LON
        </label>
        <label className="moneygrab-filter" title="90日整体向上：低点在窗口前1/3、最高点在后1/3，中间回落不限">
          <input
            type="checkbox"
            checked={northFilter}
            onChange={(event) => setNorthFilter(event.target.checked)}
          />
          一路北上
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
                  title={group === 1 ? "过20主线后需站上30确认，40是奇点" : `过${groupThreshold(group)}%主线即入档`}
                >
                  {cn}档 {zoneLower(group)}~{zoneUpper(group)}%<em>{count}</em>
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
                    <td className="moneygrab-shape">
                      {hit.from_top && <span title="跌破曾站上的主线，或冲过奇点后回落低于奇点−10（收回后自动恢复）">异常回落</span>}
                    </td>
                  </tr>
                ))}
                {!activeHits.length && (
                  <tr>
                    <td colSpan={10}>{running ? "本档暂无命中（扫描中…）" : "本档无命中"}</td>
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
