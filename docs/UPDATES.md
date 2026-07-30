# 项目更新记录

本文档记录方案、实现和重要调整。后续凡是“方案类型”“更新类型”的内容，都应同步落地到文档。

## 2026-06-11：V1 MVP 落地

类型：实现更新

完成内容：

- 初始化 FastAPI 后端。
- 初始化 React + Vite 前端。
- 接入 AKShare、efinance、BaoStock 数据源适配。
- 实现 SQLite + Parquet 本地缓存。
- 实现 MA、EMA、MACD、RSI 指标计算。
- 实现自选股看板、搜索、K 线图、资金流图。
- 增加实时行情失败时的日 K 兜底。
- 增加基础单元测试。

验证：

- `npm run test` 通过。
- `npm --prefix frontend run build` 通过。
- `GET /api/health` 正常。
- `GET /api/kline/600519?period=day` 正常。
- `GET /api/kline/600519?period=5m` 正常。
- 浏览器验证前端可加载，5m 切换可渲染。

遗留问题：

- 页面仍偏 Demo，视觉和交互体验不足。
- 数据源错误提示偏技术化。
- K 线图缺少成交量副图和悬浮数据。
- 默认接口返回数据范围需要进一步优化。

## 2026-06-11：V2 升级方案

类型：方案更新

新增文档：

- `docs/V2_UPGRADE_PLAN.md`

核心方向：

- 将 V1 技术验证页升级为三栏式 A 股分析工作台。
- 强化自选股、搜索、K 线、成交量、指标和资金流体验。
- 后端接口增加默认返回范围控制。
- 前端错误提示改为中文业务提示。
- 数据源失败时优先使用缓存或日 K 兜底。

计划优先级：

1. 后端接口升级。
2. 前端组件拆分。
3. UI 重做。
4. 图表增强。
5. 自选股和搜索增强。
6. 测试、构建、浏览器验证。

## 2026-06-11：V2 工作台升级落地

类型：实现更新

完成内容：

- 后端 `DataQuality` 增加 `fallback` 和 `message` 字段。
- `GET /api/kline/{symbol}` 增加 `limit` 参数。
- 日 K 默认返回最近 300 条。
- 分钟线默认返回最近 1000 条。
- 自选股为空时自动写入默认种子：贵州茅台、平安银行、宁德时代。
- 数据源异常时，HTTP 错误返回中文业务提示。
- 实时行情不可用时，保留最新日 K 兜底，并通过 `message` 明确说明。
- 前端拆分组件：
  - `StatusBar`
  - `WatchlistPanel`
  - `StockSummary`
  - `IndicatorTabs`
  - `format` 工具函数
- 前端重做为三栏工作台：
  - 左侧自选股栏
  - 中间 K 线和指标区
  - 右侧个股摘要区
- K 线图增加 OHLC 信息条。
- K 线图增加成交量柱。
- 指标区增加 MACD、RSI、资金流 tab。
- 自选股看板增加排序入口和更完整的行情字段。

验证：

- `npm run test` 通过。
- `npm --prefix frontend run build` 通过。
- `GET /api/health` 正常。
- `GET /api/kline/600519?period=day&indicators=ma,macd,rsi` 默认返回 300 条。
- `GET /api/watchlist` 在空数据时能返回默认自选股。
- 浏览器验证 `http://127.0.0.1:5173` 可加载 V2 三栏工作台。
- 浏览器验证 5m 周期切换可用，K 线可更新到分钟线数据。
- 浏览器验证 MACD / RSI tab 可点击。

已知问题：

- 当前网络环境下实时行情源可能失败，页面会显示“实时行情不可用，使用最新日 K 兜底”。
- 第一次加载默认自选股时，非当前选中股票的兜底行情可能需要较长时间补齐。
- 前端构建仍有图表库 chunk 偏大的提示，暂不影响功能。

下一步建议：

- 增加接口请求中的加载骨架，减少等待时的空值感。
- 进一步优化批量报价兜底速度。
- 增加可配置指标参数。
- 增加指数和行业板块入口。

## 2026-06-11：V3 自动画线方案

类型：方案更新

新增文档：

- `docs/V3_AUTO_DRAWING_PLAN.md`

核心方向：

- 基于最新日 K 自动识别近期最高点和近期最低点。
- 按高低点出现顺序判断向上或向下趋势。
- 自动绘制 5 条价格线。
- 线位按 10% 幅度间隔。
- 以 `002138` 作为本阶段测试标准标的。

## 2026-06-11：V3 自动画线落地

类型：实现更新

完成内容：

- 新增 `frontend/src/utils/autoDrawing.ts`。
- 基于最近 120 根日 K 自动计算近期最高点和近期最低点。
- 按高低点出现顺序判断趋势：
  - 低点早于高点：向上趋势。
  - 高点早于低点：向下趋势。
- 向上趋势从近期低点向上绘制 5 条线：`+10%` 到 `+50%`。
- 向下趋势从近期高点向下绘制 5 条线：`-10%` 到 `-50%`。
- K 线图中自动绘制 5 条价格线。
- K 线图中自动绘制近期高低点趋势线。
- K 线图上方展示趋势方向、基准点、目标点和最近线位。
- 右侧摘要面板展示自动画线详情：
  - 趋势方向。
  - 近期高点。
  - 近期低点。
  - 基准点。
  - 最近线位。
  - 距离最近线位。
  - 5 条完整线位。
- `002138` 加入默认自选股，并作为 V3 默认测试标的。

验证：

