import { useCallback, useEffect, useRef, useState } from "react";
import { api } from "../api";
import type { MoneyGrabHit, MoneyGrabStatus } from "../types";
import { normalizeError } from "../utils/format";

const POLL_MS = 2000;
// K线主线：破势按"已突破的最高主线"分组，与八档局的档位分界(20/40/70/100)是两套口径
const MAIN_LINES = [20, 50, 80, 110, 140, 170, 200, 230];

// 零帧起手：从高处下来、现在贴着 90 日低点的（后端 evaluate_zero_base 单独收的一批）
const ZERO_BASE_LABEL = "零帧起手";

// 蓄势待发：刚站上某条主线、还没走远（对齐 breakout.py::buildup_over）
const BUILDUP_MAX_OVER = 5;

function buildupLine(pct: number): number | null {
  if (pct < MAIN_LINES[0]) return null;
  const crossed = MAIN_LINES.filter((value) => pct >= value).pop();
  if (crossed === undefined) return null;
  return pct - crossed <= BUILDUP_MAX_OVER ? crossed : null;
}

function stageLabel(stage: number) {
  if (stage <= 1) return `0→${MAIN_LINES[0]}%`;
  const upper = MAIN_LINES[Math.min(stage, MAIN_LINES.length) - 1];
  const lower = MAIN_LINES[Math.min(stage, MAIN_LINES.length) - 2];
  return `${lower}→${upper}%`;
}

