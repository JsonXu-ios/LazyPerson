import { useEffect, useState } from "react";
import { api } from "../api";
import type { Fundamentals } from "../types";
import { formatNumber, formatPercent, normalizeError } from "../utils/format";

/// 资产信息里的财务区：估值 + 最近几期业绩 + 分红方案。
/// 数据来自 /api/fundamentals/{symbol}（东财 datacenter），仅 A 股有。
export function FundamentalsPanel({ symbol, isAShare }: { symbol: string; isAShare: boolean }) {
  const [data, setData] = useState<Fundamentals | null>(null);
  const [error, setError] = useState("");
  const [loading, setLoading] = useState(false);

  useEffect(() => {
    if (!isAShare) {
      setData(null);
      setError("");
      return;
    }
    let cancelled = false;
    setLoading(true);
    setError("");
    api
      .fundamentals(symbol)
      .then((response) => {
        if (cancelled) return;
        setData(response.data);
      })
      .catch((exc) => {
        if (cancelled) return;
        setData(null);
        setError(normalizeError(exc));
      })
      .finally(() => {
        if (!cancelled) setLoading(false);
      });
    return () => {
      cancelled = true;
    };
  }, [symbol, isAShare]);

  if (!isAShare) return null;

  const latest = data?.reports[0];
  const valuation = data?.valuation || {};

  return (
    <div className="fundamentals-box">
      <h3>财务概览</h3>
      {loading && <p className="fundamentals-hint">加载中…</p>}
      {error && <p className="fundamentals-hint warn">{error}</p>}
      {data && (
        <>
          <div className="summary-grid">
            <Metric label="市盈率(动)" value={formatNumber(valuation.pe)} />
            <Metric label="市盈率(TTM)" value={formatNumber(valuation.pe_ttm)} />
            <Metric label="市净率" value={formatNumber(valuation.pb)} />
            <Metric label="总市值" value={formatNumber(valuation.market_cap)} />
            <Metric label="流通市值" value={formatNumber(valuation.float_market_cap)} />
            <Metric label="每股净资产" value={formatNumber(latest?.bps)} />
          </div>

          {latest && (
            <>
              <h4>
                最新业绩 · {latest.report_type || latest.report_date}
                <span>公告 {latest.notice_date || "-"}</span>
              </h4>
              <div className="summary-grid">
                <Metric label="营业总收入" value={formatNumber(latest.revenue)} />
                <Metric label="营收同比" value={formatPercent(latest.revenue_yoy)} tone={latest.revenue_yoy} />
                <Metric label="归母净利润" value={formatNumber(latest.parent_netprofit)} />
                <Metric
                  label="归母同比"
                  value={formatPercent(latest.parent_netprofit_yoy)}
                  tone={latest.parent_netprofit_yoy}
                />
                <Metric label="扣非归母" value={formatNumber(latest.deduct_parent_netprofit)} />
                <Metric label="净利润" value={formatNumber(latest.netprofit)} />
                <Metric label="每股收益" value={formatNumber(latest.eps)} />
                <Metric label="扣非每股收益" value={formatNumber(latest.deduct_eps)} />
                <Metric label="净资产收益率" value={formatPercent(latest.roe)} />
                <Metric label="销售毛利率" value={formatPercent(latest.gross_margin)} />
                <Metric label="每股经营现金流" value={formatNumber(latest.operating_cashflow_ps)} />
                <Metric label="利润总额" value={formatNumber(latest.total_profit)} />
              </div>
            </>
          )}

          {data.reports.length > 1 && (
            <>
              <h4>历史业绩</h4>
              <div className="fundamentals-table-wrap">
                <table className="fundamentals-table">
                  <thead>
                    <tr>
                      <th>报告期</th>
                      <th>营收</th>
                      <th>营收同比</th>
                      <th>归母净利润</th>
                      <th>归母同比</th>
                      <th>净利润</th>
                      <th>EPS</th>
                      <th>ROE</th>
                    </tr>
                  </thead>
                  <tbody>
                    {data.reports.map((report) => (
                      <tr key={report.report_date}>
                        <td>{report.report_type || report.report_date}</td>
                        <td>{formatNumber(report.revenue)}</td>
                        <td className={toneClass(report.revenue_yoy)}>{formatPercent(report.revenue_yoy)}</td>
                        <td>{formatNumber(report.parent_netprofit)}</td>
                        <td className={toneClass(report.parent_netprofit_yoy)}>
                          {formatPercent(report.parent_netprofit_yoy)}
                        </td>
                        <td>{formatNumber(report.netprofit)}</td>
                        <td>{formatNumber(report.eps)}</td>
                        <td>{formatPercent(report.roe)}</td>
                      </tr>
                    ))}
                  </tbody>
                </table>
              </div>
            </>
          )}

          <h4>分红方案</h4>
          {data.dividends.length ? (
            <div className="fundamentals-table-wrap">
              <table className="fundamentals-table">
                <thead>
                  <tr>
                    <th>对应报告期</th>
                    <th>方案</th>
                    <th>股息率</th>
                    <th>进度</th>
                    <th>除权除息日</th>
                  </tr>
                </thead>
                <tbody>
                  {data.dividends.map((item, index) => (
                    <tr key={`${item.report_date}-${item.plan_notice_date}-${index}`}>
                      <td>{item.report_date || "-"}</td>
                      <td className="fundamentals-plan" title={item.plan}>
                        {item.plan || "-"}
                      </td>
                      <td>{item.dividend_ratio == null ? "-" : formatPercent(item.dividend_ratio * 100)}</td>
                      <td>{item.progress || "-"}</td>
                      <td>{item.ex_dividend_date || "-"}</td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
          ) : (
            <p className="fundamentals-hint">暂无分红记录</p>
          )}

          {data.warnings.length > 0 && <p className="fundamentals-hint warn">{data.warnings.join("；")}</p>}
        </>
      )}
    </div>
  );
}

function Metric({ label, value, tone }: { label: string; value: string; tone?: number | null }) {
  return (
    <div className="summary-metric">
      <span>{label}</span>
      <strong className={toneClass(tone)}>{value}</strong>
    </div>
  );
}

function toneClass(value: number | null | undefined) {
  if (value === null || value === undefined || Number.isNaN(value)) return "";
  return value >= 0 ? "rise" : "fall";
}
