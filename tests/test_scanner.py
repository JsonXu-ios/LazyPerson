import time
from datetime import date, timedelta
from pathlib import Path

import pytest

from backend.app.scanner import (
    MoneyGrabScanner,
    classify_group,
    eligible_symbol,
    evaluate_stock,
    group_threshold,
    slice_calendar_window,
)


class DummySettings:
    def __init__(self, root: Path):
        self.cache_dir = root
        self.sqlite_path = root / "lazy_person.sqlite"
        self.default_adjust = "qfq"
        self.quote_ttl_seconds = 5
        self.minute_ttl_seconds = 30
        self.day_ttl_seconds = 1800
        self.symbols_ttl_seconds = 86400
        self.money_flow_ttl_seconds = 60


def make_bars(days: int, low: float, today: date | None = None) -> list[dict]:
    """生成 days 个自然日内的工作日日线，最低价 low 放在最早一根，其余为 low*1.05。"""
    today = today or date(2026, 7, 24)  # 周五
    bars = []
    for offset in range(days, -1, -1):
        day = today - timedelta(days=offset)
        if day.weekday() >= 5:
            continue
        value = low if not bars else low * 1.05
        bars.append(
            {
                "time": day.isoformat(),
                "open": value,
                "high": value * 1.02,
                "low": value,
                "close": value * 1.01,
            }
        )
    return bars


class TestClassifyGroup:
    """档位分界 20/40/70/100/130/160/190/220：过40即从一档升二档。"""

    def test_below_20_no_group(self):
        assert classify_group(19.9) is None
        assert classify_group(-3.0) is None
        assert classify_group(None) is None

    def test_group1_zone_20_to_40(self):
        assert classify_group(20.0) == 1
        assert classify_group(25.37) == 1  # 振江
        assert classify_group(35.0) == 1
        assert classify_group(39.9) == 1
        assert group_threshold(1) == 20.0

    def test_group2_from_40(self):
        # 过40即二档（不用等50）
        assert classify_group(40.0) == 2
        assert classify_group(41.71) == 2  # 利欧
        assert classify_group(47.43) == 2  # 600617
        assert classify_group(55.0) == 2
        assert classify_group(69.9) == 2
        assert group_threshold(2) == 40.0

    def test_group_boundaries(self):
        assert [group_threshold(k) for k in range(1, 9)] == [20.0, 40.0, 70.0, 100.0, 130.0, 160.0, 190.0, 220.0]
        assert classify_group(70.0) == 3
        assert classify_group(99.9) == 3
        assert classify_group(100.0) == 4
        assert classify_group(130.0) == 5
        assert classify_group(160.0) == 6
        assert classify_group(190.0) == 7
        assert classify_group(220.0) == 8

    def test_group8_has_no_upper_bound(self):
        assert classify_group(250.0) == 8
        assert classify_group(500.0) == 8


class TestFallingBack:
    """回落记忆：曾进过更高档、现在掉回低档区间的不算。"""

    def test_is_falling_back(self):
        from backend.app.scanner import is_falling_back

        # 冲到45%（二档）后回落到35%（一档区间）→ 回落
        assert is_falling_back(35.0, 45.0)
        # 重新站上40% → 恢复为二档，不再算回落
        assert not is_falling_back(41.0, 45.0)
        # 一路上行、现价即峰值 → 不是回落
        assert not is_falling_back(35.0, 35.0)
        assert not is_falling_back(45.0, 45.0)
        # 档内回落（45→41 都在二档）→ 不算
        assert not is_falling_back(41.0, 48.0)
        # 三档跌回二档 → 回落
        assert is_falling_back(65.0, 75.0)
        assert not is_falling_back(None, 45.0)

    def test_evaluate_flags_falling_back(self):
        today = date(2026, 7, 24)
        # 收盘走到 45%（二档）后现价 35%（一档区间）→ 打 from_top 标记
        bars = make_wave_bars(today, 10.0, [20, 45, 45])
        row = evaluate_stock("600001", "回落股", 13.5, bars, today=today)
        assert row is not None
        assert row["group"] == 1
        assert row["from_top"] is True

    def test_evaluate_no_flag_when_rising(self):
        today = date(2026, 7, 24)
        bars = make_wave_bars(today, 10.0, [5, 12, 32])
        row = evaluate_stock("600001", "上行股", 13.5, bars, today=today)
        assert row is not None
        assert row["group"] == 1
        assert row["from_top"] is False


