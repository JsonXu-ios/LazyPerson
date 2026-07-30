"""东方财富财务数据源：业绩报表、利润表、分红送配、估值快照。

三个公开接口（与 app/lib/data/providers/eastmoney_fundamentals_provider.dart 一一对应）：
- datacenter-web /api/data/v1/get?reportName=RPT_LICO_FN_CPD   业绩报表（EPS/营收/归母净利润/ROE/毛利率/同比）
- datacenter-web /api/data/v1/get?reportName=RPT_DMSK_FN_INCOME 利润表（利润总额/所得税/扣非归母 → 推出净利润）
- datacenter-web /api/data/v1/get?reportName=RPT_SHAREBONUS_DET  分红送配（方案/股息率/除权除息日）
- push2 /api/qt/ulist.np/get                                     估值（PE/PE-TTM/PB/总市值/流通市值）
"""

from __future__ import annotations

from typing import Any

import requests

from backend.app.errors import ProviderError
from backend.app.utils import guess_market, normalize_symbol, safe_float

DATACENTER_URL = "https://datacenter-web.eastmoney.com/api/data/v1/get"

# push2 在部分网络下 TLS 不通，push2delay 提供同一接口（与 Flutter 端主备顺序一致）
QUOTE_HOSTS = ("https://push2.eastmoney.com", "https://push2delay.eastmoney.com")
QUOTE_TIMEOUT = 6

MAX_REPORTS = 8  # 最近 8 期报告（约两年）
MAX_DIVIDENDS = 8


class EastmoneyFundamentalsAdapter:
    source = "eastmoney"

    def __init__(self, timeout: int = 15):
        self.timeout = timeout

    def _get_json(self, url: str, params: dict[str, Any], timeout: int | None = None) -> dict:
        try:
            response = requests.get(
                url,
                params=params,
                timeout=timeout or self.timeout,
                headers={"User-Agent": "Mozilla/5.0", "Referer": "https://data.eastmoney.com/"},
            )
        except requests.RequestException as exc:
            raise ProviderError(f"{type(exc).__name__}", self.source) from exc
        if response.status_code != 200:
            raise ProviderError(f"HTTP {response.status_code}", self.source)
        try:
            return response.json()
        except ValueError as exc:
            raise ProviderError("invalid json", self.source) from exc

    def _report_rows(self, report_name: str, symbol: str, sort_column: str, page_size: int) -> list[dict]:
        payload = self._get_json(
            DATACENTER_URL,
            {
                "reportName": report_name,
                "columns": "ALL",
                "filter": f'(SECURITY_CODE="{symbol}")',
                "pageNumber": 1,
                "pageSize": page_size,
                "sortColumns": sort_column,
                "sortTypes": -1,
                "source": "WEB",
                "client": "WEB",
            },
        )
        result = payload.get("result")
        if not isinstance(result, dict):
            return []
        data = result.get("data")
        return [row for row in data if isinstance(row, dict)] if isinstance(data, list) else []

    def _secid(self, symbol: str) -> str:
        market = guess_market(symbol)
        if market == "SH":
            return f"1.{symbol}"
        if market in ("SZ", "BJ"):
            return f"0.{symbol}"
        raise ProviderError(f"Unsupported market for symbol {symbol}", self.source)

    def valuation(self, symbol: str) -> dict:
        """PE(动)/PE(TTM)/PB/总市值/流通市值。主备域名依次尝试。"""
        params = {
            "secids": self._secid(symbol),
            "fields": "f12,f14,f2,f9,f23,f20,f21,f115",
            "fltt": 2,
            "invt": 2,
        }
        errors: list[str] = []
        for host in QUOTE_HOSTS:
            try:
                # 主域名在部分网络下只会静静超时，用较短超时尽快降级到备用域名
                payload = self._get_json(f"{host}/api/qt/ulist.np/get", params, timeout=QUOTE_TIMEOUT)
            except ProviderError as exc:
                errors.append(f"{host}:{exc}")
                continue
            data = payload.get("data")
            rows = data.get("diff") if isinstance(data, dict) else None
            if isinstance(rows, dict):
                rows = list(rows.values())
            if not isinstance(rows, list) or not rows:
                errors.append(f"{host}:empty")
                continue
            row = rows[0]
            return {
                "price": safe_float(row.get("f2")),
                "pe": safe_float(row.get("f9")),
                "pe_ttm": safe_float(row.get("f115")),
                "pb": safe_float(row.get("f23")),
                "market_cap": safe_float(row.get("f20")),
                "float_market_cap": safe_float(row.get("f21")),
            }
        raise ProviderError("; ".join(errors) or "no valuation data", self.source)

    def fundamentals(self, symbol: str) -> dict:
        """业绩 + 分红 + 估值的合并结果。估值失败不影响财务部分。"""
        clean = normalize_symbol(symbol)
        performance = self._report_rows("RPT_LICO_FN_CPD", clean, "REPORTDATE", MAX_REPORTS)
        income = self._report_rows("RPT_DMSK_FN_INCOME", clean, "REPORT_DATE", MAX_REPORTS)
        bonus = self._report_rows("RPT_SHAREBONUS_DET", clean, "PLAN_NOTICE_DATE", MAX_DIVIDENDS)
        if not performance and not bonus:
            raise ProviderError("no fundamentals data", self.source)

        warnings: list[str] = []
        try:
            valuation = self.valuation(clean)
        except ProviderError as exc:
            valuation = {}
            warnings.append(f"valuation:{exc}")

        income_by_date = {_date_only(row.get("REPORT_DATE")): row for row in income}
        name = ""
        for row in performance + bonus:
            name = str(row.get("SECURITY_NAME_ABBR") or "").strip() or name
            if name:
                break

        return {
            "symbol": clean,
            "name": name,
            "valuation": valuation,
            "reports": [_normalize_report(row, income_by_date) for row in performance],
            "dividends": [_normalize_dividend(row) for row in bonus],
            "warnings": warnings,
        }


