import {
  createChart,
  ColorType,
  LineStyle,
  PriceScaleMode,
  type IChartApi,
  type ISeriesApi,
  type SeriesType,
} from "lightweight-charts";
import { Plus, Trash2 } from "lucide-react";
import { useEffect, useMemo, useRef, useState, type MouseEvent, type PointerEvent } from "react";
import type { KlineBar, KlinePayload } from "../types";
import type { AutoDrawing, AutoLineColorMap, AutoLineLevel } from "../utils/autoDrawing";
import { colorForLevel } from "../utils/autoDrawing";
import { formatNumber, formatPercent } from "../utils/format";

type Props = {
  symbol: string;
  payload: KlinePayload | null;
  autoDrawing: AutoDrawing | null;
  lineColors: AutoLineColorMap;
  windowDays: number;
  windowMode: "calendar" | "bars";
  majorLineStep?: number;
  majorLineMinPercent?: number;
  showLevelPrices?: boolean;
};

type CustomPriceLine = {
  id: string;
  price: number;
  color: string;
};

type CustomTrendLine = {
  id: string;
  color: string;
  points: Array<{
    time: string;
    price: number;
  }>;
};

type TrendPointMarker = {
  key: string;
  lineId?: string;
  pointIndex?: number;
  left: number;
  top: number;
  color: string;
  label: string;
  draft: boolean;
};

const CUSTOM_LINE_STORAGE_PREFIX = "lazy-person:custom-price-lines:v1:";
const CUSTOM_TREND_STORAGE_PREFIX = "lazy-person:custom-trend-lines:v1:";

function chartTime(value: string) {
  if (value.includes(" ")) {
    return Math.floor(new Date(value.replace(" ", "T")).getTime() / 1000);
  }
  return value;
}