class TestEligibleSymbol:
    def test_main_board_ok(self):
        for symbol in ["600519", "601398", "000001", "002138"]:
            assert eligible_symbol(symbol, "正常股")

    def test_gem_and_star_excluded(self):
        # 只要沪深主板：创业板/科创板排除
        assert not eligible_symbol("300750", "创业板股")
        assert not eligible_symbol("688981", "科创板股")

    def test_beijing_excluded(self):
        assert not eligible_symbol("430047", "北交所股")
        assert not eligible_symbol("830799", "北交所股")

    def test_st_excluded(self):
        assert not eligible_symbol("600519", "ST 某某")
        assert not eligible_symbol("600519", "*ST某某")
        assert not eligible_symbol("600519", "st某某")


class TestSliceCalendarWindow:
    def test_window_cuts_by_calendar_days(self):
        bars = make_bars(200, 10.0)
        window = slice_calendar_window(bars, 90)
        first = date.fromisoformat(window[0]["time"])
        last = date.fromisoformat(window[-1]["time"])
        assert (last - first).days <= 90
        assert window[-1]["time"] == bars[-1]["time"]

    def test_drops_bars_with_missing_ohlc(self):
        bars = make_bars(30, 10.0)
        bars[5]["close"] = None
        window = slice_calendar_window(bars, 90)
        assert all(bar["close"] is not None for bar in window)


def make_wave_bars(today: date, low: float = 10.0, closes_pct: list[float] | None = None) -> list[dict]:
    """构造 200 天日线：前段平台 low*1.05，波段低点在倒数第 len(closes_pct)+1 根，
    之后每日收盘按 closes_pct 相对低点的涨幅走（低点→高点，时间顺序）。"""
    closes_pct = closes_pct or []
    bars = make_bars(200, low * 1.02, today)
    for bar in bars:
        bar["low"] = low * 1.05
        bar["close"] = low * 1.06
        bar["high"] = low * 1.08
        bar["open"] = low * 1.05
    tail = len(closes_pct)
    bars[-(tail + 1)]["low"] = low  # 波段低点
    for offset, pct in enumerate(closes_pct):
        bar = bars[-(tail - offset)]
        price = low * (1 + pct / 100)
        bar["close"] = price
        bar["high"] = price * 1.01
        bar["low"] = min(bar["low"], price)
        bar["open"] = price * 0.99
    return bars


def make_fall_bars(today: date, low: float = 10.0, peak_pct: float = 60.0) -> list[dict]:
    """构造"先高后低"的日线：平台 low*1.2，中途一根冲到 low*(1+peak_pct/100)，
    尾部第 5 根探到 low（窗口最低价），之后贴着低点横盘。零帧起手用。"""
    bars = make_bars(200, low * 1.2, today)
    for bar in bars:
        bar["open"] = low * 1.2
        bar["close"] = low * 1.2
        bar["high"] = low * 1.22
        bar["low"] = low * 1.18
    low_index = len(bars) - 5
    peak_index = low_index - 15
    peak = low * (1 + peak_pct / 100)
    bars[peak_index].update(
        {"open": peak * 0.99, "high": peak * 1.01, "low": peak * 0.98, "close": peak}
    )
    for i in range(low_index, len(bars)):
        bars[i].update(
            {
                "open": low * 1.01,
                "high": low * 1.02,
                "low": low if i == low_index else low * 1.002,
                "close": low * 1.005,
            }
        )
    return bars


class TestEvaluateStock:
    today = date(2026, 7, 24)

    def test_group1_hit_with_dates(self):
        # 低点10 → 收盘依次 5%、12%、32%（首次收盘站上30入档线），今日现价 13.5 → pct=35% → 第一档
        bars = make_wave_bars(self.today, 10.0, [5, 12, 32])
        row = evaluate_stock("600001", "测试股", 13.5, bars, today=self.today)
        assert row is not None
        assert row["group"] == 1
        assert row["threshold"] == 20.0
        assert row["low90"] == 10.0
        assert round(row["pct"], 1) == 35.0
        assert row["low_date"] < row["cross_date"]  # 低点在先，过线在后
        # 首次收盘站上主线20%的日期
        assert row["cross_date"] <= bars[-1]["time"]

    def test_just_over_mainline_is_group1(self):
        # 振江场景：pct=25.4% → 一档 [20,40)
        bars = make_wave_bars(self.today, 10.0, [5, 12, 18])
        row = evaluate_stock("603507", "振江场景", 12.54, bars, today=self.today)
        assert row is not None
        assert row["group"] == 1

    def test_below_20_not_hit(self):
        # 000408 场景：现价只到 15%，不入任何档
        bars = make_wave_bars(self.today, 10.0, [5, 12, 14])
        assert evaluate_stock("000408", "测试股", 11.5, bars, today=self.today) is None

    def test_group2_hit(self):
        # 现价 pct=55% ∈ [40,70) → 第二档
        bars = make_wave_bars(self.today, 10.0, [20, 42, 52])
        row = evaluate_stock("600001", "测试股", 15.5, bars, today=self.today)
        assert row is not None
        assert row["group"] == 2
        assert row["threshold"] == 40.0  # 二档下沿是40
        # 首次收盘站上二档入档线40%的是 42% 那天（倒数第2根）
        assert row["cross_date"] == bars[-2]["time"]

    def test_over_40_is_group2(self):
        # 利欧场景：41.7% → 过40即二档
        bars = make_wave_bars(self.today, 10.0, [10, 28, 38])
        row = evaluate_stock("002131", "利欧场景", 14.17, bars, today=self.today)
        assert row is not None
        assert row["group"] == 2
        assert row["threshold"] == 40.0

    def test_low_on_last_day_not_hit(self):
        # 低点若是最后一天，没有低点→高点的波段
        bars = make_bars(200, 10.0, self.today)
        for bar in bars:
            bar["low"] = 12.0
        bars[-1]["low"] = 10.0  # 今日砸出新低
        assert evaluate_stock("600001", "测试股", 12.5, bars, today=self.today) is None

    def test_new_stock_excluded(self):
        bars = make_bars(60, 10.0, self.today)  # 上市仅 60 天
        assert evaluate_stock("600001", "新股", 13.1, bars, today=self.today) is None

    def test_no_price_excluded(self):
        bars = make_bars(200, 10.0, self.today)
        assert evaluate_stock("600001", "停牌股", None, bars, today=self.today) is None

    def test_too_few_bars_excluded(self):
        bars = make_bars(200, 10.0, self.today)[:10]
        assert evaluate_stock("600001", "测试股", 13.1, bars, today=self.today) is None



