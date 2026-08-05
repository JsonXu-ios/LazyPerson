import { useCallback, useEffect, useState } from "react";
import { api } from "../api";
import type { HotSectors, SectorBoard, SectorConstituent } from "../types";
import { normalizeError } from "../utils/format";

export function HotSectorPanel({ onSelect }: { onSelect: (symbol: string) => void }) {
  const [data, setData] = useState<HotSectors | null>(null);
  const [error, setError] = useState("");
  const [loading, setLoading] = useState(false);
  const [openBoard, setOpenBoard] = useState<SectorBoard | null>(null);
  const [constituents, setConstituents] = useState<SectorConstituent[]>([]);
  const [consLoading, setConsLoading] = useState(false);

  const load = useCallback(async (refresh = false) => {
    setLoading(true);
    try {
      const response = await api.hotSectors(20, refresh);
      setData(response.data);
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

  async function openConstituents(board: SectorBoard) {
    if (!board.code) return; // 同花顺行业板块无东财代码，不支持展开成分股
    if (openBoard?.code === board.code) {
      setOpenBoard(null);
      return;
    }
    setOpenBoard(board);
    setConsLoading(true);
    try {
      const response = await api.sectorConstituents(board.code, 40);
      setConstituents(response.data);
    } catch (exc) {
      setError(normalizeError(exc));
      setConstituents([]);
    } finally {
      setConsLoading(false);
    }
  }

  return (
    <div className="sector-panel">
      <h3>今日热点板块</h3>
      <div className="sector-actions">
        <button className="terminal-button" disabled={loading} onClick={() => load(true)}>
          {loading ? "刷新中…" : "刷新"}
        </button>
        <span className="sector-meta">行业来自同花顺 · 概念来自东方财富</span>
      </div>
      {error && <p className="sector-error">{error}</p>}
      <div className="sector-columns">
        <SectorList
          title="行业板块"
          boards={data?.industries || []}
          openCode={openBoard?.code || ""}
          onOpen={openConstituents}
        />
        <SectorList
          title="概念板块"
          boards={data?.concepts || []}
          openCode={openBoard?.code || ""}
          onOpen={openConstituents}
        />
      </div>
      {openBoard && (
        <div className="sector-cons">
          <h4>
            {openBoard.name} · 成分股{consLoading ? "加载中…" : ` ${constituents.length}`}
          </h4>
          <div className="sector-cons-list">
            {constituents.map((item) => (
              <button key={item.symbol} onClick={() => onSelect(item.symbol)}>
                <span>{item.name}</span>
                <em className={(item.pct_chg || 0) >= 0 ? "up" : "down"}>
                  {(item.pct_chg ?? 0).toFixed(2)}%
                </em>
              </button>
            ))}
          </div>
        </div>
      )}
    </div>
  );
}

function SectorList({
  title,
  boards,
  openCode,
  onOpen,
}: {
  title: string;
  boards: SectorBoard[];
  openCode: string;
  onOpen: (board: SectorBoard) => void;
}) {
  return (
    <div className="sector-list">
      <h4>{title}</h4>
      {!boards.length && <p className="sector-meta">暂无数据</p>}
      {boards.map((board, index) => (
        <button
          key={`${board.kind}-${board.code || board.name}`}
          className={`sector-row ${openCode && openCode === board.code ? "active" : ""} ${board.code ? "" : "plain"}`}
          onClick={() => onOpen(board)}
          title={board.code ? "点击查看成分股" : "该板块无成分股数据"}
        >
          <span className="sector-rank">{index + 1}</span>
          <span className="sector-name">{board.name}</span>
          <span className="sector-pct">{(board.pct_chg ?? 0).toFixed(2)}%</span>
          <span className="sector-leader">{board.leader}</span>
        </button>
      ))}
    </div>
  );
}
