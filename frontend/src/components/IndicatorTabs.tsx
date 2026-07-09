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
    color: ["#38bdf8", "#f2c94c", "#f24d4d"],
    legend: legendOption(["DIF", "DEA", "MACD"]),
    series: [
      { name: "DIF", type: "line", showSymbol: false, data: macd.dif || [] },
      { name: "DEA", type: "line", showSymbol: false, data: macd.dea || [] },
      { name: "MACD", type: "bar", barWidth: "60%", data: coloredBars(macd.hist || []) },
    ],
  }), [times, macd]);

  useIndicatorChart(lonRef, () => ({
    ...baseOption(times),
    color: ["#f2c94c", "#38bdf8"],
    legend: legendOption(["LON", "LONMA"]),
    series: [
      { name: "LON", type: "bar", barWidth: "60%", data: coloredBars(lon.lon || []) },
      { name: "LONMA", type: "line", showSymbol: false, data: lon.lonma || [] },
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
    backgroundColor: "#080d16",
    tooltip: { trigger: "axis", backgroundColor: "#101722", borderColor: "#2a3850", textStyle: { color: "#d6deea" } },
    grid: { left: 46, right: 18, top: 28, bottom: 22 },
    xAxis: {
      type: "category",
      data: times,
      axisLabel: { color: "#76849a", fontSize: 10 },
      axisLine: { lineStyle: { color: "#28354a" } },
    },
    yAxis: {
      type: "value",
      axisLabel: { color: "#76849a" },
      splitLine: { lineStyle: { color: "#172033" } },
    },
  };
}

function legendOption(data: string[]) {
  return { top: 0, right: 8, data, textStyle: { color: "#8f9bb0" } };
}

function coloredBars(values: Array<number | null>) {
  return values.map((value) => ({
    value,
    itemStyle: {
      color: value === null || value >= 0 ? "#f24d4d" : "#00a884",
    },
  }));
}