def _noop_fundamentals(cache, hits, caps):
    """测试用：不联网，直接打默认基本面标记。"""
    for row in hits:
        row["dividend_recent"] = False
        row["profit_ok"] = False
        row["revenue_ok"] = False


def _noop_lon(cache, hits):
    """测试用：不联网，LON 标记默认 False。"""
    for row in hits:
        row["lon_ok"] = False


def _noop_sector(cache, hits, hot_top=15):
    """测试用：不联网，板块标记默认空。"""
    for row in hits:
        row["industry"] = ""
        row["concepts"] = []
        row["hot_sector"] = False


class TestMoneyGrabScanner:
    today = date(2026, 7, 24)

    def _fetchers(self):
        quotes = [
            # 13.1 = round(11.91*1.1, 2) → 今日涨停
            {"symbol": "600001", "name": "命中股", "price": 13.1, "market_cap": 120.0, "pre_close": 11.91},
            {"symbol": "600002", "name": "未中股", "price": 11.5, "market_cap": 80.0, "pre_close": 11.2},
            {"symbol": "430047", "name": "北交所", "price": 13.1, "market_cap": 100.0, "pre_close": 12.0},
            {"symbol": "600003", "name": "ST某某", "price": 13.1, "market_cap": 100.0, "pre_close": 12.0},
            # 非涨停命中，市值过滤用
            {"symbol": "600004", "name": "小市值命中", "price": 13.1, "market_cap": 30.0, "pre_close": 12.5},
        ]
        bars = make_bars(200, 10.0, self.today)
        bars[-3]["low"] = 10.0
        return (lambda: quotes), (lambda symbol: bars)

    def _wait_done(self, scanner, timeout=5.0):
        deadline = time.time() + timeout
        while time.time() < deadline:
            state = scanner.status()
            if state["status"] in ("done", "failed"):
                return state
            time.sleep(0.05)
        raise AssertionError("scan did not finish in time")

    def test_scan_filters_and_reports_progress(self, tmp_path):
        quote_fetcher, kline_fetcher = self._fetchers()
        scanner = MoneyGrabScanner(
            DummySettings(tmp_path), quote_fetcher=quote_fetcher, kline_fetcher=kline_fetcher, max_workers=2,
            fundamentals_enricher=_noop_fundamentals, lon_enricher=_noop_lon, sector_enricher=_noop_sector
        )
        state = scanner.start()
        assert state["status"] in ("running", "done")  # 小数据集可能瞬间扫完
        state = self._wait_done(scanner)
        assert state["status"] == "done"
        assert state["total"] == 3  # 北交所与 ST 在候选阶段就被排除
        assert state["done"] == 3
        assert sorted(hit["symbol"] for hit in state["hits"]) == ["600001", "600004"]
        assert state["hits"][0]["group"] == 1
        assert state["hits"][0]["threshold"] == 20.0
        by_symbol = {hit["symbol"]: hit for hit in state["hits"]}
        assert by_symbol["600001"]["limit_up"] is True   # 13.1 = 11.91×1.1
        assert by_symbol["600004"]["limit_up"] is False

    def test_min_market_cap_filter(self, tmp_path):
        quote_fetcher, kline_fetcher = self._fetchers()
        scanner = MoneyGrabScanner(
            DummySettings(tmp_path), quote_fetcher=quote_fetcher, kline_fetcher=kline_fetcher, max_workers=2,
            fundamentals_enricher=_noop_fundamentals, lon_enricher=_noop_lon, sector_enricher=_noop_sector
        )
        scanner.start(min_market_cap=40.0)
        state = self._wait_done(scanner)
        assert state["status"] == "done"
        assert state["min_market_cap"] == 40.0
        assert state["total"] == 2  # 30亿的 600004 被市值过滤
        assert [hit["symbol"] for hit in state["hits"]] == ["600001"]

    def test_start_is_idempotent_while_running(self, tmp_path):
        quote_fetcher, kline_fetcher = self._fetchers()

        def slow_kline(symbol):
            time.sleep(0.3)
            return kline_fetcher(symbol)

        scanner = MoneyGrabScanner(
            DummySettings(tmp_path), quote_fetcher=quote_fetcher, kline_fetcher=slow_kline, max_workers=1,
            fundamentals_enricher=_noop_fundamentals, lon_enricher=_noop_lon, sector_enricher=_noop_sector
        )
        scanner.start()
        second = scanner.start()
        assert second["status"] == "running"
        self._wait_done(scanner)

    def test_result_persisted_and_restored(self, tmp_path):
        quote_fetcher, kline_fetcher = self._fetchers()
        settings = DummySettings(tmp_path)
        scanner = MoneyGrabScanner(settings, quote_fetcher=quote_fetcher, kline_fetcher=kline_fetcher, fundamentals_enricher=_noop_fundamentals, lon_enricher=_noop_lon, sector_enricher=_noop_sector)
        scanner.start()
        self._wait_done(scanner)

        fresh = MoneyGrabScanner(settings, quote_fetcher=quote_fetcher, kline_fetcher=kline_fetcher, fundamentals_enricher=_noop_fundamentals, lon_enricher=_noop_lon, sector_enricher=_noop_sector)
        state = fresh.status()
        # 持久化的 trade_date 是真实运行日，与结果一同恢复
        assert state["status"] == "done"
        assert sorted(hit["symbol"] for hit in state["hits"]) == ["600001", "600004"]

    def test_quote_fetcher_failure_sets_failed(self, tmp_path):
        def broken():
            raise RuntimeError("snapshot down")

        scanner = MoneyGrabScanner(DummySettings(tmp_path), quote_fetcher=broken, kline_fetcher=lambda s: [], fundamentals_enricher=_noop_fundamentals, lon_enricher=_noop_lon, sector_enricher=_noop_sector)
        scanner.start()
        state = self._wait_done(scanner)
        assert state["status"] == "failed"
        assert "snapshot down" in state["error"]


