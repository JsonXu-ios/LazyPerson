from __future__ import annotations

from datetime import datetime
from math import ceil
from typing import Any

import pandas as pd
import requests

from backend.app.errors import ProviderError
from backend.app.utils import guess_market, normalize_symbol, safe_float


class TencentAdapter:
    source = "tencent"

    quote_url = "https://qt.gtimg.cn/q={symbols}"
    fq_kline_url = "https://ifzq.gtimg.cn/appstock/app/fqkline/get"
    minute_kline_url = "https://ifzq.gtimg.cn/appstock/app/kline/mkline"

    def _market_symbol(self, symbol: str) -> str:
        clean = normalize_symbol(symbol)
        market = guess_market(clean)
        if market == "SH":
            return f"sh{clean}"
        if market == "SZ":
            return f"sz{clean}"
        if market == "BJ":
            return f"bj{clean}"
        raise ProviderError(f"Unsupported market for symbol {symbol}", self.source)

    def _get(self, url: str, **kwargs: Any) -> requests.Response:
        response = requests.get(
            url,
            timeout=15,
            headers={
                "User-Agent": "Mozilla/5.0",
                "Referer": "https://gu.qq.com/",
            },
            **kwargs,
        )
        if response.status_code != 200:
            raise ProviderError(f"HTTP {response.status_code}", self.source)
        return response

    def realtime_quotes(self, symbols: list[str]) -> pd.DataFrame:
        market_symbols = [self._market_symbol(symbol) for symbol in symbols]
        if not market_symbols:
            return pd.DataFrame()
        response = self._get(self.quote_url.format(symbols=",".join(market_symbols)))
        return _parse_realtime_text(response.text)

    def kline(self, symbol: str, period: str, start: str | None, end: str | None, adjust: str) -> pd.DataFrame:
        clean = self._market_symbol(symbol)
        if period != "day":
            period_key = _minute_period_key(period)
            response = self._get(
                self.minute_kline_url,
                params={"param": f"{clean},{period_key},,{_minute_count(period)}"},
            )
            payload = response.json()
            if payload.get("code") != 0:
                raise ProviderError(str(payload.get("msg") or payload), self.source)
            return _parse_minute_payload(payload, clean, period_key)

        start_date = start or ""
        end_date = end or ""
        count = _estimate_count(start, end)
        adjust_key = {"none": "", "qfq": "qfq", "hfq": "hfq"}.get(adjust, "qfq")
        response = self._get(
            self.fq_kline_url,
            params={"param": f"{clean},day,{start_date},{end_date},{count},{adjust_key}"},
        )
        payload = response.json()
        if payload.get("code") != 0:
            raise ProviderError(str(payload.get("msg") or payload), self.source)
        return _parse_kline_payload(payload, clean, adjust_key)


def _format_trade_time(value: str) -> str:
    try:
        return datetime.strptime(value, "%Y%m%d%H%M%S").strftime("%Y-%m-%d %H:%M:%S")
    except ValueError:
        return value


def _slash_value(value: str, index: int) -> float | None:
    parts = str(value or "").split("/")
    if len(parts) <= index:
        return None
    return safe_float(parts[index])


def _parse_realtime_text(text: str) -> pd.DataFrame:
    rows: list[dict] = []
    for chunk in text.splitlines():
        if '="' not in chunk:
            continue
        raw_symbol, raw_payload = chunk.split("=", 1)
        payload = raw_payload.strip().strip('";')
        fields = payload.split("~")
        if len(fields) < 39 or not fields[2]:
            continue
        prefixed = raw_symbol.replace("v_", "")
        symbol = normalize_symbol(fields[2])
        rows.append(
            {
                "symbol": symbol,
                "market": guess_market(symbol),
                "name": fields[1],
                "trade_time": _format_trade_time(fields[30]),
                "price": safe_float(fields[3]),
                "open": safe_float(fields[5]),
                "high": safe_float(fields[33]),
                "low": safe_float(fields[34]),
                "pre_close": safe_float(fields[4]),
                "pct_chg": safe_float(fields[32]),
                "change": safe_float(fields[31]),
                "volume": safe_float(fields[36]),
                "amount": _slash_value(fields[35], 2) or safe_float(fields[37]),
                "turnover": safe_float(fields[38]),
                "market_cap": safe_float(fields[45]) if len(fields) > 45 else None,  # 总市值，亿元
            }
        )
        if prefixed.startswith("bj"):
            rows[-1]["market"] = "BJ"
    return pd.DataFrame(rows)


