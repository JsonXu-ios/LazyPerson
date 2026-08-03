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
STATE_PREFIX = "fundamentals:v2:"  # v2: 估市值/净利润拆分为独立条件，按最新报告期年化


def annualize_factor(stat_date: str | None) -> float | None:
    """按报告期年化系数：一季报×4、半年报×2、三季报×4/3、年报×1（财报数据为年内累计值）。"""
    if not stat_date:
        return None
    try:
        month = int(str(stat_date)[5:7])
    except ValueError:
        return None
    return {3: 4.0, 6: 2.0, 9: 4.0 / 3.0, 12: 1.0}.get(month)


def revenue_condition(
    net_profit: float | None,
    np_margin: float | None,
    stat_date: str | None,
    market_cap_yi: float | None,
) -> bool:
    """估市值：最新报告期累计营收年化后 ×10 > 总市值。
    营收 = 累计归母净利润 / 净利率（baostock 营收字段常缺失）。数据缺失视为不通过。"""
    factor = annualize_factor(stat_date)
    if factor is None:
        return False
    if net_profit is None or np_margin is None or np_margin <= 0:
        return False
    if market_cap_yi is None or market_cap_yi <= 0:
        return False
    revenue = net_profit / np_margin * factor
    return revenue * 10 > market_cap_yi * 1e8


def profit_condition(net_profit: float | None) -> bool:
    """净利润：最新报告期归母净利润≥0（净利润与归母同口径判定）。缺失视为不通过。"""
    return net_profit is not None and net_profit >= 0


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
                hit["dividend_recent"] = cached.get("dividend_recent", False)
                hit["profit_ok"] = cached.get("profit_ok", False)
                hit["revenue_ok"] = cached.get("revenue_ok", False)
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
                profit, revenue = self._fetch_report_flags(bs, code, market_caps.get(symbol))
                hit["dividend_recent"] = dividend
                hit["profit_ok"] = profit
                hit["revenue_ok"] = revenue
                self._write_cache(symbol, dividend, profit, revenue)
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

    def _fetch_report_flags(self, bs, code: str, market_cap_yi: float | None) -> tuple[bool, bool]:
        """最新已披露报告期的（净利润, 估市值）判定；无财报数据均视为不通过。"""
        row = self._latest_report(bs, code)
        if row is None:
            return False, False
        net_profit = _to_float(row.get("netProfit"))
        return (
            profit_condition(net_profit),
            revenue_condition(net_profit, _to_float(row.get("npMargin")), row.get("statDate"), market_cap_yi),
        )

    def _latest_report(self, bs, code: str) -> dict | None:
        """从最近已结束的报告期往回找（最多4期），取第一个有数据的。"""
        candidates: list[tuple[int, int]] = []
        for year in (self.today.year, self.today.year - 1):
            for quarter in (4, 3, 2, 1):
                quarter_end = date(year, quarter * 3, 1) + timedelta(days=31)
                if quarter_end > self.today:
                    continue  # 报告期还没结束
                candidates.append((year, quarter))
        for year, quarter in candidates[:4]:
            rows = _rows(bs.query_profit_data(code=code, year=year, quarter=quarter))
            if rows:
                return rows[0]
        return None

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

    def _write_cache(self, symbol: str, dividend: bool, profit: bool, revenue: bool) -> None:
        self.cache.set_state(
            f"{STATE_PREFIX}{symbol}",
            json.dumps({
                "checked_at": self.today.isoformat(),
                "dividend_recent": dividend,
                "profit_ok": profit,
                "revenue_ok": revenue,
            }),
        )