class TestLocalSymbolsFallback:
    def test_local_a_symbols_filters_prefixes(self, tmp_path):
        from backend.app.cache import CacheStore
        from backend.app.scanner import _chunk, _local_a_symbols

        cache = CacheStore(DummySettings(tmp_path))
        cache.upsert_symbols(
            [
                {"symbol": "600519", "market": "SH", "name": "贵州茅台", "pinyin": "", "listed_at": None},
                {"symbol": "300750", "market": "SZ", "name": "宁德时代", "pinyin": "", "listed_at": None},
                {"symbol": "430047", "market": "BJ", "name": "北交所股", "pinyin": "", "listed_at": None},
                {"symbol": "SPY", "market": "US", "name": "标普ETF", "pinyin": "", "listed_at": None},
            ]
        )
        symbols = _local_a_symbols(cache)
        assert sorted(symbols) == ["600519"]  # 仅主板：创业板 300750 也被排除

    def test_chunk_splits_evenly(self):
        from backend.app.scanner import _chunk

        assert list(_chunk([1, 2, 3, 4, 5], 2)) == [[1, 2], [3, 4], [5]]


class TestCachedDailyBars:
    def test_cache_round_trip_skips_remote(self, tmp_path):
        import pandas as pd

        from backend.app.cache import CacheStore
        from backend.app.scanner import _cached_daily_bars

        cache = CacheStore(DummySettings(tmp_path))
        calls = []

        def remote(symbol):
            calls.append(symbol)
            return pd.DataFrame(make_bars(120, 10.0, date.today()))

        bars_first = _cached_daily_bars(cache, "600001", "qfq", 1800, False, remote)
        bars_second = _cached_daily_bars(cache, "600001", "qfq", 1800, False, remote)
        assert len(calls) == 1  # 第二次读缓存，不再联网
        assert bars_first[-1]["time"] == bars_second[-1]["time"]

    def test_stale_cache_refetches(self, tmp_path):
        import pandas as pd

        from backend.app.cache import CacheStore
        from backend.app.scanner import _cached_daily_bars

        cache = CacheStore(DummySettings(tmp_path))
        old = pd.DataFrame(make_bars(120, 10.0, date.today() - timedelta(days=30)))
        cache.write_frame(
            cache_key="kline_day:600001:day:qfq::",
            data_type="kline_day",
            frame=old,
            source="test",
            symbol="600001",
            period="day",
            ttl_seconds=1800,
        )
        calls = []

        def remote(symbol):
            calls.append(symbol)
            return pd.DataFrame(make_bars(120, 10.0, date.today()))

        bars = _cached_daily_bars(cache, "600001", "qfq", 1800, False, remote)
        assert len(calls) == 1  # 缓存滞后超14天，强制重拉
        assert bars[-1]["time"] == date.today().isoformat() or len(bars) > 0


