from __future__ import annotations

from datetime import datetime, timedelta, timezone
from typing import Any
from zoneinfo import ZoneInfo

import pandas as pd
import requests

from backend.app.errors import ProviderError
from backend.app.utils import guess_market, normalize_symbol, safe_float


class YahooFinanceAdapter:
    source = "yahoo"

    chart_url = "https://query1.finance.yahoo.com/v8/finance/chart/{symbol}"
    search_url = "https://query1.finance.yahoo.com/v1/finance/search"

    def search_symbols(self, query: str, limit: int = 20) -> pd.DataFrame:
        try:
            response = requests.get(
                self.search_url,
                params={"q": query, "quotesCount": limit, "newsCount": 0},
                timeout=15,
                headers={"User-Agent": "Mozilla/5.0"},
            )
        except requests.RequestException as exc:
            raise ProviderError(str(exc), self.source) from exc
        if response.status_code != 200:
            raise ProviderError(f"HTTP {response.status_code}", self.source)
        return _parse_search_payload(response.json(), limit)

    def _get_chart(self, symbol: str, params: dict[str, Any]) -> dict:
        try:
            response = requests.get(
                self.chart_url.format(symbol=normalize_symbol(symbol)),
                params=params,
                timeout=15,
                headers={"User-Agent": "Mozilla/5.0"},
            )
        except requests.RequestException as exc:
            raise ProviderError(str(exc), self.source) from exc
        if response.status_code != 200:
            raise ProviderError(f"HTTP {response.status_code}", self.source)
        payload = response.json()
        error = payload.get("chart", {}).get("error")
        if error:
            raise ProviderError(str(error), self.source)
        results = payload.get("chart", {}).get("result") or []
        if not results:
            raise ProviderError("empty chart result", self.source)
        return results[0]

    def realtime_quotes(self, symbols: list[str]) -> pd.DataFrame:
        rows: list[dict] = []
        for symbol in symbols:
            payload = self._get_chart(symbol, {"range": "5d", "interval": "1d"})
            quote = _parse_quote_payload(payload)
            if quote:
                rows.append(quote)
        return pd.DataFrame(rows)

    def kline(self, symbol: str, period: str, start: str | None, end: str | None, _adjust: str) -> pd.DataFrame:
        interval = {
            "day": "1d",
            "1m": "1m",
            "5m": "5m",
            "15m": "15m",
            "30m": "30m",
            "60m": "60m",
        }.get(period)
        if not interval:
            raise ProviderError(f"Unsupported period {period}", self.source)

        params: dict[str, Any] = {"interval": interval}
        if period == "day":
            params.update(_period_params(start, end, default_days=900))
        else:
            params["range"] = "5d" if period == "1m" else "60d"

        payload = self._get_chart(symbol, params)
        return _parse_kline_payload(payload, period)


def _period_params(start: str | None, end: str | None, default_days: int) -> dict[str, int | str]:
    end_dt = _parse_date(end) or datetime.now(timezone.utc)
    start_dt = _parse_date(start) or (end_dt - timedelta(days=default_days))
    return {
        "period1": int(start_dt.timestamp()),
        "period2": int((end_dt + timedelta(days=1)).timestamp()),
        "events": "history",
    }


def _parse_date(value: str | None) -> datetime | None:
    if not value:
        return None
    try:
        return datetime.fromisoformat(value).replace(tzinfo=timezone.utc)
    except ValueError:
        return None


def _exchange_timezone(meta: dict) -> timezone | ZoneInfo:
    name = meta.get("exchangeTimezoneName")
    if not name:
        return timezone.utc
    try:
        return ZoneInfo(name)
    except Exception:
        return timezone.utc


def _format_time(timestamp: int | float | None, meta: dict, period: str) -> str:
    if timestamp is None:
        return ""
    dt = datetime.fromtimestamp(timestamp, tz=_exchange_timezone(meta))
    if period == "day":
        return dt.date().isoformat()
    return dt.strftime("%Y-%m-%d %H:%M:%S")


