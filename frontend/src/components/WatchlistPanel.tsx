import { Plus, Search, Star, Trash2 } from "lucide-react";
import type { Quote, SymbolItem, WatchlistItem } from "../types";
import { formatNumber, formatPercent, quoteName } from "../utils/format";

type SortKey = "custom" | "pct" | "amount" | "price";

type Props = {
  query: string;
  results: SymbolItem[];
  watchlist: WatchlistItem[];
  quotes: Quote[];
  selected: string;
  sortKey: SortKey;
  panelLabel: string;
  onQueryChange: (value: string) => void;
  onSortChange: (value: SortKey) => void;
  onAdd: (symbol: string) => void;
  onRemove: (symbol: string) => void;
  onSelect: (symbol: string) => void;
};

export function WatchlistPanel({
  query,
  results,
  watchlist,
  quotes,
  selected,
  sortKey,
  panelLabel,
  onQueryChange,
  onSortChange,
  onAdd,
  onRemove,
  onSelect,
}: Props) {
  const quoteMap = new Map(quotes.map((quote) => [quote.symbol, quote]));
  const sorted = [...watchlist].sort((a, b) => {
    const qa = quoteMap.get(a.symbol);
    const qb = quoteMap.get(b.symbol);
    if (sortKey === "pct") return (qb?.pct_chg ?? -999) - (qa?.pct_chg ?? -999);
    if (sortKey === "amount") return (qb?.amount ?? 0) - (qa?.amount ?? 0);
    if (sortKey === "price") return (qb?.price ?? 0) - (qa?.price ?? 0);
    return a.sort_order - b.sort_order;
  });

  return (
    <aside className="watch-panel">
      <div className="panel-title">
        <div>
          <h2>自选资产</h2>
          <span>{watchlist.length} 个</span>
        </div>
        <select value={sortKey} onChange={(event) => onSortChange(event.target.value as SortKey)}>
          <option value="custom">自定义</option>
          <option value="pct">涨跌幅</option>
          <option value="amount">成交额</option>
          <option value="price">价格</option>
        </select>
      </div>

      <div className="search-box v2">
        <Search size={16} />
        <input
          value={query}
          onChange={(event) => onQueryChange(event.target.value)}
          placeholder={`在${panelLabel}中搜索代码 / 名称`}
        />
      </div>

      {results.length > 0 && (
        <div className="search-results v2">
          {results.map((item) => (
            <button key={item.symbol} onClick={() => onAdd(item.symbol)}>
              <Plus size={14} />
              <span>{item.display}</span>
            </button>
          ))}
        </div>
      )}

      <div className="watch-table">
        {sorted.map((item) => {
          const quote = quoteMap.get(item.symbol);
          const up = (quote?.pct_chg || 0) >= 0;
          return (
            <button
              className={`watch-card ${selected === item.symbol ? "active" : ""}`}
              key={`${item.group_name}-${item.symbol}`}
              onClick={() => onSelect(item.symbol)}
            >
              <span className="watch-main">
                <strong>{quoteName(item.symbol, item.name || quote?.name)}</strong>
                <small>
                  <Star size={11} />
                  {item.symbol}.{item.market || quote?.market || "--"}
                </small>
              </span>
              <span className="watch-price">
                <strong>{formatNumber(quote?.price)}</strong>
                <small className={up ? "rise" : "fall"}>{formatPercent(quote?.pct_chg)}</small>
              </span>
              <span className="watch-extra">
                <small>额 {formatNumber(quote?.amount)}</small>
                <small>换 {formatPercent(quote?.turnover)}</small>
              </span>
              <span
                className="mini-remove"
                onClick={(event) => {
                  event.stopPropagation();
                  onRemove(item.symbol);
                }}
                title="移除"
              >
                <Trash2 size={13} />
              </span>
            </button>
          );
        })}
      </div>
    </aside>
  );
}