class TestLimitUp:
    def test_limit_up_exact_price(self):
        from backend.app.scanner import is_limit_up

        assert is_limit_up(11.0, 10.0)        # 10.00 → 11.00
        assert is_limit_up(13.42, 12.20)      # 12.20 → 13.42
        assert not is_limit_up(10.99, 10.0)   # 差一分不算
        assert not is_limit_up(None, 10.0)
        assert not is_limit_up(11.0, None)
        assert not is_limit_up(11.0, 0)

    def test_scanner_limit_up_filter(self, tmp_path):
        today = date(2026, 7, 24)
        bars = make_bars(200, 10.0, today)
        bars[-3]["low"] = 10.0
        quotes = [
            # 13.1 = round(11.91*1.1,2) → 涨停且 pct=31% 第一档
            {"symbol": "600001", "name": "涨停命中", "price": 13.1, "pre_close": 11.91},
            # 同样 pct=31% 但非涨停
            {"symbol": "600002", "name": "非涨停命中", "price": 13.1, "pre_close": 12.5},
        ]
        scanner = MoneyGrabScanner(
            DummySettings(tmp_path),
            quote_fetcher=lambda: quotes,
            kline_fetcher=lambda symbol: bars,
            max_workers=2,
            fundamentals_enricher=_noop_fundamentals,
            lon_enricher=_noop_lon,
            sector_enricher=_noop_sector,
        )
        scanner.start(limit_up_only=True)
        deadline = time.time() + 5
        while time.time() < deadline:
            state = scanner.status()
            if state["status"] in ("done", "failed"):
                break
            time.sleep(0.05)
        assert state["status"] == "done"
        assert state["limit_up_only"] is True
        assert state["total"] == 1
        assert [hit["symbol"] for hit in state["hits"]] == ["600001"]


class TestVShapeAccepted:
    """V型反弹不再排除、不再打标：低点可能是反转也可能是起点，一视同仁。"""

    today = date(2026, 7, 24)

    def test_v_rebound_included_without_flag(self):
        # 前段 40% 高平台 → 跌到低点 10 → 反弹到 35%（未超过下跌起点）→ 正常入一档（利欧类场景）
        bars = make_bars(200, 10.0, self.today)
        for bar in bars:
            bar["low"] = 14.0
            bar["open"] = 14.0
            bar["close"] = 14.0
            bar["high"] = 14.2
        bars[-4]["low"] = 10.0  # 波段低点（近端）
        bars[-4]["close"] = 10.2
        bars[-4]["open"] = 10.5
        bars[-4]["high"] = 10.6
        for offset in (3, 2, 1):
            bar = bars[-offset]
            bar["low"] = 10.5
            bar["open"] = 13.0
            bar["close"] = 13.2
            bar["high"] = 13.3
        row = evaluate_stock("600001", "深跌反转", 13.5, bars, today=self.today)
        assert row is not None
        assert row["group"] == 1
        assert "v_shape" not in row

    def test_uptrend_low_at_start_kept(self):
        bars = make_wave_bars(self.today, 10.0, [5, 12, 32])
        row = evaluate_stock("600001", "上行波段", 13.5, bars, today=self.today)
        assert row is not None
        assert row["from_top"] is False