- `npm run test` 通过。
- `npm --prefix frontend run build` 通过。
- `GET /api/kline/002138?period=day&indicators=ma,macd,rsi&limit=300` 正常。
- 浏览器验证 `002138` 页面可显示“自动画线”模块。
- 浏览器验证显示 5 条线位：
  - `+10%`
  - `+20%`
  - `+30%`
  - `+40%`
  - `+50%`
- 浏览器验证无控制台错误。

当前 `002138` 验证结果：

- 趋势方向：向上趋势。
- 近期低点：2026-04-07 / 32.01。
- 近期高点：2026-06-10 / 61.69。
- 线位：
  - `+10% / 35.21`
  - `+20% / 38.41`
  - `+30% / 41.61`
  - `+40% / 44.81`
  - `+50% / 48.02`

已知限制：

- 本阶段只在日 K 周期显示自动画线。
- 线位窗口固定为最近 120 根日 K。
- 自动画线暂不支持手动保存、编辑和报警。

## 2026-06-11：V3.1 自动画线调整方案

类型：方案更新

新增文档：

- `docs/V3_1_AUTO_DRAWING_ADJUSTMENT.md`

核心方向：

- 日 K 默认展示近 90 根。
- 自动画线基于近 90 根日 K。
- 以 90 日最低点和最高点作为区间。
- 从最低点开始画水平线，最低点本身一根，之后每 10% 一根。
- 每条线颜色不同，`+20%` 默认红色。
- 用户可以修改线条颜色，并保存到浏览器本地缓存。
- 自动识别两根上升趋势线和两根下降趋势线。
- 禁止鼠标滚轮缩放或滚动图表，改为按钮控制。

## 2026-06-11：V3.1 自动画线调整落地

类型：实现更新

完成内容：

- 后端日 K 默认返回范围从 300 根调整为 90 根。
- 前端日 K 请求默认范围从 300 根调整为 90 根。
- 自动画线窗口固定为近 90 根有效日 K。
- 水平线以 90 日最低点为基准：
  - `0%` 为最低点本身。
  - 之后按 `+10%` 递增绘制。
  - 超过 90 日最高点后停止。
- 每条水平线使用独立颜色。
- `+20%` 默认颜色为红色。
- 右侧自动画线面板增加颜色选择器和 HEX 颜色输入框。
- 颜色修改保存到浏览器本地缓存，刷新页面后保持。
- 自动识别并绘制 2 根上升趋势线、2 根下降趋势线，用于包裹近 90 日日 K 波段。
- K 线图禁用鼠标滚轮缩放、鼠标拖拽滚动和触控缩放。
- K 线图增加按钮控制：
  - 放大。
  - 缩小。
  - 向左滚动。
  - 向右滚动。
  - 全览。

验证：

- `npm run test` 通过。
- `npm --prefix frontend run build` 通过。
- `GET /api/kline/002138?period=day&indicators=ma,macd,rsi` 默认返回 90 根日 K。
- 浏览器验证 `002138` 自动画线基于近 90 日日 K。
- 浏览器验证显示 `0%` 到 `+90%` 共 10 条水平线。
- 浏览器验证 `+20%` 默认红色。
- 浏览器验证 `+10%` 修改为 `#00a884` 后刷新页面仍保持，说明本地缓存生效。
- 浏览器验证趋势线数量为 4 条：2 条上升趋势线、2 条下降趋势线。
- 浏览器验证放大、缩小、左移、右移、全览按钮均可点击，控制台无错误。

当前 `002138` 验证结果：

- 90 日低点：2026-04-07 / 32.01。
- 90 日高点：2026-06-10 / 61.69。
- 最近线位：`+80% / 57.62`。
- 默认日 K 数据范围：2026-01-22 到 2026-06-10。

已知限制：

- 当前颜色缓存保存在浏览器本地缓存中，不会跨浏览器同步。
- 趋势线为自动波段识别结果，不支持手动微调锚点。

## 2026-06-11：本地开发端口调整

类型：配置更新

背景：

- 本地前后端服务端口需要避开旧端口。

完成内容：

- 前端 Vite 开发服务端口从 `5173` 调整为 `5175`。
- 后端 FastAPI 开发服务端口从 `8000` 调整为 `8018`。
- Vite `/api` 代理目标同步调整为 `http://127.0.0.1:8018`。
- 后端默认 CORS 白名单同步调整为 `http://localhost:5175` 和 `http://127.0.0.1:5175`。
- README 本地访问地址同步更新。

验证：

- `npm run test` 通过。
- `npm run build` 通过。
- `GET http://127.0.0.1:8018/api/health` 正常。
- `GET http://127.0.0.1:5175/api/health` 经 Vite 代理正常。
- 浏览器验证 `http://127.0.0.1:5175/` 可打开 `LazyPerson` 页面，控制台无错误。

## 2026-06-11：V3.2 行情终端 UI 与自然日窗口方案

类型：方案更新

新增文档：

- `docs/V3_2_MARKET_TERMINAL_UI_PLAN.md`

核心方向：

- 将近 90 天从“90 根交易日 K 线”调整为“90 个自然日窗口”。
- 日 K 多取原始数据，再在前端按最新日 K 日期回推 90 个自然日过滤。
- 自动画线基于过滤后的自然日窗口。
- UI 改为更接近主流股票行情终端的深色高密度风格。

## 2026-06-11：V3.2 行情终端 UI 与自然日窗口落地

类型：实现更新

完成内容：

