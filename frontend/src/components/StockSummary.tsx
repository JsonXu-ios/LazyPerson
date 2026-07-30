import { RefreshCw, Trash2 } from "lucide-react";
import type { DataQuality, KlineBar, Quote } from "../types";
import type { AutoDrawing, AutoLineColorMap } from "../utils/autoDrawing";
import { colorForLevel, trendLabel } from "../utils/autoDrawing";
import { formatNumber, formatPercent, formatTime, qualityText, qualityTone } from "../utils/format";
import { FundamentalsPanel } from "./FundamentalsPanel";

type Props = {
  symbol: string;
  quote: Quote | undefined;
  latestBar: KlineBar | undefined;
  quoteQuality: DataQuality | null;
  klineQuality: DataQuality | null;
  autoDrawing: AutoDrawing | null;
  lineColors: AutoLineColorMap;
  onLineColorChange: (label: string, color: string) => void;
  onRefresh: () => void;
  onRemove: () => void;
};

export function StockSummary({
  symbol,
  quote,
  latestBar,
  quoteQuality,
  klineQuality,
  autoDrawing,
  lineColors,
  onLineColorChange,
  onRefresh,
  onRemove,
}: Props) {
  const price = quote?.price ?? latestBar?.close;
  const pct = quote?.pct_chg ?? latestBar?.pct_chg;
  const up = (pct || 0) >= 0;

  return (
    <aside className="summary-panel">
      <div className="summary-head">
        <div>
          <h2>{quote?.name || symbol}</h2>
          <span>{symbol}.{quote?.market || "--"}</span>
        </div>
        <div className="summary-actions">
          <button className="icon-button" onClick={onRefresh} title="刷新资产">
            <RefreshCw size={16} />
          </button>
          <button className="icon-button danger" onClick={onRemove} title="移除自选">
            <Trash2 size={16} />
          </button>
        </div>
      </div>

      <div className="quote-price">
        <strong>{formatNumber(price)}</strong>
        <span className={up ? "rise" : "fall"}>{formatPercent(pct)}</span>
      </div>

      <div className="summary-grid">
        <Metric label="开盘" value={formatNumber(quote?.open ?? latestBar?.open)} />
        <Metric label="最高" value={formatNumber(quote?.high ?? latestBar?.high)} />
        <Metric label="最低" value={formatNumber(quote?.low ?? latestBar?.low)} />
        <Metric label="昨收" value={formatNumber(quote?.pre_close)} />
        <Metric label="成交额" value={formatNumber(quote?.amount ?? latestBar?.amount)} />
        <Metric label="成交量" value={formatNumber(quote?.volume ?? latestBar?.volume)} />
        <Metric label="换手率" value={formatPercent(quote?.turnover ?? latestBar?.turnover)} />
        <Metric label="更新时间" value={formatTime(quote?.trade_time ?? latestBar?.time)} />
      </div>

      <div className="quality-box">
        <h3>数据状态</h3>
        <span className={`status-pill ${qualityTone(quoteQuality)}`}>{qualityText(quoteQuality)}</span>
        <span className={`status-pill ${qualityTone(klineQuality)}`}>{qualityText(klineQuality)}</span>
      </div>

      {/* 代码不是 6 位数字（理论上不该出现）时不渲染财务区 */}
      <FundamentalsPanel symbol={symbol} isAShare={/^\d{6}$/.test(symbol)} />

      {autoDrawing && (
        <div className={`auto-summary ${autoDrawing.direction}`}>
          <h3>自动画线</h3>
          <div className="auto-trend-badge">{trendLabel(autoDrawing.direction)}</div>
          <Metric label="近期高点" value={`${autoDrawing.recentHigh.time} / ${formatNumber(autoDrawing.recentHigh.price)}`} />
          <Metric label="近期低点" value={`${autoDrawing.recentLow.time} / ${formatNumber(autoDrawing.recentLow.price)}`} />
          <Metric label="基准点" value={`${autoDrawing.base.label} / ${formatNumber(autoDrawing.base.price)}`} />
          <Metric
            label="最近线位"
            value={`${autoDrawing.nearestLevel?.label || "-"} / ${formatNumber(autoDrawing.nearestLevel?.price)}`}
          />
          <Metric
            label="距线位"
            value={autoDrawing.nearestDistancePct === null ? "-" : `${autoDrawing.nearestDistancePct.toFixed(2)}%`}
          />
          <div className="auto-line-list">
            {autoDrawing.levels.map((level, index) => {
              const color = colorForLevel(level, lineColors, index);
              return (
                <label key={level.label}>
                  <input
                    type="color"
                    value={color}
                    onChange={(event) => onLineColorChange(level.label, event.target.value)}
                    aria-label={`选择 ${level.label} 颜色`}
                    title={`${level.label} 颜色`}
                  />
                  <input
                    className="color-hex-input"
                    key={`${level.label}-${color}`}
                    type="text"
                    defaultValue={color}
                    maxLength={7}
                    spellCheck={false}
                    onChange={(event) => {
                      const nextColor = normalizeHexColor(event.target.value);
                      if (nextColor) onLineColorChange(level.label, nextColor);
                    }}
                    aria-label={`输入 ${level.label} 颜色`}
                    title={`${level.label} 颜色值`}
                  />
                  <span>
                    {level.label} / {formatNumber(level.price)}
                  </span>
                </label>
              );
            })}
          </div>
          <div className="auto-trend-list">
            {autoDrawing.trendSegments.map((segment) => (
              <span key={segment.id}>{segment.label}</span>
            ))}
          </div>
        </div>
      )}
    </aside>
  );
}

function Metric({ label, value }: { label: string; value: string }) {
  return (
    <div className="summary-metric">
      <span>{label}</span>
      <strong>{value}</strong>
    </div>
  );
}

function normalizeHexColor(value: string) {
  const normalized = value.trim().toLowerCase();
  return /^#[0-9a-f]{6}$/.test(normalized) ? normalized : null;
}