export function KlineChart({
  symbol,
  payload,
  autoDrawing,
  lineColors,
  windowDays,
  windowMode,
  majorLineStep,
  majorLineMinPercent,
  showLevelPrices,
}: Props) {
  const containerRef = useRef<HTMLDivElement | null>(null);
  const chartWrapRef = useRef<HTMLDivElement | null>(null);
  const chartRef = useRef<IChartApi | null>(null);
  const candleSeriesRef = useRef<ISeriesApi<"Candlestick"> | null>(null);
  const seriesRef = useRef<ISeriesApi<SeriesType>[]>([]);
  const barsRef = useRef<KlineBar[]>([]);
  const customTrendLinesRef = useRef<CustomTrendLine[]>([]);
  const draggingTrendPointRef = useRef<{ lineId: string; pointIndex: number } | null>(null);
  const [hoverBar, setHoverBar] = useState<KlineBar | null>(null);
  const [customLines, setCustomLines] = useState<CustomPriceLine[]>([]);
  const [customTrendLines, setCustomTrendLines] = useState<CustomTrendLine[]>([]);
  const [draftTrendPoints, setDraftTrendPoints] = useState<CustomTrendLine["points"]>([]);
  const [drawingTrend, setDrawingTrend] = useState(false);
  const [trendPointMarkers, setTrendPointMarkers] = useState<TrendPointMarker[]>([]);
  const [levelLabels, setLevelLabels] = useState<Array<{
    key: string;
    label: string;
    color: string;
    textColor: string;
    top: number;
    highlight: boolean;
    custom: boolean;
  }>>([]);
  const useLogPriceScale = shouldUseLogPriceScale(autoDrawing);

  const candleData = useMemo(() => {
    return (payload?.bars || [])
      .filter((bar) => bar.open !== null && bar.high !== null && bar.low !== null && bar.close !== null)
      .map((bar) => ({
        time: chartTime(bar.time) as never,
        open: Number(bar.open),
        high: Number(bar.high),
        low: Number(bar.low),
        close: Number(bar.close),
      }));
  }, [payload]);

  useEffect(() => {
    barsRef.current = payload?.bars || [];
    setHoverBar(null);
  }, [payload]);

  useEffect(() => {
    customTrendLinesRef.current = customTrendLines;
  }, [customTrendLines]);

  useEffect(() => {
    setCustomLines(loadCustomPriceLines(symbol));
    setCustomTrendLines(loadCustomTrendLines(symbol));
    setDraftTrendPoints([]);
    setDrawingTrend(false);
  }, [symbol]);

  const volumeData = useMemo(() => {
    return (payload?.bars || [])
      .filter((bar) => bar.volume !== null)
      .map((bar) => ({
        time: chartTime(bar.time) as never,
        value: Number(bar.volume),
        color: (bar.close || 0) >= (bar.open || 0) ? "rgba(242, 77, 77, 0.46)" : "rgba(0, 168, 132, 0.46)",
      }));
  }, [payload]);

  useEffect(() => {
    const element = containerRef.current;
    if (!element) return;
    const chart = createChart(element, {
      autoSize: true,
      layout: {
        background: { type: ColorType.Solid, color: "#070b12" },
        textColor: "#8f9bb0",
        fontFamily: "Inter, system-ui, sans-serif",
      },
      grid: {
        vertLines: { color: "#172033" },
        horzLines: { color: "#172033" },
      },
      rightPriceScale: {
        borderColor: "#28354a",
        scaleMargins: {
          top: 0.08,
          bottom: 0.12,
        },
      },
      timeScale: {
        borderColor: "#28354a",
        timeVisible: true,
      },
      handleScroll: {
        mouseWheel: false,
        pressedMouseMove: false,
        horzTouchDrag: false,
        vertTouchDrag: false,
      },
      handleScale: {
        axisPressedMouseMove: false,
        mouseWheel: false,
        pinch: false,
      },
      crosshair: {
        mode: 1,
      },
    });
    chart.subscribeCrosshairMove((param) => {
      const time = String(param.time || "");
      const matched = barsRef.current.find((bar) => String(chartTime(bar.time)) === time || bar.time === time);
      setHoverBar(matched || null);
    });
    chartRef.current = chart;
    seriesRef.current = [];
    return () => {
      seriesRef.current = [];
      chart.remove();
      chartRef.current = null;
    };
  }, []);

  useEffect(() => {
    const chart = chartRef.current;
    if (!chart) return;
    chart.priceScale("right").applyOptions({
      mode: useLogPriceScale ? PriceScaleMode.Logarithmic : PriceScaleMode.Normal,
      scaleMargins: {
        top: useLogPriceScale ? 0.12 : 0.08,
        bottom: useLogPriceScale ? 0.16 : 0.12,
      },
    });
    candleSeriesRef.current = null;
    seriesRef.current.forEach((series) => {
      try {
        chart.removeSeries(series);
      } catch {
        // React StrictMode can replay effects during development; stale series may already be gone.
      }
    });
    seriesRef.current = [];
    const candle = chart.addCandlestickSeries({
      upColor: "#f24d4d",
      downColor: "#00a884",
      borderUpColor: "#f24d4d",
      borderDownColor: "#00a884",
      wickUpColor: "#f24d4d",
      wickDownColor: "#00a884",
    });
    candle.setData(candleData);
    candleSeriesRef.current = candle;
    seriesRef.current.push(candle);

    if (payload?.period === "day" && autoDrawing) {
      autoDrawing.levels.forEach((level, index) => {
        const highlight = isHighlightLevel(level, majorLineStep, majorLineMinPercent);
        candle.createPriceLine({
          price: level.price,
          color: lineColor(level, colorForLevel(level, lineColors, index), majorLineStep, majorLineMinPercent),
          lineWidth: highlight ? 3 : 1,
          lineStyle: LineStyle.Solid,
          axisLabelVisible: false,
          title: "",
        });
      });

      autoDrawing.trendSegments.forEach((segment, index) => {
        const trend = chart.addLineSeries({
          color: segment.direction === "up" ? "#f24d4d" : "#00a884",
          lineWidth: 3,
          priceLineVisible: false,
          lastValueVisible: false,
          lineStyle: LineStyle.Solid,
          autoscaleInfoProvider: () => null,
        });
        const points = segment.points?.length ? segment.points : [segment.start, segment.end];
        trend.setData(points.map((point) => ({
          time: chartTime(point.time) as never,
          value: point.price,
        })));
        seriesRef.current.push(trend);
      });
    }

    customLines.forEach((line) => {
      candle.createPriceLine({
        price: line.price,
        color: line.color,
        lineWidth: 2,
        lineStyle: LineStyle.Solid,
        axisLabelVisible: true,
        title: formatNumber(line.price),
      });
    });

    customTrendLines.forEach((line) => {
      if (line.points.length < 2) return;
      const trend = chart.addLineSeries({
        color: line.color,
        lineWidth: 3,
        priceLineVisible: false,
        lastValueVisible: false,
        lineStyle: LineStyle.Solid,
        autoscaleInfoProvider: () => null,
      });
      trend.setData(trendSeriesData(line));
      seriesRef.current.push(trend);
    });

    const volume = chart.addHistogramSeries({
      priceFormat: { type: "volume" },
      priceScaleId: "",
      lastValueVisible: false,
      priceLineVisible: false,
    });
    volume.priceScale().applyOptions({
      scaleMargins: {
        top: 0.78,
        bottom: 0,
      },
    });
    volume.setData(volumeData);
    seriesRef.current.push(volume);

    const ma = payload?.indicators?.ma || {};
    const colors: Record<string, string> = {
      ma5: "#f2c94c",
      ma10: "#38bdf8",
      ma20: "#c084fc",
      ma60: "#f97316",
    };
    Object.entries(ma).forEach(([name, values]) => {
      const series = chart.addLineSeries({
        color: colors[name] || "#555",
        lineWidth: 1,
        priceLineVisible: false,
        lastValueVisible: false,
      });
      seriesRef.current.push(series);
      series.setData(
        values
          .map((value, index) => ({
            time: chartTime(payload?.bars[index]?.time || "") as never,
            value,
          }))
          .filter((item) => item.time && item.value !== null) as never,
      );
    });

    chart.timeScale().fitContent();
    window.setTimeout(() => {
      updateLevelLabelPositions();
      updateTrendPointPositions();
    }, 60);
  }, [autoDrawing, candleData, customLines, customTrendLines, lineColors, majorLineMinPercent, majorLineStep, payload, useLogPriceScale, volumeData]);

  useEffect(() => {
    const resize = () => {
      updateLevelLabelPositions();
      updateTrendPointPositions();
    };
    window.addEventListener("resize", resize);
    return () => window.removeEventListener("resize", resize);
  }, [autoDrawing, lineColors, majorLineMinPercent, majorLineStep]);

  useEffect(() => {
    window.setTimeout(updateTrendPointPositions, 30);
  }, [customTrendLines, draftTrendPoints, payload]);

  useEffect(() => {
    function move(event: globalThis.PointerEvent) {
      const dragging = draggingTrendPointRef.current;
      if (!dragging) return;
      event.preventDefault();
      const nextPoint = pointFromClientPosition(event.clientX, event.clientY);
      if (!nextPoint) return;
      setCustomTrendLines((current) => {
        const next = current.map((line) => {
          if (line.id !== dragging.lineId) return line;
          return {
            ...line,
            points: line.points.map((point, index) => (index === dragging.pointIndex ? nextPoint : point)),
          };
        });
        customTrendLinesRef.current = next;
        return next;
      });
    }

    function up() {
      if (!draggingTrendPointRef.current) return;
      draggingTrendPointRef.current = null;
      saveCustomTrendLines(symbol, customTrendLinesRef.current);
    }

    document.addEventListener("pointermove", move);
    document.addEventListener("pointerup", up);
    return () => {
      document.removeEventListener("pointermove", move);
      document.removeEventListener("pointerup", up);
    };
  }, [symbol]);

  function updateLevelLabelPositions() {
    if (!candleSeriesRef.current) {
      setLevelLabels([]);
      return;
    }
    const autoRows = (autoDrawing?.levels || [])
      .map((level, index) => {
        const coordinate = candleSeriesRef.current?.priceToCoordinate(level.price);
        if (coordinate === null || coordinate === undefined) return null;
        return {
          key: `auto-${level.label}`,
          label: showLevelPrices ? `${level.label} ${formatFullPrice(level.price)}` : level.label,
          color: lineColor(level, colorForLevel(level, lineColors, index), majorLineStep, majorLineMinPercent),
          textColor: labelTextColor(level, majorLineStep, majorLineMinPercent),
          top: Number(coordinate),
          highlight: isHighlightLevel(level, majorLineStep, majorLineMinPercent),
          custom: false,
          priority: levelLabelPriority(level, majorLineStep, majorLineMinPercent),
        };
      })
      .filter(Boolean) as LevelLabel[];
    const customRows = customLines
      .map((line) => {
        const coordinate = candleSeriesRef.current?.priceToCoordinate(line.price);
        const label = customLinePercentLabel(line.price, autoDrawing?.base.price, latest?.close);
        if (coordinate === null || coordinate === undefined || !label) return null;
        return {
          key: `custom-${line.id}`,
          label,
          color: line.color,
          textColor: labelTextColor("custom"),
          top: Number(coordinate),
          highlight: false,
          custom: true,
          priority: 100,
        };
      })
      .filter(Boolean) as LevelLabel[];
    setLevelLabels(avoidCrowdedLevelLabels([...autoRows, ...customRows]));
  }

  function updateTrendPointPositions() {
    if (!chartRef.current || !candleSeriesRef.current || !payload?.bars.length) {
      setTrendPointMarkers([]);
      return;
    }

    const markers: TrendPointMarker[] = [];
    customTrendLines.forEach((line, lineIndex) => {
      line.points.forEach((point, pointIndex) => {
        const coordinate = coordinateForTrendPoint(point);
        if (!coordinate) return;
        markers.push({
          key: `${line.id}-${pointIndex}`,
          lineId: line.id,
          pointIndex,
          left: coordinate.left,
          top: coordinate.top,
          color: line.color,
          label: `线${lineIndex + 1} 点${pointIndex + 1} ${formatFullPrice(point.price)}`,
          draft: false,
        });
      });
    });

    draftTrendPoints.forEach((point, pointIndex) => {
      const coordinate = coordinateForTrendPoint(point);
      if (!coordinate) return;
      markers.push({
        key: `draft-${pointIndex}`,
        left: coordinate.left,
        top: coordinate.top,
        color: "#ffd479",
        label: `点${pointIndex + 1} ${formatFullPrice(point.price)}`,
        draft: true,
      });
    });

    setTrendPointMarkers(markers);
  }

  function coordinateForTrendPoint(point: CustomTrendLine["points"][number]) {
    if (!chartRef.current || !candleSeriesRef.current || !payload?.bars.length) return null;
    const index = payload.bars.findIndex((bar) => bar.time === point.time);
    if (index < 0) return null;
    const left = (chartRef.current.timeScale() as unknown as { logicalToCoordinate: (logical: number) => number | null })
      .logicalToCoordinate(index);
    const top = candleSeriesRef.current.priceToCoordinate(point.price);
    if (left === null || left === undefined || top === null || top === undefined) return null;
    return { left: Number(left), top: Number(top) };
  }

  function setLogicalRange(nextFrom: number, nextTo: number) {
    const chart = chartRef.current;
    if (!chart) return;
    chart.timeScale().setVisibleLogicalRange({ from: nextFrom, to: nextTo });
  }

  function zoom(factor: number) {
    const chart = chartRef.current;
    const range = chart?.timeScale().getVisibleLogicalRange();
    if (!chart || !range) return;
    const center = (range.from + range.to) / 2;
    const half = ((range.to - range.from) * factor) / 2;
    setLogicalRange(center - half, center + half);
    window.setTimeout(() => {
      updateLevelLabelPositions();
      updateTrendPointPositions();
    }, 30);
  }

  function scroll(direction: -1 | 1) {
    const chart = chartRef.current;
    const range = chart?.timeScale().getVisibleLogicalRange();
    if (!chart || !range) return;
    const shift = (range.to - range.from) * 0.18 * direction;
    setLogicalRange(range.from + shift, range.to + shift);
    window.setTimeout(() => {
      updateLevelLabelPositions();
      updateTrendPointPositions();
    }, 30);
  }

  function saveCustomLines(next: CustomPriceLine[]) {
    setCustomLines(next);
    saveCustomPriceLines(symbol, next);
  }

  function saveTrendLines(next: CustomTrendLine[]) {
    customTrendLinesRef.current = next;
    setCustomTrendLines(next);
    saveCustomTrendLines(symbol, next);
  }

  function addCustomLine() {
    const price = Number(latest?.close ?? latest?.high ?? latest?.low);
    if (!Number.isFinite(price)) return;
    saveCustomLines([
      ...customLines,
      {
        id: `${Date.now()}-${Math.random().toString(16).slice(2)}`,
        price: roundLinePrice(price),
        color: "#f6d36b",
      },
    ]);
  }

  function updateCustomLine(id: string, patch: Partial<CustomPriceLine>) {
    saveCustomLines(customLines.map((line) => (line.id === id ? { ...line, ...patch } : line)));
  }

  function removeCustomLine(id: string) {
    saveCustomLines(customLines.filter((line) => line.id !== id));
  }

  function updateTrendLine(id: string, patch: Partial<CustomTrendLine>) {
    saveTrendLines(customTrendLines.map((line) => (line.id === id ? { ...line, ...patch } : line)));
  }

  function removeTrendLine(id: string) {
    saveTrendLines(customTrendLines.filter((line) => line.id !== id));
  }

  function startTrendDrawing() {
    setDraftTrendPoints([]);
    setDrawingTrend(true);
  }

  function pointFromClientPosition(clientX: number, clientY: number) {
    if (!chartRef.current || !candleSeriesRef.current || !chartWrapRef.current || !payload?.bars.length) return null;
    const rect = chartWrapRef.current.getBoundingClientRect();
    const x = clientX - rect.left;
    const y = clientY - rect.top;
    const logical = chartRef.current.timeScale().coordinateToLogical(x);
    const price = candleSeriesRef.current.coordinateToPrice(y);
    if (logical === null || logical === undefined || price === null || price === undefined) return null;
    const barIndex = Math.min(Math.max(Math.round(Number(logical)), 0), payload.bars.length - 1);
    const time = payload.bars[barIndex]?.time;
    if (!time || !Number.isFinite(Number(price))) return null;
    return { time, price: roundLinePrice(Number(price)) };
  }

  function handleChartClick(event: MouseEvent<HTMLDivElement>) {
    if (!drawingTrend || !chartRef.current || !candleSeriesRef.current) return;
    const nextPoint = pointFromClientPosition(event.clientX, event.clientY);
    if (!nextPoint) return;

    const nextPoints = [...draftTrendPoints, nextPoint];
    if (nextPoints.length < 2) {
      setDraftTrendPoints(nextPoints);
      return;
    }
    saveTrendLines([
      ...customTrendLines,
      {
        id: `${Date.now()}-${Math.random().toString(16).slice(2)}`,
        color: "#38bdf8",
        points: nextPoints,
      },
    ]);
    setDraftTrendPoints([]);
    setDrawingTrend(false);
  }

  function startDraggingTrendPoint(event: PointerEvent<HTMLButtonElement>, lineId: string | undefined, pointIndex: number | undefined) {
    event.preventDefault();
    event.stopPropagation();
    if (!lineId || pointIndex === undefined) return;
    draggingTrendPointRef.current = { lineId, pointIndex };
  }

  const latest = hoverBar || payload?.bars[payload.bars.length - 1];
  const macd = payload?.indicators?.macd;
  const lastIndex = Math.max((payload?.bars.length || 1) - 1, 0);

  return (
    <div className="chart-panel">
      <div className="chart-header">
        <h3>K 线</h3>
        <div className="chart-header-actions">
          <span>{payload?.period === "day" ? `近${windowDays}${windowMode === "bars" ? "根" : "自然日"}K` : payload?.period || "-"} · {latest?.time || "-"}</span>
          <button onClick={() => zoom(0.72)} title="放大">+</button>
          <button onClick={() => zoom(1.28)} title="缩小">-</button>
          <button onClick={() => scroll(-1)} title="左移">←</button>
          <button onClick={() => scroll(1)} title="右移">→</button>
          <button
            onClick={() => {
              chartRef.current?.timeScale().fitContent();
              window.setTimeout(updateTrendPointPositions, 30);
            }}
            title="全览"
          >
            全览
          </button>
          <button onClick={addCustomLine} title="添加横线">
            <Plus size={13} />
            横线
          </button>
          <button className={drawingTrend ? "active" : ""} onClick={startTrendDrawing} title="画趋势线">
            <Plus size={13} />
            趋势线
          </button>
        </div>
      </div>
      {(customLines.length > 0 || customTrendLines.length > 0 || drawingTrend) && (
        <div className="custom-line-editor">
          {drawingTrend && (
            <span className="trend-drawing-hint">点击图中两个位置完成趋势线</span>
          )}
          {customLines.map((line) => (
            <div className="custom-line-row" key={line.id}>
              <input
                type="number"
                value={line.price}
                step="0.01"
                onChange={(event) => {
                  const price = Number(event.target.value);
                  if (Number.isFinite(price)) updateCustomLine(line.id, { price });
                }}
                aria-label="横线价格"
                title="横线价格"
              />
              <input
                type="color"
                value={line.color}
                onChange={(event) => updateCustomLine(line.id, { color: event.target.value })}
                aria-label="横线颜色"
                title="横线颜色"
              />
              <button onClick={() => removeCustomLine(line.id)} title="删除横线">
                <Trash2 size={13} />
              </button>
            </div>
          ))}
          {customTrendLines.map((line, index) => (
            <div className="custom-line-row" key={line.id}>
              <span>趋势线 {index + 1}</span>
              <input
                type="color"
                value={line.color}
                onChange={(event) => updateTrendLine(line.id, { color: event.target.value })}
                aria-label="趋势线颜色"
                title="趋势线颜色"
              />
              <button onClick={() => removeTrendLine(line.id)} title="删除趋势线">
                <Trash2 size={13} />
              </button>
            </div>
          ))}
        </div>
      )}
      <div className="ohlc-strip">
        <span>开 {formatNumber(latest?.open)}</span>
        <span>高 {formatNumber(latest?.high)}</span>
        <span>低 {formatNumber(latest?.low)}</span>
        <span>收 {formatNumber(latest?.close)}</span>
        <span>幅 {formatPercent(latest?.pct_chg)}</span>
        <span>量 {formatNumber(latest?.volume)}</span>
      </div>
      <div
        className={`chart-canvas-wrap ${drawingTrend ? "drawing-trend" : ""}`}
        onClick={handleChartClick}
        ref={chartWrapRef}
      >
        <div className="kline-canvas" ref={containerRef} />
        {trendPointMarkers.length > 0 && (
          <div className="trend-point-overlay">
            {trendPointMarkers.map((marker) => (
              <button
                className={`trend-point-marker ${marker.draft ? "draft" : ""}`}
                key={marker.key}
                onClick={(event) => event.stopPropagation()}
                onPointerDown={(event) => startDraggingTrendPoint(event, marker.lineId, marker.pointIndex)}
                style={{ left: marker.left, top: marker.top, borderColor: marker.color }}
                title={marker.draft ? "已选择的趋势线点位" : "拖动移动趋势线点位"}
                type="button"
              >
                <span style={{ backgroundColor: marker.color }}>{marker.label}</span>
              </button>
            ))}
          </div>
        )}
        {levelLabels.length > 0 && (
          <div className="level-label-overlay" aria-hidden="true">
            {levelLabels.map((item) => (
              <div
                className={`level-label-row ${item.highlight ? "highlight" : ""} ${item.custom ? "custom" : ""}`}
                key={item.key}
                style={{ top: item.top, backgroundColor: item.color, color: item.textColor }}
              >
                <span>{item.label}</span>
              </div>
            ))}
          </div>
        )}
      </div>
      <div className="indicator-strip">
        <span>MACD {macd?.hist?.[lastIndex]?.toFixed?.(3) ?? "-"}</span>
        <span>DIF {macd?.dif?.[lastIndex]?.toFixed?.(3) ?? "-"}</span>
        <span>DEA {macd?.dea?.[lastIndex]?.toFixed?.(3) ?? "-"}</span>
        <span>LON {payload?.indicators?.lon?.lon?.[lastIndex]?.toFixed?.(3) ?? "-"}</span>
        <span>LONMA {payload?.indicators?.lon?.lonma?.[lastIndex]?.toFixed?.(3) ?? "-"}</span>
      </div>
    </div>
  );
}

