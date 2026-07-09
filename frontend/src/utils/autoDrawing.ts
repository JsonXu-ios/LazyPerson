import type { KlineBar } from "../types";

export type AutoTrendDirection = "up" | "down" | "flat";

export type AutoLineLevel = {
  label: string;
  percent: number;
  price: number;
};

export type AutoTrendSegment = {
  id: string;
  label: string;
  direction: "up" | "down";
  points?: Array<{
    time: string;
    price: number;
    index: number;
  }>;
  start: {
    time: string;
    price: number;
    index: number;
  };
  end: {
    time: string;
    price: number;
    index: number;
  };
};

export type AutoDrawing = {
  direction: AutoTrendDirection;
  windowSize: number;
  latest: KlineBar;
  recentHigh: {
    time: string;
    price: number;
    index: number;
  };
  recentLow: {
    time: string;
    price: number;
    index: number;
  };
  base: {
    time: string;
    price: number;
    label: string;
  };
  target: {
    time: string;
    price: number;
    label: string;
  };
  levels: AutoLineLevel[];
  trendSegments: AutoTrendSegment[];
  nearestLevel: AutoLineLevel | null;
  nearestDistancePct: number | null;
};

export type AutoLineColorMap = Record<string, string>;

const DEFAULT_WINDOW = 90;
const STORAGE_KEY = "lazy-person:auto-line-colors:v3";
const DEFAULT_YELLOW = "#f6d36b";
const SWING_RADIUS = 1;
const MIN_CHANNEL_SPAN = 6;
const RECENT_CHANNEL_LOOKBACK = 35;
const DEFAULT_COLORS: AutoLineColorMap = {
  "0%": DEFAULT_YELLOW,
  "+10%": DEFAULT_YELLOW,
  "+20%": "#f24d4d",
  "+30%": DEFAULT_YELLOW,
  "+40%": DEFAULT_YELLOW,
  "+50%": "#1f6feb",
  "+60%": DEFAULT_YELLOW,
  "+70%": DEFAULT_YELLOW,
  "+80%": "#ffffff",
  "+90%": DEFAULT_YELLOW,
  "+100%": DEFAULT_YELLOW,
};

type Pivot = {
  time: string;
  price: number;
  index: number;
};

type TrendChannel = {
  direction: "up" | "down";
  startIndex: number;
  endIndex: number;
  slope: number;
  intercept: number;
  offset: number;
  score: number;
};

export function computeAutoDrawing(
  bars: KlineBar[],
  windowSize = DEFAULT_WINDOW,
  levelStep = 10,
  extendLevelsBeyond100 = false,
): AutoDrawing | null {
  const valid = bars.filter((bar) => bar.high !== null && bar.low !== null && bar.close !== null);
  if (valid.length < 20) return null;

  const recent = valid.slice(-windowSize);
  let highIndex = 0;
  let lowIndex = 0;

  recent.forEach((bar, index) => {
    if (Number(bar.high) > Number(recent[highIndex].high)) highIndex = index;
    if (Number(bar.low) < Number(recent[lowIndex].low)) lowIndex = index;
  });

  const highBar = recent[highIndex];
  const lowBar = recent[lowIndex];
  const latest = recent[recent.length - 1];
  const highPrice = Number(highBar.high);
  const lowPrice = Number(lowBar.low);
  const close = Number(latest.close);
  const trendSegments = buildTrendSegments(recent);
  const direction: AutoTrendDirection = trendSegments[0]?.direction
    || (highIndex > lowIndex ? "up" : lowIndex > highIndex ? "down" : "flat");
  const levels = buildLevels(lowPrice, highPrice, levelStep, extendLevelsBeyond100);
  const nearestLevel = levels.reduce<AutoLineLevel | null>((nearest, level) => {
    if (!nearest) return level;
    return Math.abs(level.price - close) < Math.abs(nearest.price - close) ? level : nearest;
  }, null);

  return {
    direction,
    windowSize: recent.length,
    latest,
    recentHigh: {
      time: highBar.time,
      price: highPrice,
      index: highIndex,
    },
    recentLow: {
      time: lowBar.time,
      price: lowPrice,
      index: lowIndex,
    },
    base: {
      time: lowBar.time,
      price: lowPrice,
      label: `${windowSize}自然日低点`,
    },
    target: {
      time: highBar.time,
      price: highPrice,
      label: `${windowSize}自然日高点`,
    },
    levels,
    trendSegments,
    nearestLevel,
    nearestDistancePct:
      nearestLevel && close ? Number((((nearestLevel.price - close) / close) * 100).toFixed(2)) : null,
  };
}

