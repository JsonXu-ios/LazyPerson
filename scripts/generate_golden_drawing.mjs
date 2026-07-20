// 生成自动画线 / 窗口切片的 golden 对拍数据。
// 直接运行网页版 TS 源码（经 esbuild 打包），输出到 app/test/fixtures/。
// 用法: node scripts/generate_golden_drawing.mjs
import { execSync } from "node:child_process";
import { readFileSync, writeFileSync, mkdirSync, rmSync } from "node:fs";
import { fileURLToPath, pathToFileURL } from "node:url";
import path from "node:path";

const root = path.dirname(path.dirname(fileURLToPath(import.meta.url)));
const fixtures = path.join(root, "app", "test", "fixtures");
const tmp = path.join(root, "scripts", ".golden-tmp");
mkdirSync(tmp, { recursive: true });

const entry = path.join(tmp, "entry.ts");
writeFileSync(
  entry,
  `export { computeAutoDrawing } from "${path
    .join(root, "frontend/src/utils/autoDrawing")
    .replace(/\\/g, "/")}";
export { sliceDailyPayloadByCalendarDays } from "${path
    .join(root, "frontend/src/utils/calendarWindow")
    .replace(/\\/g, "/")}";`,
);

const bundle = path.join(tmp, "bundle.mjs");
execSync(
  `"${path.join(root, "frontend/node_modules/.bin/esbuild")}" "${entry}" --bundle --format=esm --outfile="${bundle}"`,
  { stdio: "inherit" },
);

const { computeAutoDrawing, sliceDailyPayloadByCalendarDays } = await import(
  pathToFileURL(bundle).href
);

// A 股面板参数：90 自然日窗口 / lineStep 10 / 延伸超 100%
const symbols = ["002138", "600519", "300750", "000001"];
for (const symbol of symbols) {
  const bars = JSON.parse(
    readFileSync(path.join(fixtures, `bars_${symbol}.json`), "utf-8"),
  );
  const payload = { symbol, period: "day", adjust: "qfq", bars, indicators: {} };
  const sliced = sliceDailyPayloadByCalendarDays(payload, 90, "calendar");
  const auto = computeAutoDrawing(sliced.bars, 90, 10, true);
  writeFileSync(
    path.join(fixtures, `auto_drawing_${symbol}.json`),
    JSON.stringify(
      {
        slicedTimes: sliced.bars.map((bar) => bar.time),
        autoDrawing: auto && {
          direction: auto.direction,
          windowSize: auto.windowSize,
          recentHigh: auto.recentHigh,
          recentLow: auto.recentLow,
          base: auto.base,
          target: auto.target,
          levels: auto.levels,
          trendSegments: auto.trendSegments.map((segment) => ({
            id: segment.id,
            label: segment.label,
            direction: segment.direction,
            start: segment.start,
            end: segment.end,
          })),
          nearestLevel: auto.nearestLevel,
          nearestDistancePct: auto.nearestDistancePct,
        },
      },
      null,
      0,
    ),
  );
  console.log(
    `${symbol}: sliced ${sliced.bars.length} bars, segments ${auto?.trendSegments.length ?? 0}`,
  );
}

rmSync(tmp, { recursive: true, force: true });
