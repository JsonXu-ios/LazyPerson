# V4 Flutter 安卓应用实现方案

## 1. 目标与范围

把现有网页版行情终端转换为独立的 Android Flutter 应用（应用名 LazyPerson，logo 由 AI 生成）。

已确认的三个关键决策：

- 目标平台：Android 手机（竖屏优先）。
- 数据层：**Flutter 用 Dart 直连数据源**，不依赖本地 FastAPI 后端，App 随处可用。
- K 线图：**原生 CustomPaint 自绘**，不用 WebView、不用第三方 K 线库。

保留的功能（对齐网页版）：

- 四个市场面板：A 股 / 美股 / 黄金 / 比特币，各自默认标的与窗口配置（90 天日历窗口 / 180 根 bar 窗口）。
- 自选股：搜索、添加、删除、选中切换、排序（自定义 / 涨跌幅 / 成交额 / 价格）。
- 实时行情 + 日 K / 1m / 5m / 15m / 30m / 60m K 线。
- 自动画线：水平位（lineStep / majorLineStep / 超 100% 延伸 / 价格标注 / 标签避让）、趋势通道、近期高低点、最近关键位提示。
- 指标副图：MACD、LON。
- 信号提示条：大涨回撤（涨 30% 后回撤 20%）、上升 ±3%。
- 缓存优先 + 后台刷新（stale-while-revalidate），数据质量提示（来源 / 缓存 / 过期 / 兜底）。
- 线位颜色自定义（沿用浅黄色默认值）。

数据本地化（本次新增决策）：

- A 股只收录**上证 + 深证**（不含北交所），全量约 5000+ 只的清单与 **90 天日 K 全部落在本地** sqlite，超过 90 天的数据一律不保存。
- 首次启动有**数据初始化页**：拉清单 → 逐只同步 90 天日 K，显示进度与预计剩余时间，支持中断续传。
- 股票搜索**只查本地**（代码 / 名称 / 拼音首字母），不依赖在线联想。

一期明确不做（网页版中也未启用或使用频率低）：

- 资金流图（`MoneyFlowChart` 网页版已下线，App.tsx 未引用）。
- 手动自定义价格线 / 手动趋势线的拖拽编辑（触屏交互复杂，二期再做）。
- 复权切换 UI（固定 qfq，与网页版一致）。

## 2. 总体架构

```text
app/                          Flutter 工程（仓库新增子目录）
  lib/
    main.dart                 入口、主题、路由
    theme/                    深色终端风主题（对齐网页版配色 #080d16 等）
    models/                   KlineBar / Quote / SymbolItem / WatchlistItem / DataQuality
    data/
      providers/
        tencent_provider.dart    A 股实时行情 + 日K/分钟K（qt.gtimg.cn / ifzq.gtimg.cn）
        eastmoney_provider.dart  A 股兜底 + 搜索（push2/searchapi，efinance 的底层接口）
        yahoo_provider.dart      美股/黄金/比特币行情、K线、搜索（query1.finance.yahoo.com）
      market_repository.dart     多源降级 + 本地优先读写编排（移植 services.py 的 _fetch_with_cache）
      local_store.dart           sqflite：symbols 全量表、daily_bars 90天日K、watchlist、sync_state、短期缓存
      sync_service.dart          首次全量初始化、每日增量、断点续传、90 天裁剪（见 §5）
    logic/
      indicators.dart            MA/EMA/MACD/RSI/LON（移植 indicators.py）
      auto_drawing.dart          自动画线（移植 autoDrawing.ts，逻辑等价）
      calendar_window.dart       日历窗口/бар窗口切片（移植 calendarWindow.ts）
      watch_signals.dart         大涨回撤、上升±3% 信号（移植 App.tsx 内逻辑）
    state/                       Riverpod：面板、自选、行情、K线、信号、通知
    ui/
      home_screen.dart           单页主界面
      widgets/
        kline_chart/             CustomPaint K线（蜡烛+成交量+画线叠加+长按十字线）
        indicator_chart/         MACD/LON 副图 painter
        market_tabs.dart         四市场切换
        period_switch.dart       周期切换
        signal_strip.dart        信号提示条
        watchlist_sheet.dart     自选资产底部弹层（搜索/排序/增删/选中）
        summary_sheet.dart       资产信息底部弹层（含线位颜色设置）
        status_bar.dart          数据质量/刷新
```

