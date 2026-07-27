# 抢钱流（全A股档位扫描）设计文档

日期：2026-07-27
状态：已确认

## 背景与目标

K 线图 A 股面板已有基于 90 自然日最低价的档位线（每 10% 一条，主档位每 20% 一条：0%、20%、40%…200% 及以上）。档位价格 = 90 日窗口最低价 × (1 + N%)。

新增"抢钱流"功能：扫描全部 A 股，找出**当前价格处于某个 20% 主档位区间上半段**的股票，即价格超过区间下沿至少 10%（例：价格位于 20%~40% 档位之间且高于 +30% 位置）。

## 筛选逻辑（与 K 线图口径一致）

对每只股票：

1. 取近 **90 自然日** 的日线（与前端 `sliceDailyPayloadByCalendarDays` + `computeAutoDrawing` 口径一致，qfq 复权）。
2. `low90 = 窗口内所有 bar 的最低 low`。
3. `pct = (最新价 / low90 − 1) × 100`，最新价取盘中实时快照价（收盘后即收盘价）。
4. `band = floor(pct / 20) × 20`（所在 20% 主档位区间下沿）。
5. **命中条件：`pct − band > 10`**（严格大于，处于区间上半段）。

### 排除规则

- 北交所股票（代码 4/8 开头，只扫沪深两市 60/00/30/68 开头）。
- ST / *ST（名称含 "ST"）。
- 上市不足 90 天：拉到的日线最早一根晚于（今日 − 90 自然日）则跳过。
- 无最新价（停牌/异常）或日线不足 20 根的跳过。

## 方案：后台任务 + 进度轮询

全 A 股约 5400 只，每只需 90 天日线算低点。首次全量扫描约 3~10 分钟；日线走现有缓存（`MarketService.kline`，day TTL），后续扫描明显加快。

### 后端

新增 `backend/app/scanner.py`：

- `MoneyGrabScanner`（模块级单例任务状态）：
  - **股票清单+最新价**：一次全市场实时快照（efinance `stock.get_realtime_quotes()`，akshare `stock_zh_a_spot_em` 次之）；两者都依赖东方财富接口，在东财不可达的环境下用第三级兜底：本地 symbols 表的沪深A股清单 + 腾讯行情按 80 只/批分批拉取。
  - **90 日低点**：复用 `MarketService.kline(symbol, period="day", limit=140)`（多数据源 + SQLite 缓存），按自然日切出近 90 天窗口取最低 low。
  - 线程池并发（约 8 workers，避免 SQLite 写锁竞争），逐只计算并累计进度。
  - 任务状态：`idle / running / done / failed`，含 `total / done / hits / started_at / finished_at / error`。
  - 完成后结果写入缓存（当天有效），重启后端或刷新页面可直接读上次结果。
  - 重复触发扫描时若已在 running 则直接返回当前进度（不重复启动）。

新增路由（`main.py`）：

- `POST /api/moneygrab/scan?refresh=false`：启动扫描（幂等）；返回当前状态。
- `GET /api/moneygrab/scan/status`：返回状态 + 进度 + 结果列表。

结果行字段：`symbol / name / price / low90 / pct / band / over`（over = pct − band − 10，超出区间中线的幅度，用于排序）。

### 前端

- `api.ts`：新增 `startMoneyGrabScan()`、`getMoneyGrabScanStatus()`。
- 新组件 `MoneyGrabPanel.tsx`：复用现有 drawer 模式（watchlist/summary 同款），仅 A 股面板显示入口按钮"抢钱流"。
  - 未扫描：显示"开始扫描"按钮。
  - 扫描中：进度条（done/total），每 2 秒轮询一次 status。
  - 完成：结果表格（代码、名称、最新价、90日低点、当前涨幅、所在档位区间如 "20%~40%"、超出幅度），按超出幅度降序；点击行切换主图到该股票。

### 测试

- pytest：档位命中函数（边界：pct=10 不命中、10.01 命中、30 不命中、31 命中、负 pct 不命中）、排除规则（北交所/ST/新股/停牌）。
- 复用现有 tests/ 结构。

## 不做的事（YAGNI）

- 不做定时自动扫描（后续可加）。
- 不做扫描历史记录/回测。
- 不做美股/黄金/加密面板的扫描。