def _estimate_count(start: str | None, end: str | None) -> int:
    if not start:
        return 640
    try:
        start_date = datetime.fromisoformat(start).date()
        end_date = datetime.fromisoformat(end).date() if end else datetime.now().date()
    except ValueError:
        return 640
    days = max((end_date - start_date).days, 1)
    return min(max(ceil(days * 1.6), 120), 5000)


def _minute_period_key(period: str) -> str:
    period_map = {
        "1m": "m1",
        "5m": "m5",
        "15m": "m15",
        "30m": "m30",
        "60m": "m60",
    }
    if period not in period_map:
        raise ProviderError(f"Unsupported period {period}", TencentAdapter.source)
    return period_map[period]


def _minute_count(period: str) -> int:
    if period == "1m":
        return 1000
    if period == "5m":
        return 600
    return 320


def _format_minute_time(value: str) -> str:
    try:
        return datetime.strptime(value, "%Y%m%d%H%M").strftime("%Y-%m-%d %H:%M:%S")
    except ValueError:
        return value


def _parse_kline_payload(payload: dict, market_symbol: str, adjust_key: str) -> pd.DataFrame:
    data = payload.get("data", {}).get(market_symbol, {})
    key = f"{adjust_key}day" if adjust_key else "day"
    rows = data.get(key) or data.get("qfqday") or data.get("day") or []
    normalized: list[dict] = []
    previous_close: float | None = None
    for row in rows:
        if len(row) < 6:
            continue
        close = safe_float(row[2])
        pct_chg = None
        if close is not None and previous_close not in (None, 0):
            pct_chg = (close - previous_close) / previous_close * 100
        normalized.append(
            {
                "time": str(row[0]),
                "open": safe_float(row[1]),
                "high": safe_float(row[3]),
                "low": safe_float(row[4]),
                "close": close,
                "volume": safe_float(row[5]),
                "amount": None,
                "pct_chg": pct_chg,
                "turnover": None,
            }
        )
        if close is not None:
            previous_close = close
    result = pd.DataFrame(normalized)
    if not result.empty:
        result = result.dropna(subset=["time"]).drop_duplicates(subset=["time"]).sort_values("time")
    return result


def _parse_minute_payload(payload: dict, market_symbol: str, period_key: str) -> pd.DataFrame:
    data = payload.get("data", {}).get(market_symbol, {})
    rows = data.get(period_key) or []
    normalized: list[dict] = []
    previous_close = safe_float(data.get("prec"))
    for row in rows:
        if len(row) < 6:
            continue
        close = safe_float(row[2])
        pct_chg = None
        if close is not None and previous_close not in (None, 0):
            pct_chg = (close - previous_close) / previous_close * 100
        normalized.append(
            {
                "time": _format_minute_time(str(row[0])),
                "open": safe_float(row[1]),
                "high": safe_float(row[3]),
                "low": safe_float(row[4]),
                "close": close,
                "volume": safe_float(row[5]),
                "amount": None,
                "pct_chg": pct_chg,
                "turnover": None,
            }
        )
        if close is not None:
            previous_close = close
    result = pd.DataFrame(normalized)
    if not result.empty:
        result = result.dropna(subset=["time"]).drop_duplicates(subset=["time"]).sort_values("time")
    return result
