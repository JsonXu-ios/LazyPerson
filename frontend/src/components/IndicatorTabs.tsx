import * as echarts from "echarts";
import { useEffect, useMemo, useRef } from "react";
import type { DependencyList, RefObject } from "react";
import type { KlinePayload } from "../types";

type Props = {
  kline: KlinePayload | null;
};

export function IndicatorTabs({ kline }: Props) {
  const macdRef = useRef<HTMLDivElement | null>(null);
  const lonRef = useRef<HTMLDivElement | null>(null);

  const times = useMemo(() => (kline?.bars || []).map((bar) => bar.time), [kline]);
  const macd = kline?.indicators?.macd || {};
  const lon = kline?.indicators?.lon || {};

  useIndicatorChart(macdRef, () => ({
    ...baseOption(times),
    color: ["#4cc9ff", "#ffb84c", "#ff4d6d"],
    legend: legendOption(["DIF", "DEA", "MACD"]),
    series: [
      { name: "DIF", type: "line", showSymbol: false, data: macd.dif || [] },
      { name: "DEA", type: "line", showSymbol: false, data: macd.dea || [] },
      { name: "MACD", type: "bar", barWidth: "60%", data: coloredBars(macd.hist || []) },
    ],
  }), [times, macd]);

  useIndicatorChart(lonRef, () => ({
    ...baseOption(times),
    color: ["#e8f0ff", "#ffb84c"],
    legend: legendOption(["LON", "LONMA"]),
    series: [
      // 东财龙系长线画法：对零轴的红绿柱 + LON 线 + LONMA 均线
      { name: "LON柱", type: "bar", barWidth: "60%", data: coloredBars(lon.lon || []), silent: true },
      { name: "LON", type: "line", showSymbol: false, lineStyle: { width: 1.5 }, data: lon.lon || [] },
      { name: "LONMA", type: "line", showSymbol: false, lineStyle: { width: 1.5 }, data: lon.lonma || [] },
    ],
  }), [times, lon]);

  return (
    <section className="indicator-panel stacked">
      <div className="indicator-chart-block">
        <div className="indicator-title">MACD</div>
        <div className="indicator-canvas" ref={macdRef} />
      </div>
      <div className="indicator-chart-block">
        <div className="indicator-title">LON</div>
        <div className="indicator-canvas" ref={lonRef} />
      </div>
    </section>
  );
}

function useIndicatorChart(
  ref: RefObject<HTMLDivElement>,
  optionFactory: () => echarts.EChartsOption,
  deps: DependencyList,
) {
  useEffect(() => {
    const element = ref.current;
    if (!element) return;
    const chart = echarts.init(element);
    chart.setOption(optionFactory(), true);
    const resize = () => chart.resize();
    window.addEventListener("resize", resize);
    return () => {
      window.removeEventListener("resize", resize);
      chart.dispose();
    };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, deps);
}

function baseOption(times: string[]): echarts.EChartsOption {
  return {
    backgroundColor: "transparent",
    tooltip: { trigger: "axis", backgroundColor: "#0c1a33", borderColor: "#1b3255", textStyle: { color: "#e8f0ff" } },
    grid: { left: 46, right: 18, top: 28, bottom: 22 },
    xAxis: {
      type: "category",
      data: times,
      axisLabel: { color: "#5d7ca8", fontSize: 10 },
      axisLine: { lineStyle: { color: "#1b3255" } },
    },
    yAxis: {
      type: "value",
      axisLabel: { color: "#5d7ca8" },
      splitLine: { lineStyle: { color: "#122038" } },
    },
  };
}

function legendOption(data: string[]) {
  return { top: 0, right: 8, data, textStyle: { color: "#8fb4e8" } };
}

function coloredBars(values: Array<number | null>) {
  return values.map((value) => ({
    value,
    itemStyle: {
      color: value === null || value >= 0 ? "#ff4d6d" : "#00e5a0",
    },
  }));
}
