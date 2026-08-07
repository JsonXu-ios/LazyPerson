import { useCallback, useEffect, useState } from "react";
import { api } from "../api";
import type { PopularStock } from "../types";
import { normalizeError } from "../utils/format";

export function PopularPanel({ onSelect }: { onSelect: (symbol: string) => void }) {
  const [rows, setRows] = useState<PopularStock[]>([]);
  const [error, setError] = useState("");
  const [loading, setLoading] = useState(false);

  const load = useCallback(async (refresh = false) => {
    setLoading(true);
    try {
      const response = await api.popularStocks(100, refresh);
      setRows(response.data);
      setError("");
    } catch (exc) {
      setError(normalizeError(exc));
    } finally {
      setLoading(false);
    }
  }, []);

  useEffect(() => {
    load();
  }, [load]);

  return (
    <div className="popular-panel">
      <h3>人气股 · 东方财富人气榜 TOP100</h3>
      <div className="popular-actions">
        <button className="terminal-button" disabled={loading} onClick={() => load(true)}>
          {loading ? "刷新中…" : "刷新"}
        </button>
        <span className="popular-meta">榜单每 5 分钟更新 · 点击行切换主图</span>
      </div>
      {error && <p className="popular-error">{error}</p>}
      <div className="popular-table-wrap">
        <table className="popular-table">
          <thead>
            <tr>
              <th>排名</th>
              <th>代码</th>
              <th>名称</th>
              <th>现价</th>
              <th>涨跌</th>
              <th>行业</th>
              <th>概念</th>
            </tr>
          </thead>
          <tbody>
            {rows.map((row) => (
              <tr key={row.symbol} onClick={() => onSelect(row.symbol)}>
                <td className="popular-rank">
                  {row.rank}
                  {row.rank_change != null && row.rank_change !== 0 && (
                    <em className={row.rank_change > 0 ? "up" : "down"}>
                      {row.rank_change > 0 ? "↑" : "↓"}
                      {Math.abs(row.rank_change)}
                    </em>
                  )}
                </td>
                <td>{row.symbol}</td>
                <td>{row.name || "-"}</td>
                <td>{row.price != null ? row.price.toFixed(2) : "-"}</td>
                <td className={(row.pct_chg ?? 0) >= 0 ? "popular-up" : "popular-down"}>
                  {row.pct_chg != null ? `${row.pct_chg.toFixed(2)}%` : "-"}
                </td>
                <td className="popular-industry" title={row.industry}>
                  {row.industry || "-"}
                </td>
                <td className="popular-concepts" title={row.concepts.join(" · ")}>
                  {row.concepts.slice(0, 2).join(" ") || "-"}
                </td>
              </tr>
            ))}
            {!rows.length && !loading && (
              <tr>
                <td colSpan={7}>暂无数据</td>
              </tr>
            )}
          </tbody>
        </table>
      </div>
    </div>
  );
}
