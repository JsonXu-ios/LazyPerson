# LazyPerson · 方案 1d（科技 HUD）开发交接

设计稿：`LazyPerson 高端改版.dc.html` → 选项 **1d**（09 主行情 / 10 八档雷达 / 11 自选浮层）。
稿子按 **Android 411dp 宽 1:1** 绘制，稿上像素 = Flutter 的 dp，可直接抄数值。

改造原则：**不动组件树、不动任何 controller / logic / data**。
1d 是一次换肤 + 三个新 widget，业务逻辑（`band_scanner.dart`、`auto_drawing.dart`、`sync_service.dart`、各 controller）一行都不用改。

---

## 一、给 Claude Code 的一句话任务（可直接粘贴）

> 按 `handoff/` 下的文件把 LazyPerson 改成 HUD 主题：
> 1. 用 `handoff/lib/theme/app_theme.dart` 整体替换 `lib/theme/app_theme.dart`；
> 2. 新增 `lib/theme/hud.dart`、`lib/ui/widgets/band_radar.dart`、`lib/ui/widgets/band_hit_table.dart`、`lib/ui/widgets/sparkline.dart`（内容见 handoff 同名文件）；
> 3. 按 `handoff/HANDOFF.md` 的第三节逐屏改 `home_screen.dart`、`band_scan_screen.dart`、`watchlist_sheet.dart`、`summary_sheet.dart`、`kline_chart.dart`、`indicator_chart.dart`；
> 4. 不修改 `lib/logic/`、`lib/data/`、`lib/state/` 下任何文件；
> 5. 跑 `flutter analyze`，零 warning。

---

## 二、落地顺序（每步都可单独跑起来看）

| # | 步骤 | 改哪些文件 | 产出 |
|---|---|---|---|
| 1 | 换色 + 换字 | 替换 `theme/app_theme.dart`；`pubspec.yaml` 加 IBM Plex Mono | 全 App 已是 HUD 配色，数字等宽 |
| 2 | 视觉基元 | 新增 `theme/hud.dart` | HudPanel / GlowText / HudChip / HudSegmentBar / drawGlowing |
| 3 | 主行情屏 | `ui/home_screen.dart` | 稿 09 |
| 4 | K 线发光 | `ui/widgets/kline_chart.dart` | 蜡烛/趋势线发光 + 四角取景框 |
| 5 | 副图卡片化 | `ui/widgets/indicator_chart.dart` | MACD / LON 圆角发光卡 |
| 6 | 八档雷达 + 命中列表 | 新增 `band_radar.dart`、`band_hit_table.dart` + `ui/band_scan_screen.dart` | 稿 10 |
| 7 | 自选浮层 | 新增 `sparkline.dart` + `ui/widgets/watchlist_sheet.dart` | 稿 11 |
| 8 | 资产信息 | `ui/widgets/summary_sheet.dart` | 沿用 HudPanel 网格 |

字体（第 1 步）：
```yaml
fonts:
  - family: IBMPlexMono
    fonts:
      - asset: assets/fonts/IBMPlexMono-Regular.ttf
      - asset: assets/fonts/IBMPlexMono-Medium.ttf
        weight: 500
      - asset: assets/fonts/IBMPlexMono-SemiBold.ttf
        weight: 600
      - asset: assets/fonts/IBMPlexMono-Bold.ttf
        weight: 700
```
中文正文继续用系统字体，**只有数字/代码/日期走 `mono()`**。

---

## 三、逐屏改造清单

### 3.1 `home_screen.dart` — 稿 09

* `Scaffold` 外层包一层背景渐变：
  ```dart
  Scaffold(
    backgroundColor: Colors.transparent,
    body: DecoratedBox(
      decoration: const BoxDecoration(gradient: hudBackgroundGradient),
      child: SafeArea(child: Column(...)),
    ),
  )
  ```
