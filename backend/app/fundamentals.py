"""八档局基本面标记：分红（近一年，含已公告的今年分红）与净利润
（归母净利润≥0 且 一季度营收×4×10 > 总市值）。

只对命中的股票取数（约一两百只），baostock 数据源，结果按股票缓存 3 天。
营收用 归母净利润/净利率 反推（baostock 一季报 MBRevenue 字段常缺失）。
"""

from __future__ import annotations

import json
from datetime import date, timedelta

from backend.app.cache import CacheStore
from backend.app.utils import now_utc

FUND_CACHE_DAYS = 3
STATE_PREFIX = "fundamentals:v1:"


def profit_condition(net_profit: float | None, np_margin: float | None, market_cap_yi: float | None) -> bool:
    """净利润筛选：归母净利润≥0（baostock netProfit 即归母口径，同时覆盖净利润≥0）
    且 一季度营收×4×10 > 总市值。营收 = 归母净利润 / 净利率。数据缺失视为不通过。"""
    if net_profit is None or net_profit < 0:
        return False
    if np_margin is None or np_margin <= 0:
        return False
    if market_cap_yi is None or market_cap_yi <= 0:
        return False
    revenue = net_profit / np_margin
    return revenue * 4 * 10 > market_cap_yi * 1e8


def dividend_condition(operate_dates: list[str], today: date) -> bool:
    """近一年有分红：除权除息日在（今日−365天）之后即算，已公告未除息的今年分红也算。"""
    cutoff = today - timedelta(days=365)
    for raw in operate_dates:
        try:
            day = date.fromisoformat(str(raw)[:10])
        except ValueError:
            continue
        if day >= cutoff:
            return True
    return False


def _bs_code(symbol: str) -> str:
    return f"sh.{symbol}" if symbol.startswith("6") else f"sz.{symbol}"


def _rows(rs) -> list[dict]:
    rows: list[dict] = []
    while rs.error_code == "0" and rs.next():
        rows.append(dict(zip(rs.fields, rs.get_row_data())))
    return rows


def _to_float(value) -> float | None:
    try:
        return float(value)
    except (TypeError, ValueError):
        return None


class FundamentalsFetcher:
    """按命中股票补 dividend_recent / profit_ok 标记，带 sqlite 状态缓存。"""

    def __init__(self, cache: CacheStore, today: date | None = None):
        self.cache = cache
        self.today = today or now_utc().date()

    def enrich(self, hits: list[dict], market_caps: dict[str, float | None]) -> None:
        pending = []
        for hit in hits:
            cached = self._read_cache(hit["symbol"])
            if cached is not None:
                hit["dividend_recent"] = cached["dividend_recent"]
                hit["profit_ok"] = cached["profit_ok"]
            else:
                pending.append(hit)
        if not pending:
            return

        import baostock as bs

        login = bs.login()
        if login.error_code != "0":
            raise RuntimeError(f"baostock login failed: {login.error_msg}")
        try:
            for hit in pending:
                symbol = hit["symbol"]
                code = _bs_code(symbol)
                dividend = self._fetch_dividend(bs, code)
                profit = self._fetch_profit(bs, code, market_caps.get(symbol))
                hit["dividend_recent"] = dividend
                hit["profit_ok"] = profit
                self._write_cache(symbol, dividend, profit)
        finally:
            bs.logout()

    def _fetch_dividend(self, bs, code: str) -> bool:
        dates: list[str] = []
        for year in (self.today.year, self.today.year - 1):
            rows = _rows(bs.query_dividend_data(code=code, year=str(year), yearType="operate"))
            for row in rows:
                cash = _to_float(row.get("dividCashPsBeforeTax"))
                if cash is not None and cash > 0:
                    dates.append(row.get("dividOperateDate") or row.get("dividPlanAnnounceDate") or "")
        return dividend_condition(dates, self.today)

    def _fetch_profit(self, bs, code: str, market_cap_yi: float | None) -> bool:
        rows = _rows(bs.query_profit_data(code=code, year=self.today.year, quarter=1))
        if not rows:
            return False  # 一季报未披露/缺失视为不通过
        row = rows[0]
        return profit_condition(
            _to_float(row.get("netProfit")),
            _to_float(row.get("npMargin")),
            market_cap_yi,
        )

    def _read_cache(self, symbol: str) -> dict | None:
        raw = self.cache.get_state(f"{STATE_PREFIX}{symbol}")
        if not raw:
            return None
        try:
            data = json.loads(raw)
            checked = date.fromisoformat(data["checked_at"])
        except (ValueError, KeyError):
            return None
        if (self.today - checked).days > FUND_CACHE_DAYS:
            return None
        return data

    def _write_cache(self, symbol: str, dividend: bool, profit: bool) -> None:
        self.cache.set_state(
            f"{STATE_PREFIX}{symbol}",
            json.dumps({
                "checked_at": self.today.isoformat(),
                "dividend_recent": dividend,
                "profit_ok": profit,
            }),
        )