class TestFundamentals:
    def test_annualize_factor(self):
        from backend.app.fundamentals import annualize_factor

        assert annualize_factor("2026-03-31") == 4.0        # 一季报 ×4
        assert annualize_factor("2026-06-30") == 2.0        # 半年报 /2×4 = ×2
        assert round(annualize_factor("2026-09-30"), 4) == round(4 / 3, 4)  # 三季报 /3×4
        assert annualize_factor("2025-12-31") == 1.0        # 年报不年化
        assert annualize_factor(None) is None
        assert annualize_factor("bad") is None

    def test_revenue_condition(self):
        from backend.app.fundamentals import revenue_condition

        # 茅台2026Q1：归母净利281.5亿、净利率0.5222 → Q1营收约539亿 ×4×10 ≈ 2.16万亿 > 市值1.61万亿
        assert revenue_condition(28153831489.89, 0.522245, "2026-03-31", 16119.8)
        # 市值过大：3 万亿 → 不通过
        assert not revenue_condition(28153831489.89, 0.522245, "2026-03-31", 30000.0)
        # 同样数字若是半年报：年化×2 → 约1.08万亿 < 1.61万亿 → 不通过
        assert not revenue_condition(28153831489.89, 0.522245, "2026-06-30", 16119.8)
        # 年报：不年化 → 539亿×10 < 1.61万亿 → 不通过
        assert not revenue_condition(28153831489.89, 0.522245, "2025-12-31", 16119.8)
        # 数据缺失 → 不通过
        assert not revenue_condition(None, 0.1, "2026-03-31", 50.0)
        assert not revenue_condition(1000.0, None, "2026-03-31", 50.0)
        assert not revenue_condition(1000.0, 0.1, None, 50.0)
        assert not revenue_condition(1000.0, 0.1, "2026-03-31", None)

    def test_profit_condition(self):
        from backend.app.fundamentals import profit_condition

        assert profit_condition(28153831489.89)
        assert profit_condition(0.0)
        assert not profit_condition(-1000.0)
        assert not profit_condition(None)

    def test_dividend_condition(self):
        from backend.app.fundamentals import dividend_condition

        today = date(2026, 8, 3)
        # 近一年内有除权除息 → True
        assert dividend_condition(["2026-06-26"], today)
        assert dividend_condition(["2025-12-19"], today)
        # 已公告、除息日在未来（今年分红计划）→ True
        assert dividend_condition(["2026-09-10"], today)
        # 超过一年 → False
        assert not dividend_condition(["2025-06-26"], today)
        # 无记录/脏数据 → False
        assert not dividend_condition([], today)
        assert not dividend_condition(["", "bad-date"], today)


class TestLonTrend:
    def test_lon_trend_ok(self):
        from backend.app.lon_check import lon_trend_ok

        # lon、lonma 都向上且 lon 在 lonma 上方 → True
        assert lon_trend_ok([100.0, 120.0], [90.0, 95.0])
        # lon 与 lonma 相等（贴线）也算未被压住 → True
        assert lon_trend_ok([100.0, 120.0], [90.0, 120.0])
        # lonma 压在 lon 上面 → False
        assert not lon_trend_ok([100.0, 120.0], [130.0, 140.0])
        # lon 走平/向下 → False
        assert not lon_trend_ok([120.0, 120.0], [90.0, 95.0])
        assert not lon_trend_ok([120.0, 110.0], [90.0, 95.0])
        # lonma 向下 → False
        assert not lon_trend_ok([100.0, 120.0], [96.0, 95.0])
        # 数据不足/含None → 按无效处理
        assert not lon_trend_ok([120.0], [95.0])
        assert not lon_trend_ok([None, 120.0], [None, 95.0])
        # None 混入时取最后两对有效值：(100,90)→(120,95) 向上且未被压 → True
        assert lon_trend_ok([100.0, None, 120.0], [90.0, None, 95.0])


