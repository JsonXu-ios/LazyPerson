import tempfile
import unittest
from pathlib import Path

import pandas as pd

from backend.app.cache import CacheStore
from backend.app.services import MarketService


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


class CacheTests(unittest.TestCase):
    def test_watchlist_and_frame_round_trip(self):
        with tempfile.TemporaryDirectory() as tmp:
            cache = CacheStore(DummySettings(Path(tmp)))
            cache.upsert_symbols([
                {"symbol": "600519", "market": "SH", "name": "贵州茅台", "pinyin": "", "listed_at": None}
            ])
            cache.add_watchlist("600519")
            self.assertEqual(cache.list_watchlist()[0]["symbol"], "600519")

            frame = pd.DataFrame([{"time": "2026-06-10", "close": 100.0}])
            cache.write_frame(
                cache_key="kline_day:600519",
                data_type="kline_day",
                frame=frame,
                source="test",
                symbol="600519",
                ttl_seconds=60,
            )
            cached = cache.read_frame("kline_day:600519")
            self.assertIsNotNone(cached)
            cached_frame, meta = cached
            self.assertEqual(cached_frame.iloc[0]["close"], 100.0)
            self.assertFalse(meta["stale"])

    def test_kline_cache_keys_use_distinct_files(self):
        with tempfile.TemporaryDirectory() as tmp:
            cache = CacheStore(DummySettings(Path(tmp)))
            first = pd.DataFrame([{"time": "2026-06-10", "close": 100.0}])
            second = pd.DataFrame([{"time": "2026-05-10", "close": 200.0}])

            cache.write_frame(
                cache_key="kline_day:600519:day:none::",
                data_type="kline_day",
                frame=first,
                source="test",
                symbol="600519",
                period="day",
                ttl_seconds=60,
            )
            cache.write_frame(
                cache_key="kline_day:600519:day:none:20260501:20260531",
                data_type="kline_day",
                frame=second,
                source="test",
                symbol="600519",
                period="day",
                ttl_seconds=60,
            )

            cached_first = cache.read_frame("kline_day:600519:day:none::")
            cached_second = cache.read_frame("kline_day:600519:day:none:20260501:20260531")
            self.assertIsNotNone(cached_first)
            self.assertIsNotNone(cached_second)
            self.assertEqual(cached_first[0].iloc[0]["close"], 100.0)
            self.assertEqual(cached_second[0].iloc[0]["close"], 200.0)
            self.assertNotEqual(cached_first[1]["path"], cached_second[1]["path"])

    def test_default_watchlist_adds_global_assets(self):
        with tempfile.TemporaryDirectory() as tmp:
            cache = CacheStore(DummySettings(Path(tmp)))
            service = MarketService(DummySettings(Path(tmp)), cache)

            rows = service.list_watchlist()
            symbols = [row["symbol"] for row in rows]

            self.assertIn("002138", symbols)
            self.assertIn("SPY", symbols)
            self.assertIn("GC=F", symbols)
            self.assertIn("BTC-USD", symbols)

    def test_builtin_global_assets_are_searchable(self):
        with tempfile.TemporaryDirectory() as tmp:
            cache = CacheStore(DummySettings(Path(tmp)))
            service = MarketService(DummySettings(Path(tmp)), cache)

            gold_rows, _ = service.search_symbols("黄金")
            bitcoin_rows, _ = service.search_symbols("比特币")
            us_rows, _ = service.search_symbols("美股")

            self.assertIn("GC=F", [row["symbol"] for row in gold_rows])
            self.assertIn("BTC-USD", [row["symbol"] for row in bitcoin_rows])
            self.assertIn("SPY", [row["symbol"] for row in us_rows])


if __name__ == "__main__":
    unittest.main()