原则：`logic/` 与 `data/` 完全不依赖 Flutter UI，可单元测试；网页版 TS 算法逐函数移植并用相同输入对拍。

## 3. 技术选型

| 事项 | 选择 | 说明 |
| --- | --- | --- |
| Flutter | 3.x stable | Material 3，深色主题 |
| 状态管理 | Riverpod | 与现有 hooks 式数据流对应自然 |
| 网络 | dio | 超时/重试/日志拦截器 |
| 本地存储 | sqflite + shared_preferences | sqflite 存自选股、symbol、K线缓存；prefs 存线位颜色、面板选中态 |
| 图表 | CustomPaint 自绘 | K 线主图 + MACD/LON 副图统一一套坐标系代码 |
| 图标 | flutter_launcher_icons | 由 AI 生成的 SVG/PNG logo 出全套 mipmap |

## 4. 数据源适配层（Dart 重写）

Python 侧五个 adapter 中，**akshare / baostock / efinance 是 Python 库无法移植**，但它们底层都是公开 HTTP 接口。Dart 侧收敛为三个 provider：

### 4.1 A 股（主：腾讯，备：东方财富）

股票范围：**只收录上证（SH）和深证（SZ）**，不含北交所。约 5000+ 只。

- 全市场清单 + 快照：东财 `https://push2.eastmoney.com/api/qt/clist/get` 分页拉取（fs 参数选沪市主板/科创板 + 深市主板/创业板），每页 100 只，约 55 页拿全所有股票的代码、名称、最新 OHLCV。这是初始化建库和每日增量更新的主通道。
- 实时行情（自选/当前标的）：`https://qt.gtimg.cn/q=sh600519,sz000001`，`~` 分隔字段，按 tencent_adapter.py 的字段位（3 现价、4 昨收、32 涨跌幅、36 量、38 换手）解析，GBK 解码。
- 日 K（单只）：`https://ifzq.gtimg.cn/appstock/app/fqkline/get?param=sh600519,day,,,90,qfq`（只取 90 天窗口所需根数）。
- 分钟 K：`https://ifzq.gtimg.cn/appstock/app/kline/mkline?param=sh600519,m5,,600`。
- 东财单只 K 线兜底：`https://push2his.eastmoney.com/api/qt/stock/kline/get`（klt=101/1/5/15/30/60，fqt=1）。
- 搜索：**纯本地**，对 sqflite 的 symbols 表按代码前缀 / 名称包含 / 拼音首字母匹配。拼音首字母在建库时用 `lpinyin` 包由名称本地生成，不依赖任何在线联想接口。

### 4.2 美股 / 黄金 / 比特币（Yahoo）

- 行情 + K 线：`https://query1.finance.yahoo.com/v8/finance/chart/{symbol}`，逐字段对齐 yahoo_adapter.py（含交易所时区转换、pct_chg 递推）。
- 搜索：`https://query1.finance.yahoo.com/v1/finance/search`，市场归类规则（CRYPTO/FUT/FX/US）原样移植。

### 4.3 降级与数据质量

移植 `services.py::_fetch_with_cache` 的完整语义到 `market_repository.dart`：

1. 日 K 优先返回未过期缓存（prefer_stale_cache：先陈旧缓存立即出图）。
2. 按 provider 顺序尝试，空数据/异常记入 warnings 继续下一个。
3. 全部失败回退陈旧缓存并标记 stale。
4. 实时行情全部失败时用最新日 K 兜底（fallback 标记 + 提示文案）。
5. 日 K 缓存校验：最新一根滞后超 14 天视为无效；A 股日 K 过滤周末和 OHLC 缺失行。

`DataQuality`（source/from_cache/stale/fallback/message/warnings）与提示文案原样保留。

### 4.4 内置数据

`services.py` 里的默认自选（002138/600519/000001/300750 + SPY/QQQ/GC=F/BTC-USD）和内置 symbol 表（AAPL/MSFT/NVDA/TSLA/GLD/XAUUSD=X/ETH-USD）作为首次启动种子写入 sqflite。

## 5. 本地数据库与初始化

### 5.1 表结构（sqflite）

- `watchlist(symbol, group_name, sort_order, note)`
- `symbols(symbol, market, name, pinyin_abbr, updated_at)` — **沪深全量清单**（约 5000+ 行）+ 内置全球标的，本地搜索的数据源
- `daily_bars(symbol, date, open, high, low, close, volume, amount, pct_chg, turnover)` — **沪深全量 90 天日 K**，主键 (symbol, date)
- `sync_state(symbol, last_synced_date, status)` — 每只股票的同步进度，支撑断点续传
- `frames(cache_key, ...)` — 分钟 K、全球标的（Yahoo）K 线/行情的短期 JSON 缓存