- 新增 `frontend/src/utils/calendarWindow.ts`。
- 日 K 请求原料从 90 根交易日提高到 140 根交易日。
- 前端以最新日 K 日期为结束日，回推 90 个自然日过滤展示窗口。
- K 线、MA、MACD、RSI 指标数组随自然日窗口同步截断。
- 自动画线改为基于近 90 个自然日窗口。
- 自动画线标签从 `90日低点/高点` 调整为 `90自然日低点/高点`。
- 后端日 K 默认原料数量从 90 根调整为 140 根。
- UI 改为深色行情终端风格：
  - 深色全局背景。
  - 深色 K 线图和指标图。
  - 红涨绿跌。
  - 更高密度的自选股、行情摘要和工具栏。
  - 面板边框、按钮和状态标签改为交易盘风格。
- ECharts 指标区同步改为深色主题。

验证：

- `npm run test` 通过。
- `npm run build` 通过。
- `GET http://127.0.0.1:8018/api/kline/002138?period=day&indicators=ma,macd,rsi&limit=140` 返回 140 根日 K 原料。
- 当前 `002138` 最新日 K 为 `2026-06-11`，近 90 自然日起点为 `2026-03-13`。
- 当前近 90 自然日窗口内实际显示 61 根交易 K。
- 浏览器验证 `http://127.0.0.1:5175/` 已显示“近90自然日”。
- 浏览器验证自动画线显示 `90自然日低点` 和 `90自然日高点`。
- 浏览器验证深色行情终端主题生效，控制台无错误。

## 2026-06-11：V3.3 走势图优先与重点画线方案

类型：方案更新

新增文档：

- `docs/V3_3_CHART_FIRST_DRAWING_PLAN.md`

核心方向：

- 默认页面让走势图占据主要面积。
- 自选股和个股信息改为按钮打开详情抽屉。
- 指标只保留 MACD 和 LON。
- 画线标签左对齐，重点标记 `+20%`、`+50%`、`+80%`。
- 趋势线和水平线均改为实线。

## 2026-06-11：V3.3 走势图优先与重点画线落地

类型：实现更新

完成内容：

- 默认布局改为主图优先，K 线图区不再被左右常驻面板压缩。
- 自选股列表改为点击 `自选股` 按钮打开抽屉。
- 个股基本信息改为点击 `个股信息` 按钮打开抽屉。
- K 线主图区高度提升到默认 `560px` 起。
- 前端指标请求从 `ma,macd,rsi` 调整为 `macd,lon`。
- 后端新增 LON 指标计算。
- 指标面板只保留 `MACD` 和 `LON` 两个 tab。
- 顶部指标摘要只显示 MACD、DIF、DEA、LON、LONMA。
- 自动画线水平线改为实线。
- 趋势线统一改为实线。
- 图表内增加左侧对齐的彩色线位标签。
- `+20%`、`+50%`、`+80%` 三条重点线固定为红、黑、蓝，并加粗显示。

验证：

- `npm run test` 通过。
- `npm run build` 通过。
- `GET http://127.0.0.1:8018/api/kline/002138?period=day&indicators=macd,lon&limit=140` 返回 MACD 和 LON。
- 浏览器验证默认布局为 `chart-first`。
- 浏览器验证主图高度为 `560px`。
- 浏览器验证页面只显示 MACD/LON，不显示 RSI/资金流。
- 浏览器验证左侧线位标签数量为 10。
- 浏览器验证 `+20%`、`+50%`、`+80%` 分别为红、黑、蓝且加粗。
- 浏览器验证 `自选股` 抽屉可打开，当前显示 4 只自选。
- 浏览器验证 `个股信息` 抽屉可打开，并显示自动画线和数据状态。
- 浏览器验证控制台无错误。

## 2026-06-11：V3.4 指标同屏与日线数据修正方案

类型：方案更新

新增文档：

- `docs/V3_4_INDICATOR_AND_CACHE_FIX_PLAN.md`

核心方向：

- MACD 和 LON 指标同屏展示，不再使用选项卡。
- MACD 和 LON 都增加柱状图，并按 0 轴红绿分色。
- 日线图只保留左侧百分比线位标签，去掉右侧线位价格标签。
- 近 90 天按自然日窗口计算，但窗口内只保留真实交易 K。
- 修正默认日线读取旧缓存或区间缓存串写导致的数据错误。

## 2026-06-11：V3.4 指标同屏与日线数据修正落地

类型：实现更新

完成内容：

- `IndicatorTabs` 从选项卡改为 MACD / LON 两个纵向指标图。
- MACD 指标图展示 DIF、DEA 线和 MACD 柱状图。
- LON 指标图展示 LON 柱状图和 LONMA 线。
- MACD / LON 柱状图统一为 0 上方红色、0 下方绿色。
- K 线自动画线关闭右侧价格轴标签，只保留左侧百分比标签。
- 前端 90 自然日窗口过滤周六、周日和缺失 OHLC 的记录。
- 指标数组按过滤后的 K 线索引同步截断。
- K 线缓存文件路径加入缓存 key 哈希，避免不同区间共用同一个 parquet 文件。
- 默认日线缓存增加最新日期校验，过旧缓存会自动绕过。
- 默认日线请求缩短为近一年原料，减少数据源刷新耗时。
- 默认日线优先走 efinance/东方财富；显式历史区间仍按 AKShare、BaoStock、efinance 顺序兜底。
- 增加缓存回归测试，覆盖同股票不同 K 线缓存 key 不互相覆盖。

验证：