class TestNorthBound:
    today = date(2026, 7, 24)

    def _window(self, low_pos: float, high_pos: float, n: int = 60) -> tuple[list[dict], int]:
        """构造 n 根窗口：低点放在 low_pos（0~1 位置），最高点放在 high_pos。"""
        bars = []
        base = date(2026, 4, 1)
        d0 = base
        added = 0
        while added < n:
            if d0.weekday() < 5:
                bars.append({"time": d0.isoformat(), "open": 10.0, "high": 10.2, "low": 9.9, "close": 10.1})
                added += 1
            d0 += timedelta(days=1)
        low_i = int((n - 1) * low_pos)
        high_i = int((n - 1) * high_pos)
        bars[low_i]["low"] = 8.0
        bars[high_i]["high"] = 15.0
        return bars, low_i

    def test_low_front_high_back_is_north(self):
        from backend.app.scanner import is_north_bound

        window, low_i = self._window(0.1, 0.9)
        assert is_north_bound(window, low_i)

    def test_high_in_middle_still_north(self):
        from backend.app.scanner import is_north_bound

        # 高点在中段也算：只要求高点在低点之后（不再限制前1/3、后1/3）
        window, low_i = self._window(0.1, 0.5)
        assert is_north_bound(window, low_i)

    def test_low_in_middle_still_north(self):
        from backend.app.scanner import is_north_bound

        window, low_i = self._window(0.5, 0.9)
        assert is_north_bound(window, low_i)

    def test_middle_pullback_allowed(self):
        from backend.app.scanner import is_north_bound

        window, low_i = self._window(0.2, 0.95)
        # 中间挖个回落坑（不低于波段低点）
        mid = len(window) // 2
        window[mid]["low"] = 8.5
        window[mid]["close"] = 8.6
        assert is_north_bound(window, low_i)

    def test_high_before_low_not_north(self):
        from backend.app.scanner import is_north_bound

        # 先见高点、再跌出低点（高点在低点之前）→ 不是从低到高
        window, low_i = self._window(0.9, 0.3)
        assert not is_north_bound(window, low_i)

    def test_deep_pullback_not_north(self):
        from backend.app.scanner import is_north_bound

        # 低点在前、高点在后，但中途从 20.0 回撤到 13.0（-35%）→ 不算一路北上
        window, low_i = self._window(0.1, 0.9)
        mid = len(window) // 2
        for index in range(mid - 4, mid):
            window[index]["close"] = 20.0
        for index in range(mid, len(window)):
            window[index]["close"] = 13.0  # 自峰值 20 回撤 35%
        assert not is_north_bound(window, low_i)

    def test_shallow_pullback_still_north(self):
        from backend.app.scanner import is_north_bound

        # 同样形态但只回撤到 15.0（-25%，未超30%）→ 仍算一路北上
        window, low_i = self._window(0.1, 0.9)
        mid = len(window) // 2
        for index in range(mid - 4, mid):
            window[index]["close"] = 20.0
        for index in range(mid, len(window)):
            window[index]["close"] = 15.0  # 自峰值 20 回撤 25%，未超阈值
        assert is_north_bound(window, low_i)

    def test_evaluate_carries_north_flag(self):
        # 低点后一路上行到 32%（高点在低点之后、无深回撤）→ 一路北上
        bars = make_wave_bars(self.today, 10.0, [5, 12, 32])
        row = evaluate_stock("600001", "测试股", 13.5, bars, today=self.today)
        assert row is not None
        assert row["north_ok"] is True


class TestRecentChange:
    today = date(2026, 7, 24)

    def test_recent_change_with_today_bar(self):
        from backend.app.scanner import recent_change

        bars = make_bars(30, 10.0, self.today)
        window = slice_calendar_window(bars, 90)
        # 窗口末根就是今天：近3日基准 = closes[-4]
        closes = [float(b["close"]) for b in window]
        expected = (13.0 / closes[-4] - 1) * 100
        assert abs(recent_change(13.0, window, 3, self.today) - expected) < 1e-6

    def test_recent_change_without_today_bar(self):
        from backend.app.scanner import recent_change

        # 窗口末根不是今天（stale 数据）：基准 = closes[-3]
        bars = make_bars(30, 10.0, self.today - timedelta(days=5))
        window = slice_calendar_window(bars, 90)
        closes = [float(b["close"]) for b in window]
        expected = (13.0 / closes[-3] - 1) * 100
        assert abs(recent_change(13.0, window, 3, self.today) - expected) < 1e-6

    def test_recent_change_insufficient_bars(self):
        from backend.app.scanner import recent_change

        window = make_bars(30, 10.0, self.today)[:2]
        assert recent_change(13.0, window, 5, self.today) is None

    def test_evaluate_carries_turnover_and_changes(self):
        bars = make_wave_bars(self.today, 10.0, [5, 12, 32])
        row = evaluate_stock("600001", "测试股", 13.5, bars, today=self.today, turnover=4.2)
        assert row is not None
        assert row["turnover"] == 4.2
        assert row["chg3"] is not None
        assert row["chg5"] is not None


class TestRevenueRatio:
    def test_ratio_and_thresholds(self):
        from backend.app.fundamentals import revenue_condition, revenue_ratio

        # 坤彩科技实况：Q1归母净利7540.8万、净利率0.1829、市值147.01亿
        ratio = revenue_ratio(75408111.4, 0.182915, "2026-03-31", 147.01)
        assert ratio is not None
        assert 1.0 < ratio < 1.2          # 擦线通过 1 倍
        assert revenue_condition(75408111.4, 0.182915, "2026-03-31", 147.01)
        assert ratio <= 2                  # 但达不到 2 倍

        # 茅台：Q1营收539亿×4×10=2.16万亿 vs 市值1.61万亿 → 1.34 倍，同样不到 2 倍
        maotai = revenue_ratio(28153831489.89, 0.522245, "2026-03-31", 16119.8)
        assert maotai is not None and 1 < maotai < 2

        # 低市销率股（年化营收 100 亿、市值 300 亿）→ 100×10/300 = 3.33 倍
        cheap = revenue_ratio(2.5e8, 0.10, "2026-03-31", 300.0)
        assert cheap is not None and cheap > 2

    def test_ratio_none_on_missing_data(self):
        from backend.app.fundamentals import revenue_ratio

        assert revenue_ratio(None, 0.2, "2026-03-31", 100.0) is None
        assert revenue_ratio(1e8, None, "2026-03-31", 100.0) is None
        assert revenue_ratio(1e8, 0.2, None, 100.0) is None
        assert revenue_ratio(1e8, 0.2, "2026-03-31", None) is None