type LevelLabel = {
  key: string;
  label: string;
  color: string;
  textColor: string;
  top: number;
  highlight: boolean;
  custom: boolean;
  priority: number;
};

function customLineStorageKey(symbol: string) {
  return `${CUSTOM_LINE_STORAGE_PREFIX}${symbol || "unknown"}`;
}

function loadCustomPriceLines(symbol: string): CustomPriceLine[] {
  try {
    const raw = window.localStorage.getItem(customLineStorageKey(symbol));
    const parsed = raw ? JSON.parse(raw) : [];
    if (!Array.isArray(parsed)) return [];
    return parsed
      .map((item) => ({
        id: String(item.id || `${Date.now()}-${Math.random().toString(16).slice(2)}`),
        price: Number(item.price),
        color: /^#[0-9a-f]{6}$/i.test(String(item.color)) ? String(item.color) : "#f6d36b",
      }))
      .filter((item) => Number.isFinite(item.price));
  } catch {
    return [];
  }
}

function saveCustomPriceLines(symbol: string, lines: CustomPriceLine[]) {
  try {
    window.localStorage.setItem(customLineStorageKey(symbol), JSON.stringify(lines));
  } catch {
    // localStorage may be unavailable in restricted browser contexts.
  }
}

function customTrendStorageKey(symbol: string) {
  return `${CUSTOM_TREND_STORAGE_PREFIX}${symbol || "unknown"}`;
}

