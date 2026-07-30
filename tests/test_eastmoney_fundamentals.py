import unittest

from backend.app.errors import ProviderError
from backend.app.providers.eastmoney_adapter import (
    EastmoneyFundamentalsAdapter,
    _normalize_dividend,
    _normalize_report,
)

# 取自 datacenter-web RPT_LICO_FN_CPD?filter=(SECURITY_CODE="600519") 的真实一行
PERFORMANCE_ROW = {
    "SECURITY_CODE": "600519",
    "SECURITY_NAME_ABBR": "贵州茅台",
    "REPORTDATE": "2025-12-31 00:00:00",
    "NOTICE_DATE": "2026-04-17 00:00:00",
    "DATATYPE": "2025年 年报",
    "BASIC_EPS": 65.66,
    "DEDUCT_BASIC_EPS": 65.64,
    "BPS": 195.355449727901,
    "TOTAL_OPERATE_INCOME": 172054171890.91,
    "YSTZ": -1.2000971769,
    "PARENT_NETPROFIT": 82320067101.68,
    "SJLTZ": -4.53,
    "WEIGHTAVG_ROE": 32.53,
    "XSMLL": 91.1795516835,
    "MGJYXJJE": 49.128538116153,
}

# 取自 RPT_DMSK_FN_INCOME 同一报告期
INCOME_ROW = {
    "REPORT_DATE": "2025-12-31 00:00:00",
    "TOTAL_PROFIT": 114755261605.08,
    "INCOME_TAX": 29444936771.41,
    "DEDUCT_PARENT_NETPROFIT": 82293107655.25,
}

# 取自 RPT_SHAREBONUS_DET
BONUS_ROW = {
    "REPORT_DATE": "2025-12-31 00:00:00",
    "IMPL_PLAN_PROFILE": "10派280.2423元(含税)",
    "ASSIGN_PROGRESS": "实施分配",
    "PRETAX_BONUS_RMB": 280.2423,
    "BONUS_RATIO": None,
    "IT_RATIO": None,
    "DIVIDENT_RATIO": 0.023120394357,
    "PLAN_NOTICE_DATE": "2026-04-17 00:00:00",
    "EQUITY_RECORD_DATE": "2026-06-25 00:00:00",
    "EX_DIVIDEND_DATE": "2026-06-26 00:00:00",
}


class NormalizeReportTests(unittest.TestCase):
    def test_maps_performance_fields(self):
        row = _normalize_report(PERFORMANCE_ROW, {})

        self.assertEqual(row["report_date"], "2025-12-31")
        self.assertEqual(row["report_type"], "2025年 年报")
        self.assertEqual(row["notice_date"], "2026-04-17")
        self.assertEqual(row["eps"], 65.66)
        self.assertEqual(row["revenue"], 172054171890.91)
        self.assertEqual(row["parent_netprofit"], 82320067101.68)
        self.assertEqual(row["parent_netprofit_yoy"], -4.53)
        self.assertEqual(row["roe"], 32.53)

    def test_netprofit_derived_from_income_statement(self):
        # 业绩报表没有「净利润（含少数股东）」，用 利润总额 - 所得税 推出
        row = _normalize_report(PERFORMANCE_ROW, {"2025-12-31": INCOME_ROW})

        self.assertAlmostEqual(row["netprofit"], 85310324833.67, places=2)
        self.assertEqual(row["deduct_parent_netprofit"], 82293107655.25)
        self.assertEqual(row["total_profit"], 114755261605.08)

    def test_netprofit_none_without_matching_income_row(self):
        # 利润表缺该报告期（报告期错位）时不硬凑，留 None
        row = _normalize_report(PERFORMANCE_ROW, {"2024-12-31": INCOME_ROW})

        self.assertIsNone(row["netprofit"])
        self.assertIsNone(row["deduct_parent_netprofit"])


class NormalizeDividendTests(unittest.TestCase):
    def test_maps_dividend_fields(self):
        row = _normalize_dividend(BONUS_ROW)

        self.assertEqual(row["report_date"], "2025-12-31")
        self.assertEqual(row["plan"], "10派280.2423元(含税)")
        self.assertEqual(row["progress"], "实施分配")
        self.assertEqual(row["pretax_bonus"], 280.2423)
        self.assertEqual(row["ex_dividend_date"], "2026-06-26")

    def test_missing_dates_become_empty_string(self):
        row = _normalize_dividend({"REPORT_DATE": None, "EX_DIVIDEND_DATE": None})

        self.assertEqual(row["report_date"], "")
        self.assertEqual(row["ex_dividend_date"], "")
        self.assertIsNone(row["dividend_ratio"])


class FundamentalsAssemblyTests(unittest.TestCase):
    def _adapter(self, performance, income, bonus, valuation_ok=True):
        adapter = EastmoneyFundamentalsAdapter()
        rows = {
            "RPT_LICO_FN_CPD": performance,
            "RPT_DMSK_FN_INCOME": income,
            "RPT_SHAREBONUS_DET": bonus,
        }
        adapter._report_rows = lambda name, *_args, **_kwargs: rows[name]
        if valuation_ok:
            adapter.valuation = lambda _symbol: {"pe": 15.62, "pb": 7.22}
        else:
            def broken(_symbol):
                raise ProviderError("push2 down", "eastmoney")

            adapter.valuation = broken
        return adapter

    def test_merges_performance_income_and_bonus(self):
        adapter = self._adapter([PERFORMANCE_ROW], [INCOME_ROW], [BONUS_ROW])

        data = adapter.fundamentals("600519")

        self.assertEqual(data["symbol"], "600519")
        self.assertEqual(data["name"], "贵州茅台")
        self.assertEqual(data["valuation"]["pe"], 15.62)
        self.assertEqual(len(data["reports"]), 1)
        self.assertAlmostEqual(data["reports"][0]["netprofit"], 85310324833.67, places=2)
        self.assertEqual(len(data["dividends"]), 1)
        self.assertEqual(data["warnings"], [])

    def test_valuation_failure_is_a_warning_not_an_error(self):
        adapter = self._adapter([PERFORMANCE_ROW], [INCOME_ROW], [BONUS_ROW], valuation_ok=False)

        data = adapter.fundamentals("600519")

        self.assertEqual(data["valuation"], {})
        self.assertEqual(len(data["reports"]), 1)  # 财务部分不受影响
        self.assertTrue(data["warnings"][0].startswith("valuation:"))

    def test_raises_when_no_financial_data(self):
        adapter = self._adapter([], [], [])

        with self.assertRaises(ProviderError):
            adapter.fundamentals("600519")


if __name__ == "__main__":
    unittest.main()