* `_StatusBar`：改成 `HudPanel`（margin 14/10，radius 10），内容 = 24dp logo · `LazyPerson`(w700 14) · `MARKET HUD v3.2`(mono 8, letterSpacing 3.8, accent) · `Spacer` · `HudLiveBadge(live: !controller.loading)` · 刷新按钮（accent）。
* `_SyncStrip`：`LinearProgressIndicator` → `HudSegmentBar(ratio: controller.syncProgress?.ratio)`；左侧 `SYNC`(mono 8.5 warn, ls 2.6)，右侧百分比 + 失败数（rise）。文案逻辑与现在的 `_text` 完全不变。
* `_MarketTabs`：每个 panel 用 `HudChip(label: panel.label, sub: '${count} ASSETS' 或 '$count', active: ...)`，`Row` + `SizedBox(width: 7)`。
* 标的头：名称 w700 21；副行 `002138 · SZ · TENCENT` 用 `mono(size: 9.5, color: textFaint, letterSpacing: 1)`；右侧价格 `GlowText(formatFullPrice(quote.price), size: 30, color: 涨跌色)`，下面一行 `+1.470` + 涨跌幅实心徽标（背景=涨跌色，字色 `#050914`，radius 3）。
* `_PeriodSwitch`：外层 `Container(color: panel.withValues(alpha:.8), radius 8, padding 3)`，内三个小 chip（选中 `hudFillActive`）；同一行右侧加 `HudLevelRail(activeIndex: 当前所处档位序号)` + `mono` 的当前涨幅（warn）。
  档位序号 = `autoDrawing` 里已站上的最高档，用 `level_rules.dart` 现有判定，别新写规则。
* K 线区：`HudBrackets(child: ClipRRect(borderRadius: 10, child: KlineChart(...)))`。
* `_BottomActions`：整条包成 `HudPanel(radius: 16, margin 14, padding 8)`，三个入口用 `Expanded` + 图标在上文字在下；八档局那格选中态发光（`HudPanel(active: true, glow: true)` 里嵌）。逻辑仍是 `onBandScan == null` 时不显示。

### 3.2 `kline_chart.dart` — 发光（改动很小）

* `_paintCandles`：把两次 `canvas.drawLine/drawRect` 换成 `drawGlowing`（`hud.dart` 提供）：
  ```dart
  drawGlowing(canvas, color, (p) => canvas.drawLine(Offset(x, highY), Offset(x, lowY), p),
      sigma: 2.0, alpha: .45, strokeWidth: math.max(barWidth * .12, 1.0));
  drawGlowing(canvas, color, (p) => canvas.drawRect(bodyRect, p), sigma: 2.4, alpha: .5);
  ```
* `_paintTrendSegments`：同样用 `drawGlowing(..., strokeWidth: 3, sigma: 3)`。
* `_paintGridAndAxis` / `_paintTimeAxis` / `_paintLevels`：只吃新色值，不改代码。
* `_OhlcStrip`：`Wrap` → 单行 `Row`（`O/H/L/C` 前缀，mono 9.5，稿 09 不折行），涨跌幅用涨跌色。
* 成交量透明度 0.46 → 0.42，蜡烛实体宽 `barWidth*0.7` → `0.66`（HUD 稿更透气）。

**性能**：`MaskFilter.blur` 每根蜡烛画两遍。60 根柱在中端机上实测无压力；若日后放开缩放到 300+ 根，把发光层改成整幅 `saveLayer` 一次性模糊，或只给最近 20 根发光。

### 3.3 `indicator_chart.dart`

* `_IndicatorBlock` 的 `Container` → `HudPanel(radius: 10, padding: EdgeInsets.zero)`，高度 110 → 96。
* 标题行：`MACD` `mono(9, textMuted, ls 1.4)` + `DIF/DEA` 当前值（accent / warn），去掉小色块图例。
* 线宽 1.4 → 1.5，并用 `drawGlowing(..., strokeWidth: 1.5, sigma: 2, alpha: .4)`。
* LON 线色改用 `AppColors.lonLine / lonmaLine`（已在主题里）。

### 3.4 `band_scan_screen.dart` — 稿 10