def _date_only(value: Any) -> str:
    return str(value or "")[:10]


def _normalize_report(row: dict, income_by_date: dict[str, dict]) -> dict:
    report_date = _date_only(row.get("REPORTDATE"))
    income = income_by_date.get(report_date, {})
    total_profit = safe_float(income.get("TOTAL_PROFIT"))
    income_tax = safe_float(income.get("INCOME_TAX"))
    # 业绩报表只给归母净利润；净利润（含少数股东）用利润表的 利润总额-所得税 推出
    netprofit = total_profit - income_tax if total_profit is not None and income_tax is not None else None
    return {
        "report_date": report_date,
        "report_type": str(row.get("DATATYPE") or "").strip(),  # 例："2025年 年报"
        "notice_date": _date_only(row.get("NOTICE_DATE")),
        "eps": safe_float(row.get("BASIC_EPS")),
        "deduct_eps": safe_float(row.get("DEDUCT_BASIC_EPS")),
        "bps": safe_float(row.get("BPS")),
        "revenue": safe_float(row.get("TOTAL_OPERATE_INCOME")),
        "revenue_yoy": safe_float(row.get("YSTZ")),
        "parent_netprofit": safe_float(row.get("PARENT_NETPROFIT")),
        "parent_netprofit_yoy": safe_float(row.get("SJLTZ")),
        "deduct_parent_netprofit": safe_float(income.get("DEDUCT_PARENT_NETPROFIT")),
        "netprofit": netprofit,
        "total_profit": total_profit,
        "income_tax": income_tax,
        "roe": safe_float(row.get("WEIGHTAVG_ROE")),
        "gross_margin": safe_float(row.get("XSMLL")),
        "operating_cashflow_ps": safe_float(row.get("MGJYXJJE")),
    }


def _normalize_dividend(row: dict) -> dict:
    return {
        "report_date": _date_only(row.get("REPORT_DATE")),
        "plan": str(row.get("IMPL_PLAN_PROFILE") or "").strip(),
        "progress": str(row.get("ASSIGN_PROGRESS") or "").strip(),
        "pretax_bonus": safe_float(row.get("PRETAX_BONUS_RMB")),  # 每 10 股税前派息（元）
        "bonus_ratio": safe_float(row.get("BONUS_RATIO")),  # 每 10 股送股
        "it_ratio": safe_float(row.get("IT_RATIO")),  # 每 10 股转增
        "dividend_ratio": safe_float(row.get("DIVIDENT_RATIO")),  # 股息率（小数）
        "plan_notice_date": _date_only(row.get("PLAN_NOTICE_DATE")),
        "equity_record_date": _date_only(row.get("EQUITY_RECORD_DATE")),
        "ex_dividend_date": _date_only(row.get("EX_DIVIDEND_DATE")),
    }