function buildLevels(lowPrice: number, highPrice: number, levelStep: number, extendLevelsBeyond100: boolean) {
  const levels: AutoLineLevel[] = [];
  let step = 0;
  const safeStep = Math.max(1, levelStep);
  while (extendLevelsBeyond100 || step <= 100) {
    const price = lowPrice * (1 + step / 100);
    if (!extendLevelsBeyond100 && price > highPrice && step > 0) break;
    levels.push({
      label: step === 0 ? "0%" : `+${step}%`,
      percent: step,
      price: roundPrice(price),
    });
    if (extendLevelsBeyond100 && price > highPrice && step > 0) break;
    step += safeStep;
  }
  return levels;
}

function buildTrendSegments(bars: KlineBar[]) {
  if (bars.length < 20) return [];
  const completedBars = isCurrentDateBar(bars[bars.length - 1]) ? bars.slice(0, -1) : bars;
  if (completedBars.length < 20) return [];
  return findTrendChannels(completedBars).flatMap((channel, index) => channelSegments(completedBars, channel, index + 1));
}

function isCurrentDateBar(bar: KlineBar | undefined) {
  if (!bar?.time) return false;
  return bar.time.slice(0, 10) === new Date().toISOString().slice(0, 10);
}

function channelSegments(bars: KlineBar[], channel: TrendChannel, order: number) {
  const baseStart = pointOnLine(bars, channel.startIndex, channel.slope, channel.intercept);
  const baseEnd = pointOnLine(bars, channel.endIndex, channel.slope, channel.intercept);
  const parallelStart = pointOnLine(bars, channel.startIndex, channel.slope, channel.intercept + channel.offset);
  const parallelEnd = pointOnLine(bars, channel.endIndex, channel.slope, channel.intercept + channel.offset);
  if (!isChannelInPriceRange(bars, [baseStart, baseEnd, parallelStart, parallelEnd])) return [];

  if (channel.direction === "down") {
    return [
      segment(`descending-${order}-upper-channel`, `下降通道${order}上轨`, "down", baseStart, baseEnd),
      segment(`descending-${order}-lower-channel`, `下降通道${order}下轨`, "down", parallelStart, parallelEnd),
    ];
  }
  return [
    segment(`ascending-${order}-lower-channel`, `上升通道${order}下轨`, "up", baseStart, baseEnd),
    segment(`ascending-${order}-upper-channel`, `上升通道${order}上轨`, "up", parallelStart, parallelEnd),
  ];
}

function isChannelInPriceRange(bars: KlineBar[], points: Pivot[]) {
  const highs = bars.map((bar) => Number(bar.high)).filter(Number.isFinite);
  const lows = bars.map((bar) => Number(bar.low)).filter((value) => Number.isFinite(value) && value > 0);
  if (!highs.length || !lows.length) return false;
  const minLow = Math.min(...lows);
  const maxHigh = Math.max(...highs);
  const range = Math.max(maxHigh - minLow, minLow * 0.1, 0.01);
  const minAllowed = Math.max(0.01, minLow - range * 1.2);
  const maxAllowed = maxHigh + range * 1.2;
  return points.every((point) => (
    Number.isFinite(point.price)
    && point.price > 0
    && point.price >= minAllowed
    && point.price <= maxAllowed
  ));
}

function findTrendChannels(bars: KlineBar[]) {
  const latestExtreme = findLatestExtremeChannel(bars);
  if (latestExtreme) return [latestExtreme];

  const swings = findSwingPivots(bars);
  const ascending = findAscendingChannel(bars, swings);
  const descending = findDescendingChannel(bars, swings);
  const latest = [ascending, descending]
    .filter((channel): channel is TrendChannel => Boolean(channel))
    .sort((a, b) => b.startIndex - a.startIndex || b.score - a.score)[0];
  return latest ? [latest] : [];
}

