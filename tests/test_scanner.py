import time
from datetime import date, timedelta
from pathlib import Path

from backend.app.scanner import (
    MoneyGrabScanner,
    band_position,
    eligible_symbol,
    evaluate_stock,
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


class TestBandPosition:
    def test_pct_10_not_hit(self):
        assert band_position(10.0) is None

    def test_pct_just_above_10_hits_band_0(self):
        band, over = band_position(10.5)
        assert band == 0
        assert round(over, 2) == 0.5

    def test_pct_30_boundary_not_hit(self):
        assert band_position(30.0) is None

    def test_pct_31_hits_band_20(self):
        band, over = band_position(31.0)
        assert band == 20
        assert round(over, 2) == 1.0

    def test_pct_155_hits_band_140(self):
        band, over = band_position(155.0)
        assert band == 140
        assert round(over, 2) == 5.0

    def test_negative_pct_not_hit(self):
        assert band_position(-3.0) is None

    def test_none_not_hit(self):
        assert band_position(None) is None


class TestEligibleSymbol:
    def test_sh_sz_prefixes_ok(self):
        for symbol in ["600519", "000001", "300750", "688981"]:
            assert eligible_symbol(symbol, "正常股")

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


class TestEvaluateStock:
    today = date(2026, 7, 24)

    def test_hit_returns_row(self):
        # 窗口内最低 10.0，价格 13.1 → pct=31% → band=20，over=1
        bars = make_bars(200, 10.0, self.today)
        bars[-3]["low"] = 10.0
        row = evaluate_stock("600001", "测试股", 13.1, bars, today=self.today)
        assert row is not None
        assert row["band"] == 20.0
        assert row["low90"] == 10.0
        assert round(row["pct"], 1) == 31.0

    def test_not_hit_returns_none(self):
        bars = make_bars(200, 10.0, self.today)
        bars[-3]["low"] = 10.0
        # 价格 12.5 → pct=25% → 区间下半段，不命中
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
            {"symbol": "600001", "name": "命中股", "price": 13.1},   # pct=31% 命中
            {"symbol": "600002", "name": "未中股", "price": 12.5},   # pct=25% 不命中
            {"symbol": "430047", "name": "北交所", "price": 13.1},   # 排除
            {"symbol": "600003", "name": "ST某某", "price": 13.1},  # 排除
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
        assert state["total"] == 2  # 北交所与 ST 在候选阶段就被排除
        assert state["done"] == 2
        assert [hit["symbol"] for hit in state["hits"]] == ["600001"]
        assert state["hits"][0]["band"] == 20.0

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
        assert [hit["symbol"] for hit in state["hits"]] == ["600001"]

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
        assert sorted(symbols) == ["300750", "600519"]

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
