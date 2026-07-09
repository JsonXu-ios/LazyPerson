import { Clock, Database, RefreshCw } from "lucide-react";
import type { DataQuality } from "../types";
import { qualityText, qualityTone } from "../utils/format";

type Props = {
  backendStatus: string;
  quoteQuality: DataQuality | null;
  klineQuality: DataQuality | null;
  loading: boolean;
  onRefresh: () => void;
};

export function StatusBar({ backendStatus, quoteQuality, klineQuality, loading, onRefresh }: Props) {
  const now = new Date().toLocaleString("zh-CN", { hour12: false });

  return (
    <header className="status-bar">
      <div className="brand-block">
        <h1>LazyPerson</h1>
        <span>多市场走势分析工作台</span>
      </div>
      <div className="status-cluster">
        <span className="status-pill">
          <Clock size={14} />
          {now}
        </span>
        <span className="status-pill">
          <Database size={14} />
          {backendStatus}
        </span>
        <span className={`status-pill ${qualityTone(quoteQuality)}`}>{qualityText(quoteQuality)}</span>
        <span className={`status-pill ${qualityTone(klineQuality)}`}>{qualityText(klineQuality)}</span>
        <button className="icon-button primary" onClick={onRefresh} title="刷新全部" disabled={loading}>
          <RefreshCw size={17} className={loading ? "spin" : ""} />
        </button>
      </div>
    </header>
  );
}