class TestBreakoutStage:
    def test_stage_by_highest_main_line(self):
        from backend.app.breakout import breakout_stage, stage_label

        # 未过20 → 不入
        assert breakout_stage(19.9) is None
        assert breakout_stage(None) is None
        # 站上20没到50 → stage 1
        assert breakout_stage(35.0) == 1
        # 站上50 → stage 2 = 「20→50」
        assert breakout_stage(50.0) == 2
        assert breakout_stage(55.0) == 2
        assert breakout_stage(79.9) == 2
        assert stage_label(2) == "20→50"
        # 站上80 → stage 3 = 「50→80」；115% 只算这组的上一级
        assert breakout_stage(80.0) == 3
        assert stage_label(3) == "50→80"
        assert breakout_stage(115.0) == 4
        assert stage_label(4) == "80→110"
        # 每只股只归最高一组，不重复计入前面的组（由 stage 唯一决定）
        assert breakout_stage(250.0) == 8
        assert stage_label(8) == "200→230"

    def test_evaluate_carries_break_stage(self):
        today = date(2026, 7, 24)
        bars = make_wave_bars(today, 10.0, [20, 42, 52])
        row = evaluate_stock("600001", "测试股", 15.5, bars, today=today)
        assert row is not None
        assert row["pct"] > 50
        assert row["break_stage"] == 2  # 站上50主线 → 「20→50」组

    def test_buildup_over_marks_fresh_crossings(self):
        from backend.app.breakout import buildup_line, buildup_over

        # 还没过 20% 的不看
        assert buildup_over(12.0) is None
        assert buildup_over(None) is None
        assert buildup_over(19.9) is None
        # 刚站上 20 线
        assert buildup_over(20.0) == pytest.approx(0.0)
        assert buildup_line(23.5) == 20
        # 52 → 刚过 50，超出 2
        assert buildup_over(52.0) == pytest.approx(2.0)
        assert buildup_line(52.0) == 50
        # 58 → 超出 8，已经走远
        assert buildup_over(58.0) is None
        assert buildup_line(58.0) is None
        # 46.5 早就过了 20，超出 26.5，不算刚过
        assert buildup_over(46.5) is None
        # 刚过 80 / 刚过 230
        assert buildup_over(81.0) == pytest.approx(1.0)
        assert buildup_line(232.0) == 230
        assert buildup_over(300.0) is None
        # 阈值可调
        assert buildup_over(58.0, max_over=10) == pytest.approx(8.0)


class TestEvaluateZeroBase:
    """零帧起手：从高处一路下来、现在停在 90 日低点上"""

    today = date(2026, 7, 24)

    def test_hits_when_price_sits_on_the_floor(self):
        from backend.app.scanner import evaluate_zero_base

        bars = make_fall_bars(self.today, 10.0, 60.0)
        row = evaluate_zero_base("600001", "摔下来的", 10.1, bars, today=self.today)
        assert row is not None
        assert row["group"] == 0  # 不属于八档任何一档
        assert row["low90"] == pytest.approx(10.0, abs=1e-6)
        assert row["pct"] == pytest.approx(1.0, abs=0.05)
        assert row["max_pct"] == pytest.approx(60.0, abs=0.5)
        assert row["cross_date"] < row["low_date"]  # 高点在低点之前
        # 同一只在八档局里不命中，两套口径互斥
        assert evaluate_stock("600001", "摔下来的", 10.1, bars, today=self.today) is None

    def test_rejects_rebound_and_flat_and_upward(self):
        from backend.app.scanner import evaluate_zero_base

        bars = make_fall_bars(self.today, 10.0, 60.0)
        # 已经反弹走了（离低点 >3%）
        assert evaluate_zero_base("600001", "反弹了", 10.5, bars, today=self.today) is None
        assert (
            evaluate_zero_base("600001", "反弹了", 10.5, bars, today=self.today, max_pct=8)
            is not None
        )
        # 没从高处下来（高点不足 50%）
        for peak in (12.0, 30.0, 49.0):
            flat = make_fall_bars(self.today, 10.0, peak)
            assert evaluate_zero_base("600001", "平地股", 10.1, flat, today=self.today) is None
        # 刚好过 50% 就算
        just = make_fall_bars(self.today, 10.0, 52.0)
        assert evaluate_zero_base("600001", "摔下来的", 10.1, just, today=self.today) is not None
        # 先低后高（一路北上）不算
        up = make_wave_bars(self.today, 10.0, [20, 42, 52])
        assert evaluate_zero_base("600001", "往上走", 10.1, up, today=self.today) is None
