from __future__ import annotations

import pandas as pd

from backend.app.errors import ProviderUnavailable
from backend.app.providers.normalizers import normalize_kline_frame
from backend.app.utils import guess_market, normalize_symbol


class BaoStockAdapter:
    source = "baostock"

    def __init__(self):
        try:
            import baostock as bs
        except Exception as exc:
            raise ProviderUnavailable("BaoStock is not installed or cannot be imported", self.source) from exc
        self.bs = bs

    def _code(self, symbol: str) -> str:
        clean = normalize_symbol(symbol)
        market = guess_market(clean).lower()
        return f"{market}.{clean}"

    def kline(self, symbol: str, start: str | None, end: str | None, adjust: str) -> pd.DataFrame:
        lg = self.bs.login()
        if lg.error_code != "0":
            raise ProviderUnavailable(f"BaoStock login failed: {lg.error_msg}", self.source)
        try:
            rs = self.bs.query_history_k_data_plus(
                self._code(symbol),
                "date,open,high,low,close,volume,amount,turn,pctChg",
                start_date=start or "1990-01-01",
                end_date=end or "2050-01-01",
                frequency="d",
                adjustflag={"none": "3", "qfq": "2", "hfq": "1"}.get(adjust, "2"),
            )
            rows = []
            while rs.next():
                rows.append(rs.get_row_data())
            frame = pd.DataFrame(rows, columns=rs.fields)
            frame = frame.rename(
                columns={
                    "date": "date",
                    "turn": "turnover",
                    "pctChg": "pct_chg",
                }
            )
            return normalize_kline_frame(frame)
        finally:
            self.bs.logout()

