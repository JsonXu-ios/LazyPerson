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

export function MoneyGrabPanel({ onSelect }: { onSelect: (symbol: string) => void }) {
  const [status, setStatus] = useState<MoneyGrabStatus | null>(null);
  const [error, setError] = useState("");
  const [activeGroup, setActiveGroup] = useState(1);
  const [capFilter, setCapFilter] = useState(true);
  const [limitUpFilter, setLimitUpFilter] = useState(false);
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
      const response = await api.startMoneyGrabScan(false, capFilter ? MARKET_CAP_MIN : undefined, limitUpFilter);
      setStatus(response.data);
      setError("");
    } catch (exc) {
      setError(normalizeError(exc));
    }
  }

  const running = status?.status === "running";
  const progress = status && status.total > 0 ? Math.round((status.done / status.total) * 100) : 0;
  const groupCounts = new Map<number, number>();
  const groupHits = new Map<number, MoneyGrabHit[]>();
  (status?.hits || []).forEach((hit) => {
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
        沪深主板（60/00）。90 日波段（低点→高点）分档：先过（阈值−10）%，最后一天至少过阈值%。
        阈值 20%~230% 每 30% 一档，与图上粗线一致。
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
        <label className="moneygrab-filter">
          <input
            type="checkbox"
            checked={limitUpFilter}
            disabled={running}
            onChange={(event) => setLimitUpFilter(event.target.checked)}
          />
          今日涨停
        </label>
        {status && (running || status.status === "done") && (
          <span className="moneygrab-meta">
            {status.trade_date} · 命中 {status.hits.length}
            {status.status === "done" ? ` / 扫描 ${status.total}` : "（边扫边出）"}
            {status.min_market_cap != null ? ` · 市值>${status.min_market_cap}亿` : " · 未过滤市值"}
            {status.limit_up_only ? " · 仅今日涨停" : ""}
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
                  title={`先过${groupThreshold(group) - 10}%，现至少过${groupThreshold(group)}%`}
                >
                  {cn}档 ≥{groupThreshold(group)}%<em>{count}</em>
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
                  <th>低点日</th>
                  <th>过线日</th>
                  <th>超出</th>
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
                    <td>{hit.low_date.slice(5)}</td>
                    <td>{hit.cross_date.slice(5)}</td>
                    <td className="moneygrab-over">+{hit.over.toFixed(1)}%</td>
                  </tr>
                ))}
                {!activeHits.length && (
                  <tr>
                    <td colSpan={8}>{running ? "本档暂无命中（扫描中…）" : "本档无命中"}</td>
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
