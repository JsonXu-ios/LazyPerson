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


class AShareOnlyMigrationTests(unittest.TestCase):
    """历史版本种过美股/黄金/加密自选，删代码不会删数据 —— 这里锁住那次数据迁移。
    残留一条 SPY 就会让 TencentAdapter._market_symbol 抛错、整批行情退化成日 K 兜底
    （name/market 变空，界面上标题退回代码），所以必须既清数据、又在入口过滤。"""

    def test_purge_removes_non_a_share_rows(self):
        with tempfile.TemporaryDirectory() as tmp:
            cache = CacheStore(DummySettings(Path(tmp)))
            cache.upsert_symbols(
                [
                    {"symbol": "600519", "market": "SH", "name": "贵州茅台", "pinyin": "", "listed_at": None},
                    {"symbol": "SPY", "market": "US", "name": "标普500 ETF", "pinyin": "", "listed_at": None},
                    {"symbol": "GC=F", "market": "FUT", "name": "COMEX 黄金期货", "pinyin": "", "listed_at": None},
                ]
            )
            cache.add_watchlist("600519", "a_share")
            cache.add_watchlist("SPY", "us")
            cache.add_watchlist("BTC-USD", "crypto")

            removed = cache.purge_non_a_share()

            self.assertEqual(removed, 2)
            self.assertEqual([row["symbol"] for row in cache.list_watchlist()], ["600519"])
            self.assertEqual([row["symbol"] for row in cache.search_symbols("", 20)], ["600519"])

    def test_list_watchlist_runs_migration_once(self):
        with tempfile.TemporaryDirectory() as tmp:
            settings = DummySettings(Path(tmp))
            cache = CacheStore(settings)
            service = MarketService(settings, cache)
            # 模拟旧版本已经种过全球自选（种子标记也已置位）
            cache.add_watchlist("SPY", "us")
            cache.set_state(service.default_watchlist_state_key, "1")

            rows = service.list_watchlist()

            self.assertNotIn("SPY", [row["symbol"] for row in rows])
            self.assertEqual(cache.get_state(service.a_share_only_state_key), "1")

    def test_realtime_quotes_ignores_non_a_share_symbols(self):
        # 不联网：给一个必然失败的假 symbol 列表，只验证过滤发生在请求之前
        with tempfile.TemporaryDirectory() as tmp:
            settings = DummySettings(Path(tmp))
            service = MarketService(settings, CacheStore(settings))

            rows, quality = service.realtime_quotes(["SPY", "GC=F", "BTC-USD"])

            self.assertEqual(rows, [])
            self.assertEqual(quality.source, "unknown")