* `AppBar` 标题两行：`八档局 · 档位雷达` + `SHSZ MAIN · 90D BAND SCAN`（mono 8.5 accent ls 2.6）；背景透明，页面外层同样包 `hudBackgroundGradient`。
* 规则说明：`Container(border-left: 2px accent, radius 0/8/8/0, color hudPanel, padding 11/12)`，文案原样，`fontSize 10, height 1.7, textMuted`，`10 个点` 用 accent 高亮（`RichText`）。
* `_buildActions`：按钮走主题里的 `OutlinedButtonTheme`（已发光）；两个 checkbox 换成 12dp 圆角实心 accent 勾（`Icons.check`，字 10）；右侧 `2026-07-30 / SCAN 2213` 两行 mono 9。
* **`_buildGroupTabs()` 整个删掉**，换成：
  ```dart
  BandRadar(
    counts: controller.groupCounts,
    activeGroup: controller.activeGroup,
    onSelect: controller.setActiveGroup,
    visibleTotal: controller.visibleHits.length,
    allTotal: controller.hits.length,
  )
  ```
* 命中列表做成 **表格 / 卡片双视图**，右上角 `BandViewToggle` 切换，默认表格（`bool _tableView = true` 存在 `_BandScanScreenState`，不要进 controller）：

```dart
Row(children: [
  Expanded(child: BandRadar(...)),
]),
Padding(
  padding: const EdgeInsets.fromLTRB(16, 10, 16, 6),
  child: Row(children: [
    Text('${bandGroupNames[controller.activeGroup - 1]}档命中 ${controller.activeHits.length}',
        style: mono(size: 9.5, color: AppColors.textFaint, letterSpacing: 1.2)),
    const Spacer(),
    BandViewToggle(table: _tableView, onChanged: (v) => setState(() => _tableView = v)),
  ]),
),
Expanded(
  child: _tableView
      ? BandHitTable(
          hits: controller.activeHits,
          running: controller.running,
          onSelect: widget.onSelect,
        )
      : _buildHitCards(),   // 下面的卡片版
),
```

**表格版**（`band_hit_table.dart`，已写好）：九列全保留，代码/名称冻结在左 116dp，其余七列横向滚动，表头与表体共用一个 `ScrollController` 同步；涨停行整行 6% rise 底色 + 名称前发光圆点；数字全右对齐等宽。**`_buildTableHeader()` 和 `_rowLayout()` 删掉**，它们的列宽已迁到 `band_hit_table.dart` 的 `_columns`。

**卡片版** `_buildHitCards()`：每条命中一张 `HudPanel`：
  * 第一行：名称 w700 14 · 代码 mono 9 · `涨停` 实心徽标 · `Spacer` · `GlowText('+${hit.pct}%', size: 18, color: rise, blur: 16)`
  * 第二行：波段进度条 —— 左 `hit.low90`、右 `hit.price`，轨高 5 radius 3；填充宽度 = `hit.pct / hit.maxPct`；轨上两根 1.5dp 刻度针：`groupThreshold(hit.group)` 主线（yellowLine）和 `+10 点`入档线（text 80%），位置按 `pct / maxPct` 换算。
  * 第三行：`波段高 ${maxPct}% · 低点 ${lowDate} · 过线 ${crossDate} · 超出 +${over}%`（超出用 warn），mono 9。
  * `tint: hit.limitUp ? AppColors.rise : null`，`glow: index == 0`。

  * 列表仍是 `ListView.separated(itemCount: controller.activeHits.length)`，`onTap: () => widget.onSelect(hit.symbol)`，`separatorBuilder` → `SizedBox(height: 8)`（不要 Divider）。

两个视图共用同一份 `controller.activeHits`，切换不触发重扫。
* 空态/失败态文案与颜色不变，只把容器换成 `HudPanel`。

### 3.5 `watchlist_sheet.dart` — 稿 11

* 顶部：`showModalBottomSheet` 的 sheet 外层 → `Container(height: 712/880 屏高比 ≈ 0.81, decoration: 顶部 20 radius + 上边框 accent 28% + 竖向渐变 #102 → #050914)`；抓手 40×3 accent 45%。
* 标题行：`自选资产` w700 16 · `A SHARE · ${list.length}` mono 9 accent · `Spacer` · `涨 x · 跌 y`（现算，不新增状态）。
* 搜索框：`HudPanel(radius: 10, padding 11/13)`，右侧 `SEARCH` mono 8.5 accent。
* 排序 chip 用 `HudChip`。
* 每行 → `HudPanel(tint: 涨跌色, active: 选中, radius: 12)`：左名称 + `代码 · 成交额`(mono 9)，中间走势线，右价格 w700 14.5 + 涨跌幅。
  走势线固定这样写 —— 无缓存日线时自动退化成涨跌幅强度色块，不会留空白：
  ```dart
  Sparkline(
    values: closesOf(item.symbol),      // 本地日线尾段，取不到就返回 const []
    color: up ? AppColors.rise : AppColors.fall,
    fallbackPct: quote?.pctChg,         // 退化态用它画 “+3.53” + 强度条
  )
  ```
  `closesOf` 只读已缓存数据（`repository.store.getDailyBars`，命中即取最后 26 根 close），**不要为了画线去发网络请求**；连 `pctChg` 都没有时组件画一条静默基线。
