from __future__ import annotations

import pandas as pd

from backend.app.errors import ProviderUnavailable
from backend.app.providers.normalizers import (
    normalize_kline_frame,
    normalize_money_flow_frame,
    normalize_quote_frame,
    normalize_symbol_frame,
)
from backend.app.utils import normalize_symbol


class AKShareAdapter:
    source = "akshare"

    def __init__(self):
        try:
            import akshare as ak
        except Exception as exc:
            raise ProviderUnavailable("AKShare is not installed or cannot be imported", self.source) from exc
        self.ak = ak

    def symbols(self) -> pd.DataFrame:
        frame = self.ak.stock_info_a_code_name()
        return normalize_symbol_frame(frame)

    def realtime_quotes(self, symbols: list[str]) -> pd.DataFrame:
        frame = self.ak.stock_zh_a_spot_em()
        normalized = normalize_quote_frame(frame)
        wanted = {normalize_symbol(symbol) for symbol in symbols}
        if wanted:
            normalized = normalized[normalized["symbol"].isin(wanted)]
        return normalized.reset_index(drop=True)

    def kline(self, symbol: str, period: str, start: str | None, end: str | None, adjust: str) -> pd.DataFrame:
        period_map = {
            "day": "daily",
            "1m": "1",
            "5m": "5",
            "15m": "15",
            "30m": "30",
            "60m": "60",
        }
        if period == "day":
            frame = self.ak.stock_zh_a_hist(
                symbol=normalize_symbol(symbol),
                period="daily",
                start_date=(start or "19900101").replace("-", ""),
                end_date=(end or "20500101").replace("-", ""),
                adjust=adjust if adjust != "none" else "",
            )
        else:
            frame = self.ak.stock_zh_a_hist_min_em(
                symbol=normalize_symbol(symbol),
                period=period_map.get(period, "5"),
                adjust=adjust if adjust != "none" else "",
            )
        return normalize_kline_frame(frame)

    def money_flow(self, symbol: str) -> pd.DataFrame:
        func = getattr(self.ak, "stock_individual_fund_flow", None)
        if func is None:
            raise ProviderUnavailable("AKShare money flow API is unavailable", self.source)
        frame = func(stock=normalize_symbol(symbol), market="")
        return normalize_money_flow_frame(frame)