function findLatestExtremeChannel(bars: KlineBar[]): TrendChannel | null {
  const recentStart = Math.max(0, bars.length - RECENT_CHANNEL_LOOKBACK);
  const channelEnd = bars.length - 1;
  const recentBars = bars.slice(recentStart);
  const recentLow = minPivot(recentBars, recentStart, "low");
  const highAfterLow = maxPivot(bars.slice(recentLow.index), recentLow.index, "high");
  const recentHigh = maxPivot(recentBars, recentStart, "high");
  const lowAfterHigh = minPivot(bars.slice(recentHigh.index), recentHigh.index, "low");
  const priceRange = Math.max(...recentBars.map((bar) => Number(bar.high))) - Math.min(...recentBars.map((bar) => Number(bar.low)));
  const tolerance = Math.max(priceRange * 0.025, 0.01);

  if (recentLow.index < highAfterLow.index && highAfterLow.index >= channelEnd - 1) {
    const latestLow = Number(bars[channelEnd].low);
    if (Number.isFinite(latestLow) && latestLow > recentLow.price) {
      const span = channelEnd - recentLow.index;
      const slope = (latestLow - recentLow.price) / Math.max(span, 1);
      if (slope > 0) {
        const intercept = recentLow.price - slope * recentLow.index;
        const offset = Math.max(...recentBars
          .filter((_, index) => recentStart + index >= recentLow.index)
          .map((bar, index) => Number(bar.high) - lineValue(slope, intercept, recentStart + index)));
        if (offset > tolerance) {
          return {
            direction: "up",
            startIndex: recentLow.index,
            endIndex: channelEnd,
            slope,
            intercept,
            offset,
            score: 10000 + highAfterLow.index,
          };
        }
      }
    }
  }

  if (recentHigh.index < lowAfterHigh.index && lowAfterHigh.index >= channelEnd - 1) {
    const latestHigh = Number(bars[channelEnd].high);
    if (Number.isFinite(latestHigh) && latestHigh < recentHigh.price) {
      const span = channelEnd - recentHigh.index;
      const slope = (latestHigh - recentHigh.price) / Math.max(span, 1);
      if (slope < 0) {
        const intercept = recentHigh.price - slope * recentHigh.index;
        const offset = Math.min(...recentBars
          .filter((_, index) => recentStart + index >= recentHigh.index)
          .map((bar, index) => Number(bar.low) - lineValue(slope, intercept, recentStart + index)));
        if (offset < -tolerance) {
          return {
            direction: "down",
            startIndex: recentHigh.index,
            endIndex: channelEnd,
            slope,
            intercept,
            offset,
            score: 10000 + recentLow.index,
          };
        }
      }
    }
  }

  return null;
}

function findAscendingChannel(bars: KlineBar[], swings: ReturnType<typeof findSwingPivots>): TrendChannel | null {
  const lows = ensureEndpointLows(swings.lows, bars);
  if (lows.length < 2 || !swings.highs.length) return null;

  const recentStart = Math.max(0, bars.length - RECENT_CHANNEL_LOOKBACK);
  const channelEnd = bars.length - 1;
  const recentHigh = maxPivot(bars.slice(recentStart), recentStart, "high");
  const recentLow = minPivot(bars.slice(recentStart), recentStart, "low");
  const highs = bars.map((bar) => Number(bar.high));
  const lowsRaw = bars.map((bar) => Number(bar.low));
  const priceRange = Math.max(...highs) - Math.min(...lowsRaw);
  const tolerance = Math.max(priceRange * 0.025, 0.01);
  let best: TrendChannel | null = null;

  for (let start = 0; start < lows.length - 1; start += 1) {
    for (let end = start + 1; end < lows.length; end += 1) {
      const first = lows[start];
      const second = lows[end];
      if (first.index < recentStart || second.index < recentStart) continue;
      if (first.index > recentHigh.index || first.index > recentLow.index) continue;
      const span = second.index - first.index;
      if (span < MIN_CHANNEL_SPAN) continue;

      const slope = (second.price - first.price) / span;
      if (slope <= 0) continue;

      const intercept = first.price - slope * first.index;
      const lowsInRange = lows.filter((pivot) => pivot.index >= first.index && pivot.index <= channelEnd);
      const highsInRange = uniquePivots([...swings.highs, recentHigh])
        .filter((pivot) => pivot.index >= first.index && pivot.index <= channelEnd);
      if (!highsInRange.length) continue;

      const lowsAfterLine = lowsInRange.filter((pivot) => pivot.price >= lineValue(slope, intercept, pivot.index) - tolerance).length;
      const touches = lowsInRange.filter((pivot) => Math.abs(pivot.price - lineValue(slope, intercept, pivot.index)) <= tolerance).length;
      const breaks = lowsInRange.length - lowsAfterLine;
      const offset = Math.max(...highsInRange.map((pivot) => pivot.price - lineValue(slope, intercept, pivot.index)));
      if (offset <= tolerance) continue;

      const slopeScore = (slope / Math.max(priceRange, 0.01)) * bars.length * 240;
      const recencyScore = second.index * 4 + first.index;
      const fitScore = touches * 45 + lowsAfterLine * 12 - breaks * 120;
      const score = recencyScore + slopeScore + fitScore;
      if (!best || score > best.score) {
        best = {
          direction: "up",
          startIndex: first.index,
          endIndex: channelEnd,
          slope,
          intercept,
          offset,
          score,
        };
      }
    }
  }

  return best;
}

