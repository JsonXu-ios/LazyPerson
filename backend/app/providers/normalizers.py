from datetime import datetime
from typing import Iterable

import pandas as pd

from backend.app.utils import guess_market, safe_float


def first_value(row: pd.Series, names: Iterable[str]):
    for name in names:
        if name in row and pd.notna(row[name]):
            return row[name]
    return None


def normalize_quote_frame(frame: pd.DataFrame) -> pd.DataFrame:
    rows: list[dict] = []
    for _, row in frame.iterrows():
        symbol = str(first_value(row, ["股票代码", "代码", "symbol", "code"]) or "").strip()
        name = str(first_value(row, ["股票名称", "名称", "name"]) or "").strip()
        rows.append(
            {
                "symbol": symbol.replace(".SH", "").replace(".SZ", "").replace(".BJ", ""),
                "market": guess_market(symbol),
                "name": name,
                "trade_time": first_value(row, ["行情时间", "更新时间", "trade_time", "time"])
                or datetime.now().isoformat(),
                "price": safe_float(first_value(row, ["最新价", "price", "close", "收盘"])),
                "open": safe_float(first_value(row, ["今开", "开盘", "open"])),
                "high": safe_float(first_value(row, ["最高", "最高价", "high"])),
                "low": safe_float(first_value(row, ["最低", "最低价", "low"])),
                "pre_close": safe_float(first_value(row, ["昨收", "pre_close"])),
                "pct_chg": safe_float(first_value(row, ["涨跌幅", "pct_chg"])),
                "change": safe_float(first_value(row, ["涨跌额", "change"])),
                "volume": safe_float(first_value(row, ["成交量", "volume"])),
                "amount": safe_float(first_value(row, ["成交额", "amount"])),
                "turnover": safe_float(first_value(row, ["换手率", "turnover"])),
            }
        )
    return pd.DataFrame(rows)


def normalize_kline_frame(frame: pd.DataFrame) -> pd.DataFrame:
    rows: list[dict] = []
    for _, row in frame.iterrows():
        rows.append(
            {
                "time": str(first_value(row, ["日期", "时间", "date", "time", "trade_date"]) or ""),
                "open": safe_float(first_value(row, ["开盘", "open"])),
                "high": safe_float(first_value(row, ["最高", "high"])),
                "low": safe_float(first_value(row, ["最低", "low"])),
                "close": safe_float(first_value(row, ["收盘", "close"])),
                "volume": safe_float(first_value(row, ["成交量", "volume"])),
                "amount": safe_float(first_value(row, ["成交额", "amount"])),
                "pct_chg": safe_float(first_value(row, ["涨跌幅", "pct_chg"])),
                "turnover": safe_float(first_value(row, ["换手率", "turnover"])),
            }
        )
    result = pd.DataFrame(rows)
    if not result.empty:
        result = result.dropna(subset=["time"]).drop_duplicates(subset=["time"]).sort_values("time")
    return result


def normalize_symbol_frame(frame: pd.DataFrame) -> pd.DataFrame:
    rows: list[dict] = []
    for _, row in frame.iterrows():
        symbol = str(first_value(row, ["代码", "股票代码", "symbol", "code"]) or "").strip()
        name = str(first_value(row, ["名称", "股票名称", "name"]) or "").strip()
        rows.append(
            {
                "symbol": symbol.replace(".SH", "").replace(".SZ", "").replace(".BJ", ""),
                "market": guess_market(symbol),
                "name": name,
                "pinyin": "",
                "listed_at": first_value(row, ["上市时间", "上市日期", "list_date"]),
            }
        )
    return pd.DataFrame([row for row in rows if row["symbol"]])


def normalize_money_flow_frame(frame: pd.DataFrame) -> pd.DataFrame:
    rows: list[dict] = []
    for _, row in frame.iterrows():
        rows.append(
            {
                "time": str(first_value(row, ["日期", "时间", "date", "time"]) or ""),
                "main_net_inflow": safe_float(first_value(row, ["主力净流入", "主力净流入-净额", "main_net_inflow"])),
                "super_large_net_inflow": safe_float(first_value(row, ["超大单净流入", "超大单净流入-净额"])),
                "large_net_inflow": safe_float(first_value(row, ["大单净流入", "大单净流入-净额"])),
                "medium_net_inflow": safe_float(first_value(row, ["中单净流入", "中单净流入-净额"])),
                "small_net_inflow": safe_float(first_value(row, ["小单净流入", "小单净流入-净额"])),
            }
        )
    return pd.DataFrame([row for row in rows if row["time"]])