function loadCustomTrendLines(symbol: string): CustomTrendLine[] {
  try {
    const raw = window.localStorage.getItem(customTrendStorageKey(symbol));
    const parsed = raw ? JSON.parse(raw) : [];
    if (!Array.isArray(parsed)) return [];
    return parsed
      .map((item) => ({
        id: String(item.id || `${Date.now()}-${Math.random().toString(16).slice(2)}`),
        color: /^#[0-9a-f]{6}$/i.test(String(item.color)) ? String(item.color) : "#38bdf8",
        points: Array.isArray(item.points)
          ? item.points
            .map((point: { time?: unknown; price?: unknown }) => ({
              time: String(point.time || ""),
              price: Number(point.price),
            }))
            .filter((point: { time: string; price: number }) => point.time && Number.isFinite(point.price))
            .slice(0, 2)
          : [],
      }))
      .filter((item) => item.points.length === 2);
  } catch {
    return [];
  }
}

function saveCustomTrendLines(symbol: string, lines: CustomTrendLine[]) {
  try {
    window.localStorage.setItem(customTrendStorageKey(symbol), JSON.stringify(lines));
  } catch {
    // localStorage may be unavailable in restricted browser contexts.
  }
}

function trendSeriesData(line: CustomTrendLine) {
  return [...line.points]
    .sort((a, b) => Date.parse(a.time.replace(" ", "T")) - Date.parse(b.time.replace(" ", "T")))
    .map((point) => ({
      time: chartTime(point.time) as never,
      value: point.price,
    }));
}