export function BreakoutPanel({ onSelect }: { onSelect: (symbol: string) => void }) {
  const [status, setStatus] = useState<MoneyGrabStatus | null>(null);
  const [error, setError] = useState("");
  const [activeStage, setActiveStage] = useState(2);
  const [view, setView] = useState<"broken" | "buildup" | "zero">("broken");
  // 零帧起手按"曾站上过的最高主线"分组（从多高摔下来的）
  const [activePeak, setActivePeak] = useState(2);
  const [activeLine, setActiveLine] = useState(50);
  const timerRef = useRef<number | null>(null);

  const loadStatus = useCallback(async () => {
    try {
      const response = await api.getMoneyGrabScanStatus();
      setStatus(response.data);
      setError("");
    } catch (exc) {
      setError(normalizeError(exc));
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
    if (timerRef.current === null) timerRef.current = window.setInterval(loadStatus, POLL_MS);
  }, [status?.status, loadStatus]);

  // 破势用的是与八档局同一次扫描的结果，只是换一套分组口径
  const byStage = new Map<number, MoneyGrabHit[]>();
  (status?.hits || []).forEach((hit) => {
    const stage = hit.break_stage ?? 0;
    if (stage < 2) return; // 只看真正完成了一次主线突破的（站上50及以上）
    const list = byStage.get(stage) || [];
    list.push(hit);
    byStage.set(stage, list);
  });
  // 蓄势待发：按"刚站上哪条主线"分组
  const byLine = new Map<number, MoneyGrabHit[]>();
  (status?.hits || []).forEach((hit) => {
    const line = buildupLine(hit.pct);
    if (line === null) return;
    const list = byLine.get(line) || [];
    list.push(hit);
    byLine.set(line, list);
  });
  // 零帧起手：数据源是后端单独收的 zero_base（八档局的 hits 里没有这批）
  const byPeak = new Map<number, MoneyGrabHit[]>();
  (status?.zero_base || []).forEach((hit) => {
    const stage = MAIN_LINES.filter((line) => hit.max_pct >= line).length;
    if (stage < 1) return;
    const list = byPeak.get(stage) || [];
    list.push(hit);
    byPeak.set(stage, list);
  });

  const rows =
    view === "broken"
      ? (byStage.get(activeStage) || []).slice().sort((a, b) => b.pct - a.pct)
      : view === "buildup"
        ? (byLine.get(activeLine) || []).slice().sort((a, b) => a.pct - b.pct)
        : (byPeak.get(activePeak) || []).slice().sort((a, b) => b.max_pct - a.max_pct);

  return (
    <div className="breakout-panel">
      <h3>
        破势 · {view === "broken" ? "主线突破" : view === "buildup" ? "蓄势待发" : ZERO_BASE_LABEL}
      </h3>
      <div className="breakout-views">
        <button className={view === "broken" ? "active" : ""} onClick={() => setView("broken")}>
          主线突破
        </button>
        <button className={view === "buildup" ? "active" : ""} onClick={() => setView("buildup")}>
          蓄势待发
        </button>
        <button className={view === "zero" ? "active" : ""} onClick={() => setView("zero")}>
          {ZERO_BASE_LABEL}
        </button>
      </div>
      <div className="breakout-actions">
        <span className="breakout-meta">
          {view === "broken"
            ? "与八档局共用同一次扫描结果；按已突破的最高主线分组，每只股只出现在最高那组。"
            : view === "buildup"
              ? `与八档局共用同一次扫描结果；刚站上主线、超出 ≤${BUILDUP_MAX_OVER}% 的，按刚站上哪条线分组。`
              : "至少从 +50% 一路摔回 90 日低点的（八档局的档位规则筛掉的那批，扫描时单独收）；按曾站上过哪条主线分组。App 端已拆成独立扫描。"}
          {status?.status === "done" && ` · ${status.trade_date} 命中 ${status.hits.length}`}
        </span>
      </div>
      {error && <p className="breakout-error">{error}</p>}
      {status?.status !== "done" && !status?.hits.length && !status?.zero_base?.length && (
        <p className="breakout-meta">请先到「八档局」执行一次扫描</p>
      )}
      <div className="breakout-tabs">
        {view === "broken"
          ? MAIN_LINES.slice(1).map((_, index) => {
              const stage = index + 2;
              const count = (byStage.get(stage) || []).length;
              return (
                <button
                  key={stage}
                  className={activeStage === stage ? "active" : ""}
                  onClick={() => setActiveStage(stage)}
                  title={`已站上 ${MAIN_LINES[stage - 1]}% 主线`}
                >
                  {stageLabel(stage)}
                  <em>{count}</em>
                </button>
              );
            })
          : view === "buildup"
            ? MAIN_LINES.map((line) => (
                <button
                  key={line}
                  className={activeLine === line ? "active" : ""}
                  onClick={() => setActiveLine(line)}
                  title={`刚站上 ${line}% 主线，超出不到 ${BUILDUP_MAX_OVER}%`}
                >
                  刚过 {line}%
                  <em>{(byLine.get(line) || []).length}</em>
                </button>
              ))
            : MAIN_LINES.map((line, index) => (
                <button
                  key={line}
                  className={activePeak === index + 1 ? "active" : ""}
                  onClick={() => setActivePeak(index + 1)}
                  title={`曾站上 ${line}% 主线后跌回 90 日低点`}
                >
                  曾过 {line}%
                  <em>{(byPeak.get(index + 1) || []).length}</em>
                </button>
              ))}
      </div>
      <div className="breakout-table-wrap">
        <table className="breakout-table">
          <thead>
            <tr>
              <th>代码</th>
              <th>名称</th>
              <th>现价</th>
              <th>涨幅</th>
              <th>{view === "broken" ? "波段高" : view === "buildup" ? "超出" : "自高点"}</th>
              <th>换手</th>
              <th>行业/概念</th>
            </tr>
          </thead>
          <tbody>
            {rows.map((hit) => (
              <tr key={hit.symbol} onClick={() => onSelect(hit.symbol)}>
                <td>{hit.symbol}</td>
                <td>{hit.name}</td>
                <td>{hit.price.toFixed(2)}</td>
                <td className="breakout-pct">{hit.pct.toFixed(1)}%</td>
                <td>
                  {view === "broken"
                    ? `${hit.max_pct.toFixed(1)}%`
                    : view === "buildup"
                      ? `+${(hit.pct - (buildupLine(hit.pct) ?? hit.pct)).toFixed(1)}%`
                      : `-${((1 - (1 + hit.pct / 100) / (1 + hit.max_pct / 100)) * 100).toFixed(1)}%`}
                </td>
                <td>{hit.turnover != null ? `${hit.turnover.toFixed(1)}%` : "-"}</td>
                <td className="breakout-sector" title={[hit.industry, ...(hit.concepts || [])].filter(Boolean).join(" · ")}>
                  {(hit.concepts || []).slice(0, 2).join(" ") || hit.industry || "-"}
                </td>
              </tr>
            ))}
            {!rows.length && (
              <tr>
                <td colSpan={7}>本组无命中</td>
              </tr>
            )}
          </tbody>
        </table>
      </div>
    </div>
  );
}
