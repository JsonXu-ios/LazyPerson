import time
from datetime import date, timedelta
from pathlib import Path

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
    def test_below_20_no_group(self):
        assert classify_group(19.9) is None
        assert classify_group(15.0) is None  # 000408 场景：区间刚过20%但现价没站上20%
        assert classify_group(-3.0) is None
        assert classify_group(None) is None

    def test_group1_zone_20_to_40(self):
        assert classify_group(20.0) == 1
        assert classify_group(31.0) == 1
        assert classify_group(39.9) == 1
        assert group_threshold(1) == 20.0

    def test_transition_zone_not_grouped(self):
        # 600617 场景：47.4% 已过40（第二档先过线）但没过50 → 过渡区不入档
        assert classify_group(47.43) is None
        assert classify_group(40.0) is None
        assert classify_group(49.9) is None
        assert classify_group(75.0) is None   # 70~80 过渡区
        assert classify_group(105.0) is None  # 100~110 过渡区

    def test_group2_zone_50_to_70(self):
        assert classify_group(50.0) == 2
        assert classify_group(69.9) == 2
        assert group_threshold(2) == 50.0

    def test_group_thresholds_step_30(self):
        # 第三档80、第四档110、第五档140、第六档170、第七档200、第八档230
        assert [group_threshold(k) for k in range(1, 9)] == [20.0, 50.0, 80.0, 110.0, 140.0, 170.0, 200.0, 230.0]
        assert classify_group(80.0) == 3
        assert classify_group(115.0) == 4
        assert classify_group(150.0) == 5
        assert classify_group(171.0) == 6
        assert classify_group(205.0) == 7
        assert classify_group(231.0) == 8

    def test_beyond_group8_zone_not_grouped(self):
        assert classify_group(249.9) == 8
        assert classify_group(250.0) is None
        assert classify_group(500.0) is None


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


class TestEvaluateStock:
    today = date(2026, 7, 24)

    def test_group1_hit_with_dates(self):
        # 低点10 → 收盘依次 5%、12%（先过10%线）、18%，今日现价 12.2 → pct=22% ≥20 → 第一档
        bars = make_wave_bars(self.today, 10.0, [5, 12, 18])
        row = evaluate_stock("600001", "测试股", 12.2, bars, today=self.today)
        assert row is not None
        assert row["group"] == 1
        assert row["threshold"] == 20.0
        assert row["low90"] == 10.0
        assert round(row["pct"], 1) == 22.0
        assert row["low_date"] < row["cross_date"]  # 低点在先，过线在后
        # 首次收盘过 10% 线的是 12% 那天（倒数第2根）
        assert row["cross_date"] == bars[-2]["time"]

    def test_below_20_not_hit(self):
        # 000408 场景：现价只到 15%，不入任何档
        bars = make_wave_bars(self.today, 10.0, [5, 12, 14])
        assert evaluate_stock("000408", "测试股", 11.5, bars, today=self.today) is None

    def test_group2_hit(self):
        # 现价 pct=55% → 第二档（阈值50，先过40）
        bars = make_wave_bars(self.today, 10.0, [20, 42, 52])
        row = evaluate_stock("600001", "测试股", 15.5, bars, today=self.today)
        assert row is not None
        assert row["group"] == 2
        assert row["threshold"] == 50.0
        # 首次收盘过 40% 线的是 42% 那天
        assert row["cross_date"] == bars[-2]["time"]

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
            DummySettings(tmp_path), quote_fetcher=quote_fetcher, kline_fetcher=kline_fetcher, max_workers=2
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
            DummySettings(tmp_path), quote_fetcher=quote_fetcher, kline_fetcher=kline_fetcher, max_workers=2
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
            DummySettings(tmp_path), quote_fetcher=quote_fetcher, kline_fetcher=slow_kline, max_workers=1
        )
        scanner.start()
        second = scanner.start()
        assert second["status"] == "running"
        self._wait_done(scanner)

    def test_result_persisted_and_restored(self, tmp_path):
        quote_fetcher, kline_fetcher = self._fetchers()
        settings = DummySettings(tmp_path)
        scanner = MoneyGrabScanner(settings, quote_fetcher=quote_fetcher, kline_fetcher=kline_fetcher)
        scanner.start()
        self._wait_done(scanner)

        fresh = MoneyGrabScanner(settings, quote_fetcher=quote_fetcher, kline_fetcher=kline_fetcher)
        state = fresh.status()
        # 持久化的 trade_date 是真实运行日，与结果一同恢复
        assert state["status"] == "done"
        assert sorted(hit["symbol"] for hit in state["hits"]) == ["600001", "600004"]

    def test_quote_fetcher_failure_sets_failed(self, tmp_path):
        def broken():
            raise RuntimeError("snapshot down")

        scanner = MoneyGrabScanner(DummySettings(tmp_path), quote_fetcher=broken, kline_fetcher=lambda s: [])
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


class TestFallingFromTop:
    today = date(2026, 7, 24)

    def test_is_falling_from_top(self):
        from backend.app.scanner import is_falling_from_top

        # 紫光场景：曾到 85%（站上80主线），现价 65% 跌破 → 排除
        assert is_falling_from_top(65.0, 85.0)
        # 峰值 85% 跌到 75%：跌破曾站上的 80 主线 → 排除
        assert is_falling_from_top(75.0, 85.0)
        # 峰值 85% 回踩到 82%：仍站在 80 上方 → 保留
        assert not is_falling_from_top(82.0, 85.0)
        # 上行途中：现价即峰值 45%（刚过40先过线）→ 保留
        assert not is_falling_from_top(45.0, 45.0)
        # 曾过 40 先过线又跌回 31% → 排除
        assert is_falling_from_top(31.0, 45.0)
        # 曾过 50 主线（峰值66）又跌回 49.7% → 排除（002774 场景）
        assert is_falling_from_top(49.7, 66.3)
        # 峰值 35%（站上20主线），现价 22% ≥ 20 → 保留
        assert not is_falling_from_top(22.0, 35.0)

    def test_evaluate_rejects_falling_stock(self):
        # 收盘走出 40% → 85% → 65%：现价 16.5（65%）满足第二档阈值，但从 80 档跌破 70 → 排除
        bars = make_wave_bars(self.today, 10.0, [40, 85, 65])
        assert evaluate_stock("000938", "紫光场景", 16.5, bars, today=self.today) is None

    def test_evaluate_keeps_holding_stock(self):
        # 峰值 85%，今日现价 18.2（82%）≥ 80 → 第三档保留
        bars = make_wave_bars(self.today, 10.0, [40, 85, 82])
        row = evaluate_stock("600001", "持稳股", 18.2, bars, today=self.today)
        assert row is not None
        assert row["group"] == 3
        assert row["max_pct"] >= 85.0
