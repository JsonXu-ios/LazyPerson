import { useCallback, useEffect, useRef, useState } from "react";
import { api } from "../api";
import type { MoneyGrabStatus } from "../types";
import { normalizeError } from "../utils/format";

const POLL_MS = 2000;

export function MoneyGrabPanel({ onSelect }: { onSelect: (symbol: string) => void }) {
  const [status, setStatus] = useState<MoneyGrabStatus | null>(null);
  const [error, setError] = useState("");
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
      const response = await api.startMoneyGrabScan();
      setStatus(response.data);
      setError("");
    } catch (exc) {
      setError(normalizeError(exc));
    }
  }

  const running = status?.status === "running";
  const progress = status && status.total > 0 ? Math.round((status.done / status.total) * 100) : 0;
  const hits = status ? [...status.hits].sort((a, b) => b.over - a.over) : [];
  const showTable = status ? hits.length > 0 || status.status === "done" : false;

  return (
    <div className="moneygrab-panel">
      <h3>抢钱流 · A股档位扫描</h3>
      <p className="moneygrab-desc">
        筛选：现价超过所在 20% 档位区间下沿 10% 以上（如 20%~40% 档中高于 +30%）。基准为 90 自然日最低价。
      </p>
      <div className="moneygrab-actions">
        <button className="terminal-button" disabled={running} onClick={startScan}>
          {running ? "扫描中…" : status?.status === "done" ? "重新扫描" : "开始扫描"}
        </button>
        {status && (running || status.status === "done") && (
          <span className="moneygrab-meta">
            {status.trade_date} · 命中 {status.hits.length}
            {status.status === "done" ? ` / 扫描 ${status.total}` : "（边扫边出，实时更新）"}
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
      {showTable && (
        <div className="moneygrab-table-wrap">
          <table className="moneygrab-table">
            <thead>
              <tr>
                <th>代码</th>
                <th>名称</th>
                <th>最新价</th>
                <th>90日低点</th>
                <th>涨幅</th>
                <th>档位</th>
                <th>超出</th>
              </tr>
            </thead>
            <tbody>
              {hits.map((hit) => (
                <tr key={hit.symbol} onClick={() => onSelect(hit.symbol)}>
                  <td>{hit.symbol}</td>
                  <td>{hit.name}</td>
                  <td>{hit.price.toFixed(2)}</td>
                  <td>{hit.low90.toFixed(2)}</td>
                  <td className="moneygrab-pct">{hit.pct.toFixed(1)}%</td>
                  <td>
                    {hit.band}%~{hit.band + 20}%
                  </td>
                  <td className="moneygrab-over">+{hit.over.toFixed(1)}%</td>
                </tr>
              ))}
              {!hits.length && status?.status === "done" && (
                <tr>
                  <td colSpan={7}>今日无命中</td>
                </tr>
              )}
            </tbody>
          </table>
        </div>
      )}
    </div>
  );
}