- `npm run test` 通过。
- `npm run build` 通过。
- `GET http://127.0.0.1:8018/api/kline/002138?period=day&indicators=macd,lon&limit=140` 返回 140 根日 K 原料。
- 当前 `002138` 原料范围：`2025-11-12` 到 `2026-06-11`。
- 当前 `002138` 近 90 自然日窗口：`2026-03-13` 到 `2026-06-11`，共 61 根交易 K。
- 接口验证周末记录数量为 0。
- 接口验证返回 MACD 和 LON，两个指标数组长度均为 140。
- 浏览器验证 `http://127.0.0.1:5175/` 显示 `近90自然日交易K · 2026-06-11`。
- 浏览器验证 MACD 和 LON 同屏展示，指标图数量为 2。
- 浏览器验证页面不显示 RSI 和资金流。
- 浏览器验证左侧线位标签为 `0%` 到 `+90%`，且只显示百分比。
- 浏览器验证控制台无错误。

## 2026-06-11：V3.5 局域网访问与趋势通道调整方案

类型：方案更新

新增文档：

- `docs/V3_5_LAN_AND_TREND_CHANNEL_PLAN.md`

核心方向：

- 让前后端开发服务支持局域网访问。
- 调整线位重点色：`+20%` 红色、`+50%` 蓝色、`+80%` 白色。
- 其他线位默认统一为绿色。
- 向上和向下趋势改为大范围双平行通道线。

## 2026-06-11：V3.5 局域网访问与趋势通道调整落地

类型：实现更新

完成内容：

- 后端开发服务启动 host 从 `127.0.0.1` 调整为 `0.0.0.0`。
- 前端 Vite 开发服务启动 host 从 `127.0.0.1` 调整为 `0.0.0.0`。
- Vite 配置同步增加 `server.host = "0.0.0.0"`。
- README 增加局域网访问说明和 Windows 防火墙提示。
- 线位颜色规则调整为：
  - `+20%` 红色。
  - `+50%` 蓝色。
  - `+80%` 白色。
  - 其他线位绿色。
- 线位颜色缓存 key 升级到 `v2`，避免旧颜色缓存影响新默认展示。
- 自动趋势线从局部波段线改为 4 条大范围通道线：
  - `向上通道 下轨`。
  - `向上通道 上轨`。
  - `向下通道 上轨`。
  - `向下通道 下轨`。
- 已重启前后端服务，新监听地址包含 `0.0.0.0:5175` 和 `0.0.0.0:8018`。

验证：

- `npm run test` 通过。
- `npm run build` 通过。
- `GET http://127.0.0.1:8018/api/health` 正常。
- `GET http://127.0.0.1:5175/api/health` 经 Vite 代理正常。
- 当前检测到本机局域网 IP：`192.168.22.22`。
- 浏览器验证 `http://127.0.0.1:5175/` 显示 `近90自然日交易K · 2026-06-11`。
- 浏览器验证线位标签颜色：
  - `+20%` 为红色。
  - `+50%` 为蓝色。
  - `+80%` 为白色且文字可读。
  - 其他线位为绿色。
- 浏览器验证自动画线详情显示 4 条通道线。
- 浏览器验证控制台无错误。

## 2026-06-11：V3.6 线位浅黄色与单方向趋势通道方案

类型：方案更新

新增文档：

- `docs/V3_6_LINE_COLOR_AND_SINGLE_CHANNEL_PLAN.md`

核心方向：

- 普通百分比线从绿色调整为浅黄色，降低图面花哨感。
- `+20%`、`+50%`、`+80%` 继续保留红、蓝、白重点色。
- 趋势通道只展示当前方向的一组，不再同时显示向上和向下两组。
- 通道依据前后两个时间段的高点、低点连接形成。

## 2026-06-11：V3.6 线位浅黄色与单方向趋势通道落地

类型：实现更新

完成内容：

- 普通百分比线默认颜色从绿色改为浅黄色 `#f6d36b`。
- 浅黄色和白色标签文字改为深色，保证可读性。
- 线位颜色缓存 key 升级到 `v3`，避免旧绿色缓存影响新默认展示。
- 自动趋势通道改为：
  - 将近 90 自然日交易窗口拆成前后两个时间段。
  - 分别识别前段高点、前段低点、后段高点、后段低点。
  - 低点连低点作为下轨。
  - 高点连高点作为上轨。
  - 根据前后价格中枢判断只显示向上或向下一组通道。
- 向上通道为红色。
- 向下通道为绿色。

验证：

- `npm run test` 通过。
- `npm run build` 通过。
- 浏览器验证普通线位均为浅黄色。
- 浏览器验证 `+20%`、`+50%`、`+80%` 分别为红、蓝、白。
- 浏览器验证当前 `002138` 只显示一组向上通道，共 2 条线：`向上通道 下轨`、`向上通道 上轨`。
- 浏览器验证控制台无错误。

## 2026-06-11：V3.7 数据缓存与自选股切换性能修正

类型：实现更新

新增文档：

- `docs/V3_7_DATA_CACHE_AND_SWITCH_PERFORMANCE.md`

完成内容：

- 梳理缓存结构：
  - SQLite 保存自选股、股票基础信息和缓存索引。
  - Parquet 保存 K 线、实时行情、分钟线、资金流等时序数据。
- 明确在线读取成功后会写入本地缓存。
- 后端 `_fetch_with_cache` 增加本地优先策略：
  - 非强制刷新时优先返回已有缓存。
  - 手动刷新时再强制访问在线数据源。
