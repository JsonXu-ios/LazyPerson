import unittest

from backend.app.providers.tencent_adapter import _parse_kline_payload, _parse_minute_payload, _parse_realtime_text


class TencentAdapterTests(unittest.TestCase):
    def test_parse_realtime_quote(self):
        text = (
            'v_sz002138="51~顺络电子~002138~63.44~61.29~59.99~408910~219575~189334~'
            '63.37~4~63.34~142~63.33~44~63.30~3~63.28~5~63.38~1~63.44~19~'
            '63.45~2~63.48~1~63.49~1~~20260617120530~2.15~3.51~64.89~'
            '59.99~63.44/408910/2575616475~408910~257562~5.41";'
        )

        frame = _parse_realtime_text(text)

        self.assertEqual(frame.iloc[0]["symbol"], "002138")
        self.assertEqual(frame.iloc[0]["market"], "SZ")
        self.assertEqual(frame.iloc[0]["trade_time"], "2026-06-17 12:05:30")
        self.assertEqual(frame.iloc[0]["price"], 63.44)
        self.assertEqual(frame.iloc[0]["amount"], 2575616475.0)

    def test_parse_kline_payload(self):
        payload = {
            "code": 0,
            "data": {
                "sz002138": {
                    "qfqday": [
                        ["2026-06-16", "62.00", "61.29", "62.80", "58.80", "652075"],
                        ["2026-06-17", "59.99", "63.44", "64.89", "59.99", "408910"],
                    ]
                }
            },
        }

        frame = _parse_kline_payload(payload, "sz002138", "qfq")

        self.assertEqual(frame.iloc[-1]["time"], "2026-06-17")
        self.assertEqual(frame.iloc[-1]["close"], 63.44)
        self.assertAlmostEqual(frame.iloc[-1]["pct_chg"], 3.508, places=3)

    def test_parse_minute_payload(self):
        payload = {
            "code": 0,
            "data": {
                "sz002138": {
                    "m5": [
                        ["202606171110", "64.10", "63.73", "64.10", "63.70", "5974.00", {}, "7.90"],
                        ["202606171115", "63.73", "63.85", "64.02", "63.73", "5424.00", {}, "7.17"],
                    ],
                    "prec": "61.29",
                }
            },
        }

        frame = _parse_minute_payload(payload, "sz002138", "m5")

        self.assertEqual(frame.iloc[0]["time"], "2026-06-17 11:10:00")
        self.assertEqual(frame.iloc[0]["open"], 64.10)
        self.assertEqual(frame.iloc[-1]["close"], 63.85)
        self.assertAlmostEqual(frame.iloc[0]["pct_chg"], 3.981, places=3)


if __name__ == "__main__":
    unittest.main()
