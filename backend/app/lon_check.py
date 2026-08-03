"""八档局 LON 多头标记：日线、周线、月线三个周期上，
lon 与 lonma 整体向上，且 lonma 不压在 lon 上方（lon ≥ lonma）。
只对命中的股票计算；周/月K走 缓存→腾讯（与图表共用缓存键）。"""

from __future__ import annotations

from datetime import timedelta

import pandas as pd

from backend.app.cache import CacheStore
from backend.app.indicators import add_lon
from backend.app.utils import now_utc

PERIODS = ("day", "week", "month")
# 缓存最新一根bar允许的滞后（自然日）：超过则重拉该周期
MAX_LAG_DAYS = {"day": 4, "week": 11, "month": 45}
# 各周期拉取跨度（自然日）：LON 的 LONG 是累计序列，给足历史让 SMA10/20 收敛
FETCH_DAYS = {"day": 420, "week": 1100, "month": 4200}


def lon_trend_ok(lon: list, lonma: list) -> bool:
    """单周期判定：lon、lonma 都比上一根高（整体向上），且 lonma 不压在 lon 上面。"""
    pairs = [
        (float(a), float(b))
        for a, b in zip(lon, lonma)
        if a is not None and b is not None
    ]
    if len(pairs) < 2:
        return False
    (prev_lon, prev_ma), (last_lon, last_ma) = pairs[-2], pairs[-1]
    return last_lon > prev_lon and last_ma > prev_ma and last_lon >= last_ma


class LonChecker:
    """为命中行补 lon_ok 标记（日/周/月全满足才 True）。"""

    def __init__(self, cache: CacheStore, adjust: str = "qfq"):
        self.cache = cache
        self.adjust = adjust

    def enrich(self, hits: list[dict]) -> None:
        from backend.app.providers.tencent_adapter import TencentAdapter

        adapter = TencentAdapter()
        for hit in hits:
            hit["lon_ok"] = self._check_symbol(adapter, hit["symbol"])

    def _check_symbol(self, adapter, symbol: str) -> bool:
        for period in PERIODS:
            try:
                frame = self._cached_bars(adapter, symbol, period)
            except Exception:
                return False
            if frame is None or len(frame) < 25:
                return False
            payload = add_lon(frame)
            if not lon_trend_ok(payload.get("lon", []), payload.get("lonma", [])):
                return False
        return True

    def _cached_bars(self, adapter, symbol: str, period: str) -> pd.DataFrame | None:
        """缓存→腾讯（15s超时），缓存键与 MarketService/扫描日K完全一致，互相复用。"""
        cache_key = f"kline_{period}:{symbol}:{period}:{self.adjust}::"
        cached = self.cache.read_frame(cache_key, allow_stale=True)
        if cached:
            frame, _meta = cached
            if len(frame) and not self._too_old(frame, MAX_LAG_DAYS[period]):
                return frame
        start = (now_utc().date() - timedelta(days=FETCH_DAYS[period])).isoformat()
        frame = adapter.kline(symbol, period, start, None, self.adjust)
        if frame is None or frame.empty:
            return None
        self.cache.write_frame(
            cache_key=cache_key,
            data_type=f"kline_{period}",
            frame=frame,
            source="tencent",
            symbol=symbol,
            period=period,
            ttl_seconds=1800,
            start_at=str(frame.iloc[0].get("time", "")),
            end_at=str(frame.iloc[-1].get("time", "")),
        )
        return frame

    def _too_old(self, frame: pd.DataFrame, max_lag_days: int) -> bool:
        raw = str(frame.iloc[-1].get("time", ""))[:10]
        try:
            last = pd.Timestamp(raw).date()
        except ValueError:
            return True
        return (now_utc().date() - last).days > max_lag_days