- 后端写缓存前增加校验，默认日线如果最新日期明显过旧则不写入缓存。
- 前端切换自选股时不再额外刷新整组自选股实时行情。
- 前端行情和 K 线请求增加请求序号，避免慢响应覆盖新选择的股票。
- Vite 代理目标临时调整为 `http://192.168.22.22:8018`，绕开残留的旧 `127.0.0.1:8018` 后端监听。

验证：

- `npm run test` 通过。
- `npm run build` 通过。
- `GET http://192.168.22.22:8018/api/quotes/realtime?...` 约 285ms 返回缓存。
- `GET http://127.0.0.1:5175/api/quotes/realtime?...` 经 Vite 代理约 125ms 返回缓存。
- 默认自选股日 K 返回约 35ms 到 321ms，最新日期均为 `2026-06-11`。
- 浏览器验证页面显示 `002138 · 使用本地缓存`。
- 浏览器验证 K 线显示 `近90自然日交易K · 2026-06-11`。
- 浏览器验证控制台无错误。

## 2026-06-11：V3.8 开发服务启动治理与 VSCode Launch 方案

类型：方案与实现更新

新增文档：

- `docs/V3_8_DEV_STARTUP_AND_VSCODE_LAUNCH.md`

完成内容：

- 后端默认启动脚本去掉 `--reload`，降低 Windows 下 uvicorn 父子进程残留风险。
- 保留 `npm run dev:backend:reload`，需要热重载时显式使用。
- `npm run dev` 增加 `concurrently -k`，一个服务退出时会联动停止另一个。
- 新增 `npm run stop:dev`，调用 `scripts/stop-dev.ps1` 清理 `5175/8018` 和当前工作区开发进程。
- 新增 `.vscode/tasks.json`：
  - `Stop LazyPerson Dev Ports`
- 新增 `.vscode/launch.json`：
  - `Backend 8018`
  - `Frontend 5175`
  - `LazyPerson Dev` compound，一键启动前后端。
- Vite 代理默认值恢复为 `http://127.0.0.1:8018`。
- Vite 代理保留 `API_PROXY_TARGET` 环境变量覆盖能力。
- README 增加 VSCode 手动启动说明。

验证：

- `npm run test` 通过。
- `npm run build` 通过。
- 已验证 `scripts/stop-dev.ps1` 不再因为宽匹配杀掉自身执行链。

注意：

- 当前 Windows 环境曾出现 `netstat` 显示多个 `8018 LISTENING`，但进程表查不到 PID 的残留状态。
- 如果 `npm run stop:dev` 无法清理不存在 PID 的监听记录，应重启 Windows 后再使用 VSCode `LazyPerson Dev` 启动。

## 2026-06-11：V3.9 后端端口迁移到 8018

类型：方案与配置更新

新增文档：

- `docs/V3_9_BACKEND_PORT_MIGRATION.md`

背景：

- 后端启动时报 `[WinError 10048]`，说明 `8018` 端口被占用。
- `netstat` 显示多个 `8018 LISTENING`，但 `taskkill` 提示部分 PID 不存在，进程表也查不到命令行。
- 当前 Windows 会话里的 `8018` 端口状态已经不可信。

完成内容：

- 后端开发端口从 `8018` 迁移到 `8018`。
- `package.json` 的 `dev:backend` 和 `dev:backend:reload` 改为 `8018`。
- Vite 默认代理目标改为 `http://127.0.0.1:8018`。
- VSCode launch 后端项改名为 `Backend 8018`。
- 清理脚本继续清理历史残留 `8018`，并新增清理 `8018`。
- README 和 V3.8 启动治理文档同步更新。

建议：

- 后续固定使用 `8018`，不要再切回 `8018`。
- 优先使用 VSCode `LazyPerson Dev` 启动。

## 2026-07-20：V4 Flutter 安卓应用（M1-M4）落地

类型：实现更新

完成内容：

- 新增 `app/` Flutter 工程（包名 `com.jsonxu.lazyperson`，仅 Android）。
- Dart 直连数据源：腾讯（A 股行情/日K/分钟K，GBK 解析）、东方财富（clist 全市场快照 + 单只 K 线兜底，push2 不通时自动切 push2delay）、Yahoo（美股/黄金/比特币）。
- 数据本地化：沪深全量清单（约 5540 只，不含北交所）+ 90 天日 K 落 sqlite；首次启动初始化页带分段进度与断点续传；每日增量用约 55 页快照批量写当日 bar；超 90 天自动裁剪；搜索纯本地（代码/名称/拼音首字母）。
- 算法移植并对拍：indicators.py（MA/EMA/MACD/RSI/LON）、autoDrawing.ts、calendarWindow.ts、watch 信号，用 4 只真实股票的 golden 数据逐值比对（`scripts/generate_golden.py` + `scripts/generate_golden_drawing.mjs`）。
- UI：初始化进度页、四市场面板、周期切换、信号条、K 线 CustomPaint（蜡烛/成交量/水平位含主线加粗与标签避让/趋势通道/长按十字线/对数坐标）、MACD/LON 副图、自选与资产信息弹层、线位颜色设置（存储 key 与网页版一致）。
- Logo：AI 生成"慵懒小人靠 K 线打盹"扁平图标（`scripts/generate_logo.py`），flutter_launcher_icons 出全套自适应图标，启动页深色底。
- Android release 补 INTERNET 权限，应用名 LazyPerson。

验证：