### 5.2 首次全量同步（后台进行，顶部进度条）

首次打开 App **直接进主界面**，全量同步在后台跑，主界面顶部显示一条细进度条与文案，不阻塞任何操作：

1. **拉清单**（约 55 页分页请求）：东财 clist 接口拉全沪深股票代码/名称/最新行情，本地生成拼音首字母，写入 `symbols` 表。文案"正在获取沪深股票清单 (2345/5540)"。
2. **拉 90 天日 K**（约 5000+ 次单只请求）：并发 8~10 路（腾讯为主、东财兜底），逐只写入 `daily_bars` 并更新 `sync_state`，自选标的优先。文案"同步日线 1234/5540 只，剩约 x 分钟"。
3. 全程**可中断可续传**：杀进程或断网后下次启动自动从 `sync_state` 未完成处继续，已完成部分不重拉；同步失败时顶部条变红，点按重试。
4. 同步期间查看的股票走"单只即时拉取"通道，不受全量进度影响；完成后落全局标记，顶部条消失。

体量估算：90 根 × 5100 只 ≈ 46 万行，sqlite 约 40~60MB；并发 10 路、单次 ~150ms 估算全量同步约 8~15 分钟（受接口限速影响，实测后调优并发与节流）。

### 5.3 日常增量更新与数据保留

- **每日增量**：启动或手动刷新时，用东财 clist 全市场快照（55 页）把**当天这根 bar** 批量 upsert 进 `daily_bars`——55 次请求覆盖全市场，不需要逐只拉取。
- **补缺口**：若本地最新日期落后超过 1 个交易日（如几天没开 App），当前查看/自选的标的即时单只拉齐；其余股票在后台低优先级逐只补齐（可在设置里手动触发"全量校准"，复用初始化进度页）。
- **只留 90 天**：每次同步后删除 `daily_bars` 中早于 90 个自然日的行，数据库体积恒定。
- 分钟 K 不入 `daily_bars`，走 `frames` 短 TTL 缓存（~60s），行情 TTL ~10s。
- 交互模式与网页版一致：**进入即读本地渲染 → 后台刷新 → 静默更新**。由于日 K 全量在本地，切换股票、本地搜索均为零网络等待。

## 6. 算法移植与对拍

| 源文件 | 目标 | 验证方式 |
| --- | --- | --- |
| indicators.py（MA/EMA/MACD/RSI/LON，含中式 SMA 递推） | logic/indicators.dart | 用同一段日 K JSON，与后端输出逐值对比（容差 1e-6） |
| autoDrawing.ts（563 行） | logic/auto_drawing.dart | 从网页版导出若干标的的 AutoDrawing JSON 作为 golden 用例 |
| calendarWindow.ts | logic/calendar_window.dart | 同上 |
| App.tsx 信号逻辑（大涨回撤/上升±3%） | logic/watch_signals.dart | 单测覆盖边界（bars<20、无高点等） |

这是保证"换壳不变行为"的关键，全部进 `test/` 单元测试。

## 7. UI 方案（手机竖屏）

**首次启动**：直接进主界面，全量同步在后台进行，顶部显示同步进度条（见 §5.2）；中途退出下次续传。

主界面为单页结构，自上而下：

1. **顶栏**：应用 logo + 当前标的名称/代码 + 数据质量标签 + 刷新按钮。
2. **市场切换**：A 股 / 美股 / 黄金 / 比特币 分段控件（带各自自选数量角标）。
3. **信号提示条**：大涨回撤（警示色）/ 上升±3%（上涨色）横向滚动 chip，点按切换标的。
4. **K 线主图**（占屏 ~45%）：蜡烛 + 成交量 + 自动画线叠加；长按出十字线和 OHLC 浮窗；周期切换条（日K/1m/5m/15m/30m/60m）。
5. **指标副图**：MACD、LON 两块堆叠（各 ~120dp），与主图共用 X 轴索引，长按十字线联动。
6. **底部操作**：「自选资产」「资产信息」两个按钮，弹 DraggableScrollableSheet（对应网页版抽屉）：
   - 自选资产：搜索框（260ms 防抖联想）、排序切换、列表（名称/现价/涨跌幅，红涨绿跌）、滑动删除、点按切换。
   - 资产信息：现价摘要、最近关键位、线位颜色设置（沿网页版浅黄默认）、删除自选、强制刷新。