* 底部 hint：`SWIPE LEFT TO REMOVE · TAP TO CHART` mono 9 `textDim`，前面 16dp accent 细线。**左滑删除交互保持现状**。

### 3.6 `summary_sheet.dart`

* 同款 sheet 外壳；八格摘要用 2 列 `HudPanel`（radius 10，label `textFaint` 10 / value mono 11.5）。
* 「自动画线」「线位颜色」两段标题：w700 12.5 + 右侧 1px `hudBorder` 横线 + 状态词（趋势色）。
* 色板圆点 19dp、选中态 `boxShadow` 两层（内圈底色 + 外圈 accent），保持现有 `lineColors` 存取逻辑。
* 底部两个按钮：`强制刷新`（accent 描边）/ `删除自选`（rise 描边）。

---

## 四、验收标准

1. `flutter analyze` 零 warning；`lib/logic`、`lib/data`、`lib/state` 的 git diff 为空。
2. 411×880dp（Pixel 6 竖屏）下四屏均无溢出、无 `RenderFlex overflow`；底部操作条与手势条不重叠；八档表格横向滚动时表头与表体不错位。
3. 数字全部等宽，价格跳动时不发生宽度抖动。
4. 长按 K 线十字线、日/周/月切换、市场切换、八档位切换、表格/卡片切换、左滑删除自选、扫描进度回显 —— 行为与改造前一致。
5. 发光只出现在：现价、涨跌幅、命中涨幅、蜡烛/趋势线、选中 chip 与选中档位轨。其它元素不得发光。
6. 深色为唯一主题（1d 不做浅色）；若后续要浅色，走 1c 的宣纸配色，`AppColors` 已按可切换结构组织。
7. 自选行走势线：有日线缓存画线，无缓存画涨跌幅强度块，两者宽度一致（56×20），列表右缘不参差。

---

## 六、文件位置

本包在**本项目**里的路径是 `handoff/`，目录结构已按 `app/lib` 镜像摆好，拷进你的仓库时一一对应：

```
handoff/HANDOFF.md                              → 只读文档，不入仓
handoff/lib/theme/app_theme.dart                → app/lib/theme/app_theme.dart      （整体替换）
handoff/lib/theme/hud.dart                      → app/lib/theme/hud.dart            （新增）
handoff/lib/ui/widgets/band_radar.dart          → app/lib/ui/widgets/band_radar.dart（新增）
handoff/lib/ui/widgets/band_hit_table.dart      → app/lib/ui/widgets/band_hit_table.dart（新增）
handoff/lib/ui/widgets/sparkline.dart           → app/lib/ui/widgets/sparkline.dart （新增）
```

右上「下载」可整包导出；也可以直接把 `handoff/` 交给 Claude Code，让它按第一节那条任务自己搬。

---

## 五、稿子取值速查（411dp）

* 页边距 14~16；卡片内距 12~14；行高 ≥ 44（触控）。
* 圆角：8（chip）/ 10（小卡）/ 12（列表卡）/ 16（底部浮层）/ 20（sheet 顶）。
* 描边：1px `accent 20%`；选中 `accent 50%`。
* 发光：`blurRadius 18~22`，`spreadRadius -2~-4`；画布 `MaskFilter sigma 2~3`。
* 字号：屏标题 15~16 / 标的名 21 / 现价 30 / 表内数字 9~11.5 / 全大写标签 8.5~9（`letterSpacing` 1.2~2.8）。
* 色值以 `handoff/lib/theme/app_theme.dart` 为唯一来源，稿子里的 hex 与它一致。