- `flutter analyze` 无告警。
- `flutter test` 28 项全部通过（含指标与自动画线 golden 对拍）。
- `dart run tool/smoke_providers.dart` 联网冒烟 8 项全部通过（四个市场行情与 K 线）。
- `flutter build apk --release` 构建成功（约 55MB）。

遗留问题：

- 真机验收未做：全量初始化实际耗时与接口限速需实测调优并发；002138 画线位置与网页版截图比对待真机完成。
- 手动画线/趋势线拖拽编辑、资金流图为二期范围。
- Yahoo 接口在大陆移动网络下可能不通，仅影响非 A 股面板（有缓存兜底与提示）。

## 2026-07-27：抢钱流（全A股档位扫描）

类型：实现更新

完成内容：

- 新增"抢钱流"功能：扫描全部沪深A股，筛选现价处于 20% 主档位区间上半段（超过区间下沿 10% 以上）的股票，口径与 K 线图 90 自然日档位线一致（`low90 = 90日窗口最低 low`，`pct = 现价/low90 - 1`，命中条件 `pct - floor(pct/20)*20 > 10`）。
- 排除：北交所、ST/*ST、上市不足 90 天、无最新价、日线不足 20 根。
- 后端 `backend/app/scanner.py`：后台线程扫描任务（16 并发），`POST /api/moneygrab/scan` 启动、`GET /api/moneygrab/scan/status` 查进度/结果；结果当天持久化（app_state），重启可恢复。
- 全市场快照三级降级：efinance → akshare → 本地清单+腾讯 80只/批 6 路并发；记住上次成功源，避免每次先等东财超时。
- 扫描日线走专用通道：本地缓存 → 腾讯（15s 超时），不走 efinance/akshare 降级链（东财不可达时其内部长超时会拖死工作线程）；缓存键与 `MarketService.kline` 一致，图表与扫描互相复用。
- 前端：A股面板"抢钱流"入口 → 右侧抽屉，开始扫描/阶段提示/进度条，命中边扫边显、实时按超出档位中线幅度排序，点击行切换主图。

验证：

- `python -m pytest tests/` 39 项全部通过。
- `npm run build`（frontend）通过。
- 真实全量冒烟：4926 只扫描完成（缓存热后全程约 1.1 分钟），命中 2039 条；抽查 top5 + 中段 5 只，与 K 线图公式重算完全一致。

遗留问题：

- 命中条件覆盖面较宽（约四成个股满足"区间上半段"），如需收敛可加"当日刚突破档位中线"或成交额过滤，二期考虑。
- 东财可达的环境未实测 efinance/akshare 快照路径。
- 设计文档：docs/superpowers/specs/2026-07-27-moneygrab-scan-design.md。

## 2026-07-30：八档局「从高处来」改为可选 + 资产信息财务概览

类型：实现更新

完成内容：

- 八档局：`is_falling_from_top`（从顶部跌破已站上线）与 V 型反弹两条规则不再 `return None` 丢弃，改为在命中行上打 `from_top` / `v_shape` 标记；V 型判定抽成 `is_v_shape_rebound()`。展示层新增「含从顶部下来」「含V型反弹」两个筛选开关（默认不勾选，与改动前看到的列表一致），切换即时生效无需重扫；结果表新增「形态」列。
- 结果结构变了，扫描结果缓存键升版：后端 `moneygrab:last_scan:v3 → v4`，App `band_scan:last:v1 → v2`（旧结果自动作废重扫）。
- Flutter 端 `band_scanner.dart` / `band_scan_controller.dart` / `band_scan_screen.dart` 同步，逻辑与 Python 侧逐条对齐。
- 新增财务数据源 `backend/app/providers/eastmoney_adapter.py`（东财 datacenter）：业绩报表 `RPT_LICO_FN_CPD`、利润表 `RPT_DMSK_FN_INCOME`、分红送配 `RPT_SHAREBONUS_DET`，估值走 push2 `ulist.np`（PE/PE-TTM/PB/总市值/流通市值）。净利润（含少数股东）由 利润总额 - 所得税 推出，业绩报表本身只有归母口径。
- 新增 `GET /api/fundamentals/{symbol}`（仅 A 股）。结构是嵌套的，不走 `write_frame` 的表格缓存，改用 state 表存 JSON + `fetched_at` 判 TTL（默认 6 小时，`FUNDAMENTALS_TTL_SECONDS`）；远端不可用时回落到过期缓存并标 stale。
- 网页版：`FundamentalsPanel.tsx` 挂进资产信息抽屉，展示估值、最新业绩（营收/归母净利润/扣非归母/净利润/EPS/ROE/毛利率/每股经营现金流）、历史业绩表、分红方案表。
- App：`eastmoney_fundamentals_provider.dart` 直连同样的东财接口（不经后端，与其他 provider 一致），`MarketRepository.fundamentals()` 做 6 小时 JSON 缓存，`fundamentals_section.dart` 挂进资产信息弹层。
- 估值接口主域名 push2 在部分网络下只会静静超时，超时压到 6 秒尽快降级 push2delay；估值失败只记 warning，不影响财务部分。

验证：

- `python -m pytest tests/` 60 项全部通过（新增 `tests/test_eastmoney_fundamentals.py` 8 项：字段映射、净利润推导、报告期错位不硬凑、估值失败降级）。
- `flutter analyze` 无告警，`flutter test` 49 项全部通过。
- `npx tsc --noEmit` 与 `npm run build`（frontend）通过。
- 真实接口冒烟：`GET /api/fundamentals/600519` 返回 8 期业绩 + 8 条分红 + 完整估值；`GET /api/fundamentals/AAPL` 按预期 503。

遗留问题：

- 财务只覆盖 A 股，美股/黄金/加密走 Yahoo 无对应接口，面板直接不渲染。
- 只做了业绩 + 分红 + 估值；资产负债表与现金流量表科目未纳入。

## 2026-07-30：收敛为纯 A 股 + HUD 主题（方案 1d）

类型：方案更新 + 实现更新

### 一、只保留 A 股，移除美股/黄金/加密

- 后端：删除 `backend/app/providers/yahoo_adapter.py` 与 `tests/test_yahoo_adapter.py`；`MarketService` 去掉 `global_watchlist` / `builtin_symbols` / `_upsert_builtin_symbols` / `_should_search_yahoo_symbols` / `_combine_quality`；`realtime_quotes` 与 `kline` 不再按 A 股/非 A 股分流，只走腾讯→efinance→akshare（日线再加 baostock）；`utils.guess_market` 只判 SH/SZ/BJ，`normalize_symbol` 去掉 `.US` 后缀。
- App：删除 `lib/data/providers/yahoo_provider.dart`；`market_panels.dart` 的 `PanelKey` 四值枚举 + `panelForAsset` + `panelGroupName` 换成单个 `aShareConfig` 常量；`HomeController` 的 `activePanel` / `selectedByPanel` / `setPanel` 收敛为一个 `selected` 字段，搜索不再走 Yahoo 在线补全；默认自选只留 4 只 A 股。
- 网页版：`App.tsx` 的 `marketPanels` / `defaultSelectedByPanel` / `panelForAsset` / `panelConfig` / `fillSelectedPanels` 全部删除，换成 `aShareConfig`；市场切换 Tab 与对应 CSS 一并移除；`WatchlistPanel` 去掉 `panelLabel` 入参。
- 八档局入口不再判面板，始终显示。

### 二、HUD 主题（handoff/ 方案 1d，稿 09/10/11）

- `lib/theme/app_theme.dart` 整体替换为 HUD 配色（深蓝底 #050914 + 青 accent #4CC9FF + 涨 #FF4D6D / 跌 #00E5A0），新增 `lib/theme/hud.dart` 视觉基元：`HudPanel`、`GlowText`、`HudBrackets`、`HudSegmentBar`、`HudChip`、`HudLiveBadge`、`HudLevelRail`、`drawGlowing`。
- 新增 widget：`band_radar.dart`（八档竖轨雷达，替代原横向 Tab）、`band_hit_table.dart`（九列冻结前两列 + 表头表体同步横滚）、`sparkline.dart`（自选行迷你走势线，无日线缓存时退化成涨跌幅强度块）、`hud_sheet.dart`（两个浮层共用的 sheet 外壳）。
- 字体：IBM Plex Mono 四个字重打进 `app/assets/fonts/`，网页版用 woff2 放 `frontend/public/fonts/`，两端都本地打包不联网；只有数字/代码/日期走 mono，中文正文仍用系统字体。
- 逐屏：主行情屏（顶栏 HudPanel + LIVE 徽标、同步条改分段进度、标的头现价发光 + 涨跌实心徽标、周期切换旁加档位轨、K 线四角取景框、底部操作条浮层化）；K 线蜡烛与趋势线走 `drawGlowing`，OHLC 条改单行 O/H/L/C；副图卡片化（110→96dp，标题行显示当前值取代色块图例）；八档局改雷达 + 表格/卡片双视图（切换态存在 State，不进 controller）；自选与资产信息换 HUD sheet 外壳。
- 档位轨的「已站上最高档」在 `home_screen.dart` 用 `level_rules.isMajorLevel` 现成判定算出，没有新写规则，`lib/logic` 未改动。
- 网页版同步这套视觉语言：`styles.css` 换 HUD 调色板与 `--hud-*` 变量、径向渐变背景、chip 化按钮与周期切换、八档局入口常亮发光、数字统一 mono + tabular-nums、现价发光；`KlineChart.tsx` 与 `IndicatorTabs.tsx` 的图表底色/网格/轴/涨跌色跟着换。
- logo 未改动。

验证：

- `flutter analyze` 无告警；`flutter test` 49 项全部通过。
- `python -m pytest tests/` 55 项全部通过（删掉 Yahoo 适配器 5 项，全球自选 2 项改为 A 股断言）。
- `npx tsc --noEmit` 与 `npm run build`（frontend）通过，woff2 已进 dist。
- `flutter build apk --release` 构建成功。

遗留问题：

- 真机/模拟器 UI 未实跑：411×880dp 下的溢出、表头与表体横滚对位、发光在中端机上的绘制开销都还没实测，需要装机走一遍。
- `frontend/tsconfig.json` 之前被去掉了 `moduleResolution`，与 `module: ESNext` 组合会报 TS5070，本次补成 `Bundler` 才能过类型检查。
- 沪深清单里非 6 位数字的历史脏数据（若有）不会再被展示层归类，只是不显示，未做清理迁移。

## 2026-07-30（修复）：App 财务概览拿不到数据

类型：实现更新

问题：App 的「资产信息 → 财务概览」始终空白。原因是东财 datacenter（`datacenter-web.eastmoney.com/api/data/v1/get`）
返回的 `Content-Type` 是 `text/plain;charset=UTF-8`，而 Dio 默认只对 `application/json` 反序列化，
`_dio.get<Map<String, dynamic>>` 拿到的是字符串、泛型转换抛 `DioException`，业绩/利润表/分红三个请求全部失败。
push2 系（clist / ulist.np / kline）返回的是 `application/json`，所以其他 provider 不受影响；
Python 端 `response.json()` 不看 content-type，网页版也不受影响 —— 这也是只测后端接口时没暴露的原因。

修复内容：

- `eastmoney_fundamentals_provider.dart` 的 `_getJson` 改为 `ResponseType.plain` 收响应后自己 `jsonDecode`，不依赖服务端 content-type。
- 估值改用独立的 `_quoteDio`（connect/receive 各 6 秒）。原先用 `Options(receiveTimeout:)` 想压短超时，
  但 `connectTimeout` 无法按请求覆盖，push2 连不上时仍要等 BaseOptions 的 15 秒才降级到 push2delay。
- 新增 `app/test/eastmoney_fundamentals_provider_test.dart`（9 项）：用假 HttpClientAdapter 覆盖 text/plain 与
  application/json 两种响应、字段映射、净利润推导、报告期错位留空、估值降级、空数据抛错；
  另有一条「前提」测试锁住 Dio 对 text/plain 的默认行为，说明这个手动 jsonDecode 为什么必须存在。

验证：

- `flutter analyze` 无告警；`flutter test` 58 项全部通过。
- `dart run tool/smoke_providers.dart` 联网冒烟：东财财务返回「贵州茅台 8期业绩 8条分红，最新 2026年 一季报 归母=27242512886.45」，东财估值 PE/PB/市值正常。
- `flutter build apk --release` 构建成功（19.6MB）。

遗留问题：

- `eastmoney_provider.dart` 的单只 K 线兜底走 `push2his.eastmoney.com`，没有像 clist 那样配 push2delay 主备；
  在 push2 不通的网络下这条兜底恒超时 15 秒（腾讯是主源，故只影响腾讯也失败的情况）。冒烟里的「东财 日K 300750」失败就是这个。

## 2026-07-30（调整）：字号标度上调，改掉偏小偏密的问题

类型：实现更新

按给定的「用途 → 上限」表，把 app 的字号从散落的裸数字收进 `app_theme.dart` 的 `FontSize` 标度，
widget 里不再写裸数字，避免各屏再次跑偏：

| 用途 | 原 | 现 | FontSize |
| --- | --- | --- | --- |
| 标的名 | 21 | 21 | `symbolName` |
| 现价 | 30 | 30 | `price` |
| 涨跌幅 / 次要数字 | 10~11.5 | 13 | `secondaryNumber` |
| 表格数字 | 9~10.5 | 12 | `tableNumber` |
| OHLC 条 / 图例 / 代码副行 | 9~9.5 | 11 | `legend` |
| 全大写英文标签 | 8~8.5 | 9（配 letterSpacing） | `capsLabel` |
| 角标（涨停 / 形态） | 8.5 | 10 | `badge` |
| 卡片/列表项名称 | 11.5~14 | 15 | `cardTitle` |
| 屏标题 / 浮层标题 | 14~16 | 16 | `screenTitle` |
| 中文正文与按钮 | 10~12 | 12 | `body` |
| 次要中文说明 | 10 | 11.5 | `caption` |

标的名与现价原本就已经是 21 / 30（HUD 稿的值），这次没动；其余全部上调。

字变大后同步放开的尺寸（否则截字/贴边）：

- 八档命中表列宽整体 +20%：冻结列 116→128，七列 54/62/52/52/48/48/50/62 → 64/74/62/62/58/58/60/72。
- 财务历史业绩表列宽 +15%：92/62/62/72/62/62/46/52 → 106/72/74/84/74/72/54/62。
- K 线右侧价格轴 52→58、底部日期轴 18→20；轴上与十字线的数字也改走等宽，跟其它数字一致。
- 副图卡片 96→104，八档雷达轨 96→104。
- 勾选框 12→15、图标 15~18→17~20、色板圆点 19→22，间距普遍 +1~2。
- 命中卡第三行（波段高/低点/过线/超出）从 `Row` 改 `Wrap`，字号 9→12 后单行在 411dp 放不下。

防溢出（`flutter analyze` 抓不到 RenderFlex overflow）：

- 新增 `app/test/layout_overflow_test.dart`：411×880 与 360×800 两个宽度各跑一遍
  八档命中表（长名称 + 涨停 + 双形态标记）与八档雷达（八档满命中），pump 到底不报溢出。
- 顶栏固定内容按字号算约 390dp，360dp 窄屏会挤爆 → `MARKET HUD v3.2` 装饰标签放进 `Flexible`，
  窄屏优先截它，不挤掉右侧 LIVE 与刷新；八档局页头标题列改 `Expanded`。

验证：

- `flutter analyze` 无告警；`flutter test` 62 项全部通过（含新增 4 项布局用例）。
- `flutter build apk --release` 构建成功。

遗留问题：

- 整屏（HomeScreen / BandScanScreen）的溢出没能进自动化测试：`pumpWidget` 会卡在
  `HomeController.bootstrap()` 的异步上，fake_async 永远 settle 不了（实测 10 分钟超时，
  且失败会污染同文件其它用例）。整屏的横向风险改为结构性堵住，纵向仍需装机确认。
- 竖向空间没实测：主行情屏是固定 Column（顶栏/标的头/周期条/图表 flex5/副图 104×2/底部条），
  字号普遍上调后在 800dp 高的窄屏上是否够，要装机看。