function findDescendingChannel(bars: KlineBar[], swings: ReturnType<typeof findSwingPivots>): TrendChannel | null {
  const highs = ensureEndpointHighs(swings.highs, bars);
  if (highs.length < 2 || !swings.lows.length) return null;

  const recentStart = Math.max(0, bars.length - RECENT_CHANNEL_LOOKBACK);
  const channelEnd = bars.length - 1;
  const recentHigh = maxPivot(bars.slice(recentStart), recentStart, "high");
  const recentLow = minPivot(bars.slice(recentStart), recentStart, "low");
  const highValues = bars.map((bar) => Number(bar.high));
  const lowValues = bars.map((bar) => Number(bar.low));
  const priceRange = Math.max(...highValues) - Math.min(...lowValues);
  const tolerance = Math.max(priceRange * 0.025, 0.01);
  let best: TrendChannel | null = null;

  for (let start = 0; start < highs.length - 1; start += 1) {
    for (let end = start + 1; end < highs.length; end += 1) {
      const first = highs[start];
      const second = highs[end];
      if (first.index < recentStart || second.index < recentStart) continue;
      if (first.index > recentHigh.index || first.index > recentLow.index) continue;
      const span = second.index - first.index;
      if (span < MIN_CHANNEL_SPAN) continue;

      const slope = (second.price - first.price) / span;
      if (slope >= 0) continue;

      const intercept = first.price - slope * first.index;
      const highsInRange = highs.filter((pivot) => pivot.index >= first.index && pivot.index <= channelEnd);
      const lowsInRange = uniquePivots([...swings.lows, recentLow])
        .filter((pivot) => pivot.index >= first.index && pivot.index <= channelEnd);
      if (!lowsInRange.length) continue;

      const highsBelowLine = highsInRange.filter((pivot) => pivot.price <= lineValue(slope, intercept, pivot.index) + tolerance).length;
      const touches = highsInRange.filter((pivot) => Math.abs(pivot.price - lineValue(slope, intercept, pivot.index)) <= tolerance).length;
      const breaks = highsInRange.length - highsBelowLine;
      const offset = Math.min(...lowsInRange.map((pivot) => pivot.price - lineValue(slope, intercept, pivot.index)));
      if (offset >= -tolerance) continue;

      const projectedLatest = lineValue(slope, intercept, channelEnd);
      const latestHigh = Number(bars[channelEnd].high);
      if (latestHigh > projectedLatest + tolerance) continue;
      const latestDistance = Math.max(projectedLatest - latestHigh, 0);
      const slopeScore = (Math.abs(slope) / Math.max(priceRange, 0.01)) * bars.length * 240;
      const recencyScore = second.index * 4 + first.index;
      const fitScore = touches * 45 + highsBelowLine * 12 - breaks * 120 - latestDistance * 4;
      const score = recencyScore + slopeScore + fitScore;
      if (!best || score > best.score) {
        best = {
          direction: "down",
          startIndex: first.index,
          endIndex: channelEnd,
          slope,
          intercept,
          offset,
          score,
        };
      }
    }
  }

  return best;
}

function findSwingPivots(bars: KlineBar[]) {
  const lows: Pivot[] = [];
  const highs: Pivot[] = [];

  for (let index = SWING_RADIUS; index < bars.length - SWING_RADIUS; index += 1) {
    const window = bars.slice(index - SWING_RADIUS, index + SWING_RADIUS + 1);
    const low = Number(bars[index].low);
    const high = Number(bars[index].high);
    if (window.every((bar) => low <= Number(bar.low))) {
      lows.push(pivotFromBar(bars[index], index, "low"));
    }
    if (window.every((bar) => high >= Number(bar.high))) {
      highs.push(pivotFromBar(bars[index], index, "high"));
    }
  }

  return { lows, highs };
}