function roundLinePrice(value: number) {
  return Number(value.toFixed(value >= 100 ? 2 : 3));
}

function shouldUseLogPriceScale(autoDrawing: AutoDrawing | null) {
  const base = Number(autoDrawing?.base.price);
  const target = Number(autoDrawing?.target.price);
  if (!Number.isFinite(base) || !Number.isFinite(target) || base <= 0) return false;
  return target / base >= 2 || (autoDrawing?.levels.length || 0) >= 28;
}

function avoidCrowdedLevelLabels(rows: LevelLabel[]) {
  const minGap = 19;
  const selected = [...rows]
    .sort((a, b) => b.priority - a.priority || a.top - b.top)
    .reduce<LevelLabel[]>((kept, row) => {
      const gap = row.highlight ? minGap + 4 : minGap;
      const blocked = kept.some((item) => Math.abs(item.top - row.top) < Math.max(gap, item.highlight ? minGap + 4 : minGap));
      if (!blocked) kept.push(row);
      return kept;
    }, []);
  return selected.sort((a, b) => a.top - b.top);
}

function levelLabelPriority(level: AutoLineLevel, majorLineStep?: number, majorLineMinPercent = 0) {
  if (level.percent === 0) return 90;
  if (isMajorLevel(level, majorLineStep, majorLineMinPercent)) return 80 + Math.min(level.percent, 200) / 100;
  if (level.percent % 50 === 0) return 70;
  if (level.percent % 20 === 0) return 60;
  if (level.percent % 10 === 0) return 50;
  return 10;
}

