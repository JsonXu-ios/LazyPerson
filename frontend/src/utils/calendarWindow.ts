import type { KlinePayload } from "../types";

const DAY_MS = 24 * 60 * 60 * 1000;

export function sliceDailyPayloadByCalendarDays(payload: KlinePayload | null, days: number, mode: "calendar" | "bars" = "calendar") {
  if (!payload || payload.period !== "day" || !payload.bars.length) return payload;

  const latestDate = parseBarDate(payload.bars[payload.bars.length - 1].time);
  if (!latestDate) return payload;

  const cutoff = new Date(latestDate.getTime() - days * DAY_MS);
  const keepWeekends = isCryptoSymbol(payload.symbol);
  const validItems = payload.bars
    .map((bar, index) => ({ bar, index, date: parseBarDate(bar.time) }))
    .filter((item) => {
      if (!item.date || (!keepWeekends && !isWeekday(item.date))) return false;
      return item.bar.open !== null && item.bar.high !== null && item.bar.low !== null && item.bar.close !== null;
    });
  const selected = mode === "bars"
    ? validItems.slice(-days)
    : validItems.filter((item) => item.date && item.date >= cutoff);

  if (!selected.length || selected.length === payload.bars.length) return payload;

  return {
    ...payload,
    bars: selected.map((item) => item.bar),
    indicators: sliceIndicatorsByIndices(payload.indicators, selected.map((item) => item.index)),
  };
}

function parseBarDate(value: string) {
  const normalized = value.includes(" ") ? value.replace(" ", "T") : `${value}T00:00:00`;
  const timestamp = Date.parse(normalized);
  return Number.isNaN(timestamp) ? null : new Date(timestamp);
}

function isWeekday(date: Date) {
  const day = date.getDay();
  return day !== 0 && day !== 6;
}

function isCryptoSymbol(symbol: string) {
  return symbol.toUpperCase().endsWith("-USD");
}

function sliceIndicatorsByIndices(indicators: KlinePayload["indicators"], indices: number[]) {
  return Object.fromEntries(
    Object.entries(indicators || {}).map(([group, series]) => [
      group,
      Object.fromEntries(
        Object.entries(series).map(([name, values]) => [name, indices.map((index) => values[index] ?? null)]),
      ),
    ]),
  );
}

export function countWeekendBars(payload: KlinePayload | null) {
  if (!payload) return 0;
  return payload.bars.filter((bar) => {
    const date = parseBarDate(bar.time);
    return date ? !isWeekday(date) : false;
  }).length;
}
