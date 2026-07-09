import * as echarts from "echarts";
import { useEffect, useRef } from "react";
import type { MoneyFlowPayload } from "../types";

type Props = {
  payload: MoneyFlowPayload | null;
};

function formatYi(value: number | null | undefined) {
  if (value === null || value === undefined) return 0;
  return Number((value / 100000000).toFixed(3));
}

export function MoneyFlowChart({ payload }: Props) {
  const ref = useRef<HTMLDivElement | null>(null);
  const latest = payload?.items?.[Math.max((payload?.items?.length || 1) - 1, 0)];

  useEffect(() => {
    const element = ref.current;
    if (!element) return;
    const chart = echarts.init(element);
    const items = (payload?.items || []).slice(-80);
    chart.setOption({
      animation: false,
      color: ["#1f6feb", "#d64f45", "#15876f"],
      tooltip: { trigger: "axis" },
      grid: { left: 46, right: 18, top: 30, bottom: 36 },
      xAxis: {
        type: "category",
        data: items.map((item) => item.time),
        axisLabel: { color: "#667382", fontSize: 11 },
        axisLine: { lineStyle: { color: "#d8dee7" } },
      },
      yAxis: {
        type: "value",
        axisLabel: { color: "#667382", formatter: "{value}亿" },
        splitLine: { lineStyle: { color: "#e9edf2" } },
      },
      series: [
        {
          name: "主力",
          type: "bar",
          data: items.map((item) => formatYi(item.main_net_inflow)),
        },
        {
          name: "超大单",
          type: "line",
          smooth: true,
          showSymbol: false,
          data: items.map((item) => formatYi(item.super_large_net_inflow)),
        },
        {
          name: "大单",
          type: "line",
          smooth: true,
          showSymbol: false,
          data: items.map((item) => formatYi(item.large_net_inflow)),
        },
      ],
    });
    const resize = () => chart.resize();
    window.addEventListener("resize", resize);
    return () => {
      window.removeEventListener("resize", resize);
      chart.dispose();
    };
  }, [payload]);

  return (
    <div className="chart-panel flow-panel">
      <div className="chart-header">
        <h3>资金流</h3>
        <span>{latest?.time || "-"}</span>
      </div>
      <div className="flow-canvas" ref={ref} />
    </div>
  );
}
