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

    def test_default_watchlist_is_a_share_only(self):
        with tempfile.TemporaryDirectory() as tmp:
            cache = CacheStore(DummySettings(Path(tmp)))
            service = MarketService(DummySettings(Path(tmp)), cache)

            rows = service.list_watchlist()

            self.assertIn("002138", [row["symbol"] for row in rows])
            # 只做 A 股：种子全部落在 a_share 分组，没有美股/黄金/加密
            self.assertEqual({row["group_name"] for row in rows}, {"a_share"})
            self.assertTrue(all(row["symbol"].isdigit() for row in rows))


if __name__ == "__main__":
    unittest.main()
