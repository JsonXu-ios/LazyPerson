import unittest

from backend.app.providers.yahoo_adapter import _parse_kline_payload, _parse_quote_payload, _parse_search_payload
from backend.app.utils import guess_market, is_a_share_symbol, normalize_symbol


class YahooAdapterTests(unittest.TestCase):
    def test_parse_quote_payload(self):
        payload = {
            "meta": {
                "symbol": "BTC-USD",
                "exchangeTimezoneName": "UTC",
                "regularMarketTime": 1782086400,
                "regularMarketPrice": 65000.0,
                "chartPreviousClose": 62500.0,
                "regularMarketDayHigh": 66000.0,
                "regularMarketDayLow": 62000.0,
                "regularMarketVolume": 10,
                "longName": "Bitcoin USD",
            }
        }

        quote = _parse_quote_payload(payload)

        self.assertEqual(quote["symbol"], "BTC-USD")
        self.assertEqual(quote["market"], "CRYPTO")
        self.assertEqual(quote["price"], 65000.0)
        self.assertEqual(quote["change"], 2500.0)
        self.assertEqual(quote["amount"], 650000.0)

    def test_parse_kline_payload(self):
        payload = {
            "meta": {"exchangeTimezoneName": "UTC", "chartPreviousClose": 100.0},
            "timestamp": [1782000000, 1782086400],
            "indicators": {
                "quote": [
                    {
                        "open": [101.0, 103.0],
                        "high": [105.0, 106.0],
                        "low": [99.0, 102.0],
                        "close": [104.0, 105.0],
                        "volume": [1000, 1100],
                    }
                ]
            },
        }

        frame = _parse_kline_payload(payload, "day")

        self.assertEqual(frame.iloc[-1]["time"], "2026-06-22")
        self.assertEqual(frame.iloc[-1]["close"], 105.0)
        self.assertAlmostEqual(frame.iloc[0]["pct_chg"], 4.0)

    def test_symbol_market_helpers(self):
        self.assertEqual(normalize_symbol("aapl.us"), "AAPL")
        self.assertEqual(guess_market("GC=F"), "FUT")
        self.assertFalse(is_a_share_symbol("BTC-USD"))
        self.assertTrue(is_a_share_symbol("600519"))

    def test_parse_search_payload(self):
        payload = {
            "quotes": [
                {
                    "exchange": "NMS",
                    "quoteType": "EQUITY",
                    "symbol": "META",
                    "longname": "Meta Platforms, Inc.",
                },
                {
                    "exchange": "NYQ",
                    "quoteType": "ETF",
                    "symbol": "SPY",
                    "shortname": "SPDR S&P 500 ETF Trust",
                },
                {
                    "exchange": "SHH",
                    "quoteType": "EQUITY",
                    "symbol": "600519.SS",
                    "longname": "Kweichow Moutai Co., Ltd.",
                },
            ]
        }

        frame = _parse_search_payload(payload)

        self.assertEqual(frame.iloc[0]["symbol"], "META")
        self.assertEqual(frame.iloc[0]["market"], "US")
        self.assertEqual(frame.iloc[0]["name"], "Meta Platforms, Inc.")
        self.assertEqual(frame.iloc[1]["symbol"], "SPY")
        self.assertEqual(len(frame), 2)


if __name__ == "__main__":
    unittest.main()