function ensureEndpointLows(lows: Pivot[], bars: KlineBar[]) {
  const midpoint = Math.floor(bars.length / 2);
  const finalStart = Math.max(0, bars.length - 12);
  const firstLow = minPivot(bars.slice(0, midpoint + 1), 0, "low");
  const secondLow = minPivot(bars.slice(midpoint), midpoint, "low");
  const finalLow = minPivot(bars.slice(finalStart), finalStart, "low");
  const byIndex = new Map<number, Pivot>();
  [...lows, firstLow, secondLow, finalLow].forEach((pivot) => byIndex.set(pivot.index, pivot));
  return [...byIndex.values()].sort((a, b) => a.index - b.index);
}

function ensureEndpointHighs(highs: Pivot[], bars: KlineBar[]) {
  const midpoint = Math.floor(bars.length / 2);
  const finalStart = Math.max(0, bars.length - 12);
  const firstHigh = maxPivot(bars.slice(0, midpoint + 1), 0, "high");
  const secondHigh = maxPivot(bars.slice(midpoint), midpoint, "high");
  const finalHigh = maxPivot(bars.slice(finalStart), finalStart, "high");
  const byIndex = new Map<number, Pivot>();
  [...highs, firstHigh, secondHigh, finalHigh].forEach((pivot) => byIndex.set(pivot.index, pivot));
  return [...byIndex.values()].sort((a, b) => a.index - b.index);
}

function uniquePivots(pivots: Pivot[]) {
  const byIndex = new Map<number, Pivot>();
  pivots.forEach((pivot) => byIndex.set(pivot.index, pivot));
  return [...byIndex.values()].sort((a, b) => a.index - b.index);
}

function maxPivot(bars: KlineBar[], offset: number, kind: "high" | "low"): Pivot {
  let selectedIndex = 0;
  bars.forEach((bar, index) => {
    if (Number(bar[kind]) > Number(bars[selectedIndex][kind])) selectedIndex = index;
  });
  return pivotFromBar(bars[selectedIndex], offset + selectedIndex, kind);
}

function minPivot(bars: KlineBar[], offset: number, kind: "high" | "low"): Pivot {
  let selectedIndex = 0;
  bars.forEach((bar, index) => {
    if (Number(bar[kind]) < Number(bars[selectedIndex][kind])) selectedIndex = index;
  });
  return pivotFromBar(bars[selectedIndex], offset + selectedIndex, kind);
}

function pointOnLine(bars: KlineBar[], index: number, slope: number, intercept: number): Pivot {
  return {
    time: bars[index].time,
    price: roundPrice(lineValue(slope, intercept, index)),
    index,
  };
}

function lineValue(slope: number, intercept: number, index: number) {
  return slope * index + intercept;
}

function pivotFromBar(bar: KlineBar, index: number, kind: "high" | "low"): Pivot {
  return {
    time: bar.time,
    price: Number(bar[kind]),
    index,
  };
}

function segment(
  id: string,
  label: string,
  direction: "up" | "down",
  start: Pivot,
  end: Pivot,
  points?: Pivot[],
): AutoTrendSegment {
  return {
    id,
    label,
    direction,
    points,
    start,
    end,
  };
}

function roundPrice(value: number) {
  return Number(value.toFixed(value >= 100 ? 2 : 3));
}

export function trendLabel(direction: AutoTrendDirection) {
  if (direction === "up") return "向上趋势";
  if (direction === "down") return "向下趋势";
  return "震荡观察";
}

export function defaultLineColors() {
  return { ...DEFAULT_COLORS };
}

export function loadLineColors(): AutoLineColorMap {
  try {
    const raw = window.localStorage.getItem(STORAGE_KEY);
    return raw ? { ...DEFAULT_COLORS, ...JSON.parse(raw) } : defaultLineColors();
  } catch {
    return defaultLineColors();
  }
}

export function saveLineColors(colors: AutoLineColorMap) {
  window.localStorage.setItem(STORAGE_KEY, JSON.stringify(colors));
}

export function colorForLevel(level: AutoLineLevel, colors: AutoLineColorMap, index = 0) {
  if (level.label === "+20%") return "#f24d4d";
  if (level.label === "+50%") return "#1f6feb";
  if (level.label === "+80%") return "#ffffff";
  return colors[level.label] || DEFAULT_COLORS[level.label] || (index >= 0 ? DEFAULT_YELLOW : DEFAULT_YELLOW);
}