function formatFullPrice(value: number | null | undefined) {
  if (value === null || value === undefined || Number.isNaN(value)) return "-";
  if (Math.abs(value) >= 100) return value.toFixed(2);
  if (Math.abs(value) >= 1) return value.toFixed(3);
  return value.toFixed(6);
}

function isHighlightLevel(level: AutoLineLevel, majorLineStep?: number, majorLineMinPercent = 0) {
  return isMajorLevel(level, majorLineStep, majorLineMinPercent)
    || level.label === "+20%"
    || level.label === "+50%"
    || level.label === "+80%";
}

function lineColor(level: AutoLineLevel, fallback: string, majorLineStep?: number, majorLineMinPercent = 0) {
  if (isMajorLevel(level, majorLineStep, majorLineMinPercent)) return majorLevelColor(level.percent);
  if (level.label === "+20%") return "#f24d4d";
  if (level.label === "+50%") return "#1f6feb";
  if (level.label === "+80%") return "#ffffff";
  return fallback;
}

function labelTextColor(levelOrLabel: AutoLineLevel | string, majorLineStep?: number, majorLineMinPercent = 0) {
  if (typeof levelOrLabel !== "string" && isMajorLevel(levelOrLabel, majorLineStep, majorLineMinPercent)) {
    return majorLevelTextColor(levelOrLabel.percent);
  }
  const label = typeof levelOrLabel === "string" ? levelOrLabel : levelOrLabel.label;
  if (label === "+20%" || label === "+50%") return "#ffffff";
  return "#07111f";
}

function isMajorLevel(level: AutoLineLevel, majorLineStep?: number, majorLineMinPercent = 0) {
  return !!majorLineStep
    && level.percent >= majorLineMinPercent
    && level.percent > 0
    && level.percent % majorLineStep === 0;
}

function majorLevelColor(percent: number) {
  const palette = ["#38bdf8", "#f24d4d", "#c084fc", "#f2a93b", "#1f6feb", "#00a884"];
  const index = Math.max(Math.floor(percent / 10) - 1, 0) % palette.length;
  return palette[index];
}

function majorLevelTextColor(percent: number) {
  const color = majorLevelColor(percent);
  return color === "#38bdf8" || color === "#f2a93b" ? "#061016" : "#ffffff";
}

function customLinePercentLabel(price: number, basePrice: number | undefined, fallbackPrice: number | null | undefined) {
  const base = Number(basePrice || fallbackPrice);
  if (!Number.isFinite(price) || !Number.isFinite(base) || base <= 0) return "";
  const percent = ((price - base) / base) * 100;
  const sign = percent > 0 ? "+" : "";
  return `${sign}${percent.toFixed(2)}%`;
}