主题：延续网页版深色终端风（背景 #080d16、面板 #101722、涨 #f24d4d、跌 #00a884、警示 #f2c94c）。

## 8. K 线 CustomPaint 实现要点

一个 `KlinePainter` 承担全部绘制，图层顺序：

1. 网格 + Y 轴价格刻度（支持对数坐标，条件沿用 `shouldUseLogPriceScale`）。
2. 成交量柱（底部 ~18% 高度，红涨绿跌半透明）。
3. 蜡烛图（自动 bar 宽，窗口固定为面板配置的 90 天/180 bar，不做缩放平移——与网页版"窗口固定"策略一致，实现量大幅缩小）。
4. 水平位线：颜色取自用户配置（默认浅黄），major 线加粗；右侧价签 + 百分比标签，移植 `avoidCrowdedLevelLabels` 避让算法。
5. 趋势通道段：上/下方向不同色，端点小圆点。
6. 近期高/低点标记。
7. 长按十字线 + 浮动 OHLC/涨跌幅信息卡（RepaintBoundary 隔离，避免整图重绘）。

副图 `IndicatorPainter` 复用同一 X 映射：MACD（DIF/DEA 线 + 红绿柱）、LON（柱 + LONMA 线），零轴虚线。

## 9. Logo 与应用标识

- 主题 LazyPerson：AI 生成一个"慵懒小人靠在上升 K 线上"的极简扁平 logo，深色底 + 浅黄/上涨红点缀，与应用主题同色系。
- 产出 SVG 源稿 + 1024×1024 PNG，经 `flutter_launcher_icons` 生成自适应图标（前景/背景分层）。
- 应用名：LazyPerson；包名建议 `com.jsonxu.lazyperson`。

## 10. 实施阶段

| 阶段 | 内容 | 验收 |
| --- | --- | --- |
| M1 数据与算法 | Flutter 工程脚手架；三个 provider；sqflite 建库 + 全量初始化同步（断点续传）+ 每日增量 + 90 天裁剪；indicators/autoDrawing/calendarWindow/watchSignals 移植 + 对拍单测 | `flutter test` 全绿；真机完成一次全量初始化（5000+ 只 90 天日 K 入库），断网重启可续传；本地搜索命中代码/名称/拼音 |
| M2 主界面与 K 线 | 初始化进度页、主题、主页骨架、市场切换、周期切换、K 线 CustomPaint（蜡烛+成交量+画线叠加）、副图 | 真机上 002138 的 90 天日 K 与网页版画线位置一致（截图比对）；初始化进度展示正确 |
| M3 自选与交互 | 自选弹层（搜索/增删/排序）、资产信息弹层、信号条、长按十字线、线位颜色设置、数据质量提示 | 网页版核心操作流程在 App 上全部可完成 |
| M4 打磨与打包 | logo 生成与图标接入、启动页、异常与空态、弱网表现、release APK | 手机安装包可用，冷启动 ≤3s 出缓存图 |

## 11. 风险与对策

- **Yahoo 接口在大陆移动网络下可能不通**：美股/黄金/比特币面板受影响。对策：请求失败回退陈旧缓存并明确提示；二期可加东财的全球指数/贵金属接口兜底。
- **腾讯/东财接口为非官方公开接口**，字段可能变动：provider 解析层集中隔离，单测锁字段位；双源互备。
- **CustomPaint 工作量**：已通过"固定窗口、不做缩放平移、手动画线延后"把范围压缩到可控。
- **全量初始化耗时与接口限速**：5000+ 次单只 K 线请求可能触发腾讯/东财限速。对策：并发可调 + 失败退避重试 + 双源切换 + 断点续传；进度页明示预计时间，允许用户先中断（已同步部分立即可用，自选标的优先同步）。
- **增量快照的口径差异**：东财 clist 当日快照与收盘后复权日 K 可能有细微差（qfq 因除权变动）。对策：当天 bar 用快照临时值，收盘后该股下次被查看时以单只 qfq 日 K 覆盖校正；除权日触发该股 90 天重拉。

## 12. 现有仓库的影响

- 网页版与 FastAPI 后端保持原样不动，Flutter 工程独立放在 `app/`。
- 文档：本方案纳入 README 文档入口；完成后按文档规则补 UPDATES.md。
