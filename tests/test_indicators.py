import unittest

import pandas as pd

from backend.app.indicators import compute_indicators


class IndicatorTests(unittest.TestCase):
    def test_ma_macd_rsi_lon_lengths_match_input(self):
        frame = pd.DataFrame({
            "close": [float(i) for i in range(1, 31)],
            "high": [float(i) + 0.6 for i in range(1, 31)],
            "low": [float(i) - 0.6 for i in range(1, 31)],
            "volume": [1000000.0 + i * 1000 for i in range(1, 31)],
        })
        indicators = compute_indicators(frame, ["ma", "macd", "rsi", "lon"])

        self.assertEqual(len(indicators["ma"]["ma5"]), 30)
        self.assertEqual(len(indicators["macd"]["dif"]), 30)
        self.assertEqual(len(indicators["rsi"]["rsi6"]), 30)
        self.assertEqual(len(indicators["lon"]["lon"]), 30)
        self.assertEqual(len(indicators["lon"]["lonma"]), 30)
        self.assertIsNone(indicators["ma"]["ma5"][3])
        self.assertAlmostEqual(indicators["ma"]["ma5"][4], 3.0)


if __name__ == "__main__":
    unittest.main()
