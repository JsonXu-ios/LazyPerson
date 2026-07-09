from __future__ import annotations

import pandas as pd

from backend.app.errors import ProviderUnavailable
from backend.app.providers.normalizers import (
    normalize_kline_frame,
    normalize_money_flow_frame,
    normalize_quote_frame,
)
from backend.app.utils import normalize_symbol


class EFinanceAdapter:
    source = "efinance"

    def __init__(self):
        try:
            import efinance as ef
        except Exception as exc:
            raise ProviderUnavailable("efinance is not installed or cannot be imported", self.source) from exc
        self.ef = ef

    def realtime_quotes(self, symbols: list[str]) -> pd.DataFrame:
        frame = self.ef.stock.get_realtime_quotes()
        normalized = normalize_quote_frame(frame)
        wanted = {normalize_symbol(symbol) for symbol in symbols}
        if wanted:
            normalized = normalized[normalized["symbol"].isin(wanted)]
        return normalized.reset_index(drop=True)

    def kline(self, symbol: str, period: str, start: str | None, end: str | None, adjust: str) -> pd.DataFrame:
        klt_map = {
            "1m": 1,
            "5m": 5,
            "15m": 15,
            "30m": 30,
            "60m": 60,
            "day": 101,
        }
        fqt_map = {"none": 0, "qfq": 1, "hfq": 2}
        frame = self.ef.stock.get_quote_history(
            stock_codes=normalize_symbol(symbol),
            beg=(start or "19900101").replace("-", ""),
            end=(end or "20500101").replace("-", ""),
            klt=klt_map.get(period, 101),
            fqt=fqt_map.get(adjust, 1),
        )
        return normalize_kline_frame(frame)

    def money_flow(self, symbol: str) -> pd.DataFrame:
        stock = getattr(self.ef, "stock", None)
        func = getattr(stock, "get_history_bill", None)
        if func is None:
            raise ProviderUnavailable("efinance money flow API is unavailable", self.source)
        frame = func(normalize_symbol(symbol))
        return normalize_money_flow_frame(frame)
