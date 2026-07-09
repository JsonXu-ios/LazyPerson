import type { DataQuality } from "../types";

export function formatNumber(value: number | null | undefined, digits = 2) {
  if (value === null || value === undefined || Number.isNaN(value)) return "-";
  if (Math.abs(value) >= 100000000) return `${(value / 100000000).toFixed(2)}亿`;
  if (Math.abs(value) >= 10000) return `${(value / 10000).toFixed(2)}万`;
  return value.toFixed(digits);
}

export function formatPercent(value: number | null | undefined) {
  if (value === null || value === undefined || Number.isNaN(value)) return "-";
  return `${value.toFixed(2)}%`;
}

export function formatTime(value: string | null | undefined) {
  if (!value) return "-";
  return value.replace("T", " ").replace("+08:00", "");
}

export function qualityText(quality: DataQuality | null | undefined) {
  if (!quality) return "未同步";
  if (quality.message) return quality.message;
  const cache = quality.from_cache ? "缓存" : "实时";
  return `${quality.source} · ${cache}${quality.stale ? " · 过期" : ""}`;
}

export function qualityTone(quality: DataQuality | null | undefined) {
  if (!quality) return "muted";
  if (quality.fallback || quality.stale) return "warn";
  if (quality.from_cache) return "cache";
  return "live";
}

export function normalizeError(error: unknown) {
  if (error instanceof Error) {
    return error.message || "请求失败，请稍后重试";
  }
  return "请求失败，请稍后重试";
}

export function quoteName(symbol: string, name?: string | null) {
  return name && name.trim() ? name : symbol;
}