def _parse_quote_payload(payload: dict) -> dict | None:
    meta = payload.get("meta", {})
    symbol = normalize_symbol(meta.get("symbol", ""))
    price = safe_float(meta.get("regularMarketPrice"))
    pre_close = safe_float(meta.get("previousClose")) or safe_float(meta.get("chartPreviousClose"))
    change = (price - pre_close) if price is not None and pre_close not in (None, 0) else None
    pct_chg = (change / pre_close * 100) if change is not None and pre_close not in (None, 0) else None
    if not symbol or price is None:
        return None
    volume = safe_float(meta.get("regularMarketVolume"))
    return {
        "symbol": symbol,
        "market": guess_market(symbol) or str(meta.get("exchangeName") or ""),
        "name": meta.get("longName") or meta.get("shortName") or symbol,
        "trade_time": _format_time(meta.get("regularMarketTime"), meta, "minute"),
        "price": price,
        "open": safe_float(meta.get("regularMarketOpen")),
        "high": safe_float(meta.get("regularMarketDayHigh")),
        "low": safe_float(meta.get("regularMarketDayLow")),
        "pre_close": pre_close,
        "pct_chg": pct_chg,
        "change": change,
        "volume": volume,
        "amount": (price * volume) if price is not None and volume is not None else None,
        "turnover": None,
    }


def _parse_search_payload(payload: dict, limit: int = 20) -> pd.DataFrame:
    rows: list[dict] = []
    seen: set[str] = set()
    for quote in payload.get("quotes") or []:
        symbol = normalize_symbol(str(quote.get("symbol") or ""))
        market = _search_market(quote, symbol)
        if not symbol or not market or symbol in seen:
            continue
        rows.append(
            {
                "symbol": symbol,
                "market": market,
                "name": quote.get("longname") or quote.get("shortname") or symbol,
                "pinyin": "",
                "listed_at": None,
            }
        )
        seen.add(symbol)
        if len(rows) >= limit:
            break
    return pd.DataFrame(rows)


def _search_market(quote: dict, symbol: str) -> str:
    quote_type = str(quote.get("quoteType") or "").upper()
    exchange = str(quote.get("exchange") or "").upper()
    if quote_type in {"CRYPTOCURRENCY", "CRYPTO"} or symbol.endswith("-USD"):
        return "CRYPTO"
    if quote_type in {"FUTURE"} or symbol.endswith("=F"):
        return "FUT"
    if quote_type in {"CURRENCY"} or symbol.endswith("=X"):
        return "FX"
    if quote_type in {"EQUITY", "ETF"} and exchange in {"NMS", "NYQ", "ASE", "PCX", "BTS", "NGM", "NCM"}:
        return "US"
    return ""


def _parse_kline_payload(payload: dict, period: str) -> pd.DataFrame:
    meta = payload.get("meta", {})
    timestamps = payload.get("timestamp") or []
    quote = (payload.get("indicators", {}).get("quote") or [{}])[0]
    rows: list[dict] = []
    previous_close = safe_float(meta.get("chartPreviousClose"))
    for index, timestamp in enumerate(timestamps):
        close = safe_float(_at(quote, "close", index))
        pct_chg = None
        if close is not None and previous_close not in (None, 0):
            pct_chg = (close - previous_close) / previous_close * 100
        volume = safe_float(_at(quote, "volume", index))
        rows.append(
            {
                "time": _format_time(timestamp, meta, period),
                "open": safe_float(_at(quote, "open", index)),
                "high": safe_float(_at(quote, "high", index)),
                "low": safe_float(_at(quote, "low", index)),
                "close": close,
                "volume": volume,
                "amount": (close * volume) if close is not None and volume is not None else None,
                "pct_chg": pct_chg,
                "turnover": None,
            }
        )
        if close is not None:
            previous_close = close
    result = pd.DataFrame(rows)
    if not result.empty:
        result = result.dropna(subset=["time"]).drop_duplicates(subset=["time"]).sort_values("time")
    return result.reset_index(drop=True)


def _at(values: dict, key: str, index: int):
    series = values.get(key) or []
    if index >= len(series):
        return None
    return series[index]
