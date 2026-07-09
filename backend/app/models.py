from datetime import datetime
from typing import Any

from pydantic import BaseModel, Field


class DataQuality(BaseModel):
    source: str = "unknown"
    from_cache: bool = False
    updated_at: datetime | None = None
    stale: bool = False
    fallback: bool = False
    message: str = ""
    warnings: list[str] = Field(default_factory=list)


class ApiResponse(BaseModel):
    data: Any
    quality: DataQuality | None = None


class StockSymbol(BaseModel):
    symbol: str
    market: str = ""
    name: str = ""
    pinyin: str = ""
    display: str = ""


class StockQuote(BaseModel):
    symbol: str
    market: str = ""
    name: str = ""
    trade_time: datetime | None = None
    price: float | None = None
    open: float | None = None
    high: float | None = None
    low: float | None = None
    pre_close: float | None = None
    pct_chg: float | None = None
    change: float | None = None
    volume: float | None = None
    amount: float | None = None
    turnover: float | None = None


class KlineBar(BaseModel):
    time: str
    open: float | None = None
    high: float | None = None
    low: float | None = None
    close: float | None = None
    volume: float | None = None
    amount: float | None = None
    pct_chg: float | None = None
    turnover: float | None = None


class KlinePayload(BaseModel):
    symbol: str
    period: str
    adjust: str
    bars: list[KlineBar]
    indicators: dict[str, Any] = Field(default_factory=dict)


class MoneyFlowItem(BaseModel):
    time: str
    main_net_inflow: float | None = None
    super_large_net_inflow: float | None = None
    large_net_inflow: float | None = None
    medium_net_inflow: float | None = None
    small_net_inflow: float | None = None


class MoneyFlowPayload(BaseModel):
    symbol: str
    items: list[MoneyFlowItem]


class WatchlistItem(BaseModel):
    symbol: str
    market: str = ""
    name: str = ""
    group_name: str = "default"
    sort_order: int = 0
    note: str = ""


class WatchlistCreate(BaseModel):
    symbol: str
    group_name: str = "default"
    note: str = ""
