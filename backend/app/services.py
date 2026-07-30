from __future__ import annotations

import json
from collections.abc import Callable
from datetime import datetime, timedelta

import pandas as pd

from backend.app.cache import CacheStore
from backend.app.config import Settings
from backend.app.errors import ProviderError
from backend.app.indicators import compute_indicators
from backend.app.models import DataQuality
from backend.app.providers.akshare_adapter import AKShareAdapter
from backend.app.providers.baostock_adapter import BaoStockAdapter
from backend.app.providers.eastmoney_adapter import EastmoneyFundamentalsAdapter
from backend.app.providers.efinance_adapter import EFinanceAdapter
from backend.app.providers.tencent_adapter import TencentAdapter
from backend.app.utils import is_a_share_symbol, normalize_symbol, now_utc


class MarketService:
    """只做沪深 A 股。美股/黄金/加密与 Yahoo 数据源已移除。"""

    default_watchlist_state_key = "default_watchlist_seeded"
    default_watchlist = [
        {"symbol": "002138", "market": "SZ", "name": "顺络电子", "group_name": "a_share", "sort_order": 1, "note": "V3 自动画线测试标的"},
        {"symbol": "600519", "market": "SH", "name": "贵州茅台", "group_name": "a_share", "sort_order": 2, "note": ""},
        {"symbol": "000001", "market": "SZ", "name": "平安银行", "group_name": "a_share", "sort_order": 3, "note": ""},
        {"symbol": "300750", "market": "SZ", "name": "宁德时代", "group_name": "a_share", "sort_order": 4, "note": ""},
    ]

    def __init__(self, settings: Settings, cache: CacheStore):
        self.settings = settings
        self.cache = cache

    def _message_for(self, source: str, from_cache: bool = False, stale: bool = False, fallback: bool = False) -> str:
        if fallback:
            return "实时行情不可用，使用最新日 K 兜底"
        if stale:
            return "缓存数据已过期，可能滞后"
        if from_cache:
            return "使用本地缓存"
        if source in ("efinance", "eastmoney"):
            return "东方财富数据"
        if source == "akshare":
            return "AKShare 数据"
        if source == "baostock":
            return "BaoStock 历史数据"
        if source == "tencent":
            return "腾讯行情数据"
        if source == "sqlite":
            return "本地自选股数据"
        return "数据已更新"

    def _quality_from_meta(self, meta: dict, stale: bool | None = None, warnings: list[str] | None = None) -> DataQuality:
        updated = datetime.fromisoformat(meta["updated_at"]) if meta.get("updated_at") else None
        is_stale = meta.get("stale", False) if stale is None else stale
        source = meta.get("source", "cache")
        return DataQuality(
            source=source,
            from_cache=True,
            updated_at=updated,
            stale=is_stale,
            fallback=False,
            message=self._message_for(source, from_cache=True, stale=is_stale),
            warnings=warnings or ([] if not meta.get("stale") else ["stale_cache"]),
        )

    def _fetch_with_cache(
        self,
        cache_key: str,
        data_type: str,
        fetchers: list[tuple[str, callable]],
        ttl_seconds: int,
        symbol: str = "",
        period: str = "",
        refresh: bool = False,
        cache_validator: Callable[[pd.DataFrame, dict], str | None] | None = None,
        prefer_stale_cache: bool = False,
    ) -> tuple[pd.DataFrame, DataQuality]:
        warnings: list[str] = []
        if prefer_stale_cache and not refresh:
            cached = self.cache.read_frame(cache_key, allow_stale=True)
            if cached:
                frame, meta = cached
                invalid_reason = cache_validator(frame, meta) if cache_validator else None
                if not invalid_reason:
                    return frame, self._quality_from_meta(meta, stale=bool(meta.get("stale")))
                warnings.append(f"cache:{invalid_reason}")

        if not refresh:
            cached = self.cache.read_frame(cache_key, allow_stale=False)
            if cached:
                frame, meta = cached
                invalid_reason = cache_validator(frame, meta) if cache_validator else None
                if not invalid_reason:
                    return frame, self._quality_from_meta(meta)
                warnings.append(f"cache:{invalid_reason}")

        for source, fetcher in fetchers:
            try:
                frame = fetcher()
                if frame is None or frame.empty:
                    warnings.append(f"{source}:empty")
                    continue
                invalid_reason = cache_validator(frame, {"source": source}) if cache_validator else None
                if invalid_reason:
                    warnings.append(f"{source}:{invalid_reason}")
                    continue
                start_at = str(frame.iloc[0].get("time", "")) if "time" in frame.columns else None
                end_at = str(frame.iloc[-1].get("time", "")) if "time" in frame.columns else None
                self.cache.write_frame(
                    cache_key=cache_key,
                    data_type=data_type,
                    frame=frame,
                    source=source,
                    symbol=symbol,
                    period=period,
                    ttl_seconds=ttl_seconds,
                    start_at=start_at,
                    end_at=end_at,
                )
                return frame, DataQuality(
                    source=source,
                    from_cache=False,
                    updated_at=now_utc(),
                    stale=False,
                    fallback=False,
                    message=self._message_for(source),
                    warnings=warnings,
                )
            except Exception as exc:
                if isinstance(exc, ProviderError):
                    warnings.append(f"{source}:{exc}")
                else:
                    warnings.append(f"{source}:{type(exc).__name__}")

        cached = self.cache.read_frame(cache_key, allow_stale=True)
        if cached:
            frame, meta = cached
            invalid_reason = cache_validator(frame, meta) if cache_validator else None
            if invalid_reason:
                warnings.append(f"cache:{invalid_reason}")
                raise ProviderError("; ".join(warnings) or "cached data is invalid")
            return frame, self._quality_from_meta(meta, stale=True, warnings=warnings + ["stale_cache"])
        raise ProviderError("; ".join(warnings) or "no provider returned data")

    def _validate_recent_daily_cache(self, frame: pd.DataFrame, _meta: dict) -> str | None:
        if frame.empty or "time" not in frame.columns:
            return "empty_daily_cache"
        latest = pd.to_datetime(frame["time"], errors="coerce").max()
        if pd.isna(latest):
            return "invalid_daily_time"
        lag_days = (now_utc().date() - latest.date()).days
        if lag_days > 14:
            return f"daily_cache_latest_too_old:{latest.date().isoformat()}"
        return None

    def _filter_daily_trading_rows(self, frame: pd.DataFrame) -> pd.DataFrame:
        if frame.empty or "time" not in frame.columns:
            return frame
        dates = pd.to_datetime(frame["time"], errors="coerce")
        valid = dates.notna() & dates.dt.weekday.lt(5)
        for column in ["open", "high", "low", "close"]:
            if column in frame.columns:
                valid &= frame[column].notna()
        return frame.loc[valid].reset_index(drop=True)

    def _validate_quote_symbols(self, expected: list[str]) -> Callable[[pd.DataFrame, dict], str | None]:
        def validate(frame: pd.DataFrame, _meta: dict) -> str | None:
            if frame.empty or "symbol" not in frame.columns:
                return "empty_quotes"
            found = {normalize_symbol(str(symbol)) for symbol in frame["symbol"].dropna()}
            missing = [symbol for symbol in expected if symbol not in found]
            return f"missing_symbols:{','.join(missing)}" if missing else None

        return validate

    def search_symbols(self, query: str, limit: int = 20, refresh: bool = False) -> tuple[list[dict], DataQuality]:
        cache_key = "symbols:all"
        rows = self.cache.search_symbols(query, limit)
        if refresh or not rows:
            frame, quality = self._fetch_with_cache(
                cache_key,
                "symbols",
                [("akshare", lambda: AKShareAdapter().symbols())],
                ttl_seconds=self.settings.symbols_ttl_seconds,
                refresh=refresh,
            )
            self.cache.upsert_symbols(frame.to_dict("records"))
            rows = self.cache.search_symbols(query, limit)
        else:
            quality = DataQuality(
                source="sqlite",
                from_cache=True,
                updated_at=now_utc(),
                message=self._message_for("sqlite", from_cache=True),
            )
        for row in rows:
            row["display"] = f"{row['symbol']}.{row.get('market', '')} {row.get('name', '')}".strip()
        return rows, quality

    def realtime_quotes(self, symbols: list[str], refresh: bool = False) -> tuple[list[dict], DataQuality]:
        clean_symbols = list(dict.fromkeys(normalize_symbol(symbol) for symbol in symbols if symbol.strip()))
        if not clean_symbols:
            return [], DataQuality(source="unknown", updated_at=now_utc())
        try:
            cache_key = f"quote:realtime:a:{','.join(sorted(clean_symbols))}"
            frame, quality = self._fetch_with_cache(
                cache_key,
                "quote",
                [
                    ("tencent", lambda: TencentAdapter().realtime_quotes(clean_symbols)),
                    ("efinance", lambda: EFinanceAdapter().realtime_quotes(clean_symbols)),
                    ("akshare", lambda: AKShareAdapter().realtime_quotes(clean_symbols)),
                ],
                ttl_seconds=self.settings.quote_ttl_seconds,
                symbol="_".join(clean_symbols),
                refresh=refresh,
                cache_validator=self._validate_quote_symbols(clean_symbols),
                prefer_stale_cache=True,
            )
            order = {symbol: index for index, symbol in enumerate(clean_symbols)}
            frame["_order"] = frame["symbol"].map(lambda value: order.get(normalize_symbol(str(value)), len(order)))
            frame = frame.sort_values("_order").drop(columns=["_order"])
            return frame.to_dict("records"), quality
        except ProviderError as exc:
            rows: list[dict] = []
            for symbol in clean_symbols:
                try:
                    payload, _ = self.kline(symbol, period="day", indicators=[], refresh=False)
                except ProviderError:
                    continue
                if not payload["bars"]:
                    continue
                latest = payload["bars"][-1]
                previous = payload["bars"][-2] if len(payload["bars"]) > 1 else {}
                close = latest.get("close")
                pre_close = previous.get("close")
                rows.append(
                    {
                        "symbol": symbol,
                        "market": "",
                        "name": "",
                        "trade_time": latest.get("time"),
                        "price": close,
                        "open": latest.get("open"),
                        "high": latest.get("high"),
                        "low": latest.get("low"),
                        "pre_close": pre_close,
                        "pct_chg": latest.get("pct_chg"),
                        "change": (close - pre_close) if close is not None and pre_close is not None else None,
                        "volume": latest.get("volume"),
                        "amount": latest.get("amount"),
                        "turnover": latest.get("turnover"),
                    }
                )
            if rows:
                return rows, DataQuality(
                    source="kline_fallback",
                    from_cache=True,
                    updated_at=now_utc(),
                    stale=True,
                    fallback=True,
                    message=self._message_for("kline_fallback", from_cache=True, stale=True, fallback=True),
                    warnings=["realtime_unavailable", str(exc)],
                )
            raise

    def kline(
        self,
        symbol: str,
        period: str = "day",
        start: str | None = None,
        end: str | None = None,
        adjust: str | None = None,
        indicators: list[str] | None = None,
        limit: int | None = None,
        refresh: bool = False,
    ) -> tuple[dict, DataQuality]:
        clean = normalize_symbol(symbol)
        adjust = adjust or self.settings.default_adjust
        bar_periods = ("day", "week", "month")
        data_type = f"kline_{period}" if period in bar_periods else "kline_minute"
        ttl = self.settings.day_ttl_seconds if period in bar_periods else self.settings.minute_ttl_seconds
        cache_key = f"{data_type}:{clean}:{period}:{adjust}:{start or ''}:{end or ''}"
        request_start = start
        request_end = end
        if period in bar_periods and not start and not end:
            days_per_bar = {"day": 3, "week": 10, "month": 40}[period]
            days_back = max(365, (limit or 140) * days_per_bar)
            request_start = (now_utc().date() - timedelta(days=days_back)).isoformat()
        fetchers: list[tuple[str, callable]] = []
        if period in bar_periods:
            fetchers = (
                [
                    ("tencent", lambda: TencentAdapter().kline(clean, period, request_start, request_end, adjust)),
                    ("efinance", lambda: EFinanceAdapter().kline(clean, period, request_start, request_end, adjust)),
                    ("akshare", lambda: AKShareAdapter().kline(clean, period, request_start, request_end, adjust)),
                ]
                if not start and not end
                else [
                    ("akshare", lambda: AKShareAdapter().kline(clean, period, request_start, request_end, adjust)),
                    ("efinance", lambda: EFinanceAdapter().kline(clean, period, request_start, request_end, adjust)),
                    ("tencent", lambda: TencentAdapter().kline(clean, period, request_start, request_end, adjust)),
                ]
            )
            if period == "day":  # baostock 仅支持日线
                fetchers.append(("baostock", lambda: BaoStockAdapter().kline(clean, request_start, request_end, adjust)))
        else:
            fetchers = [
                ("tencent", lambda: TencentAdapter().kline(clean, period, start, end, adjust)),
                ("efinance", lambda: EFinanceAdapter().kline(clean, period, start, end, adjust)),
                ("akshare", lambda: AKShareAdapter().kline(clean, period, start, end, adjust)),
            ]
        frame, quality = self._fetch_with_cache(
            cache_key,
            data_type,
            fetchers,
            ttl_seconds=ttl,
            symbol=clean,
            period=period,
            refresh=refresh,
            cache_validator=self._validate_recent_daily_cache if period == "day" and not end else None,
            prefer_stale_cache=period in bar_periods,
        )
        if period in bar_periods:
            frame = self._filter_daily_trading_rows(frame)
        full_indicator_payload = compute_indicators(frame, indicators or []) if indicators else {}
        if limit and limit > 0:
            frame = frame.tail(limit).reset_index(drop=True)
            indicator_payload = {
                group: {name: values[-limit:] for name, values in series.items()}
                for group, series in full_indicator_payload.items()
            }
        else:
            indicator_payload = full_indicator_payload
        return {
            "symbol": clean,
            "period": period,
            "adjust": adjust,
            "bars": frame.to_dict("records"),
            "indicators": indicator_payload,
        }, quality

    def money_flow(self, symbol: str, period: str = "day", refresh: bool = False) -> tuple[dict, DataQuality]:
        clean = normalize_symbol(symbol)
        cache_key = f"money_flow:{clean}:{period}"
        frame, quality = self._fetch_with_cache(
            cache_key,
            "money_flow",
            [
                ("efinance", lambda: EFinanceAdapter().money_flow(clean)),
                ("akshare", lambda: AKShareAdapter().money_flow(clean)),
            ],
            ttl_seconds=self.settings.money_flow_ttl_seconds,
            symbol=clean,
            period=period,
            refresh=refresh,
        )
        return {"symbol": clean, "items": frame.to_dict("records")}, quality

    def fundamentals(self, symbol: str, refresh: bool = False) -> tuple[dict, DataQuality]:
        """分红 + 业绩 + 估值。返回结构是嵌套的，不走 write_frame 的表格缓存，
        改用 state 表存 JSON（键 fundamentals:{symbol}，带 fetched_at 判 TTL）。"""
        clean = normalize_symbol(symbol)
        if not is_a_share_symbol(clean):
            raise ProviderError("fundamentals are only available for A-share symbols")
        state_key = f"fundamentals:{clean}"
        ttl = self.settings.fundamentals_ttl_seconds

        cached_payload: dict | None = None
        cached_age: float | None = None
        raw = self.cache.get_state(state_key)
        if raw:
            try:
                cached = json.loads(raw)
                cached_payload = cached.get("data")
                fetched_at = datetime.fromisoformat(cached["fetched_at"])
                cached_age = (now_utc() - fetched_at).total_seconds()
            except (ValueError, KeyError, TypeError):
                cached_payload = None
        if not refresh and cached_payload and cached_age is not None and cached_age < ttl:
            return cached_payload, DataQuality(
                source="eastmoney",
                from_cache=True,
                updated_at=now_utc(),
                message=self._message_for("eastmoney", from_cache=True),
            )

        try:
            data = EastmoneyFundamentalsAdapter().fundamentals(clean)
        except ProviderError as exc:
            if cached_payload:  # 远端不可用时回落到过期缓存，聊胜于无
                return cached_payload, DataQuality(
                    source="eastmoney",
                    from_cache=True,
                    updated_at=now_utc(),
                    stale=True,
                    message=self._message_for("eastmoney", from_cache=True, stale=True),
                    warnings=[f"eastmoney:{exc}", "stale_cache"],
                )
            raise
        self.cache.set_state(state_key, json.dumps({"fetched_at": now_utc().isoformat(), "data": data}))
        return data, DataQuality(
            source="eastmoney",
            from_cache=False,
            updated_at=now_utc(),
            message=self._message_for("eastmoney"),
            warnings=data.get("warnings", []),
        )

    def list_watchlist(self, group_name: str | None = None) -> list[dict]:
        rows = self.cache.list_watchlist(group_name)
        if rows and self.cache.get_state(self.default_watchlist_state_key) != "1":
            self.cache.set_state(self.default_watchlist_state_key, "1")

        if not rows and self.cache.get_state(self.default_watchlist_state_key) != "1":
            for item in self.default_watchlist:
                if group_name and item["group_name"] != group_name:
                    continue
                self.cache.upsert_symbols([item])
                self.cache.add_watchlist(item["symbol"], item["group_name"], item["note"])
            self.cache.set_state(self.default_watchlist_state_key, "1")
            rows = self.cache.list_watchlist(group_name)

        if rows:
            return rows

        if self.cache.get_state(self.default_watchlist_state_key) == "1":
            return []
        return rows

    def add_watchlist(self, symbol: str, group_name: str = "default", note: str = "") -> None:
        self.cache.add_watchlist(normalize_symbol(symbol), group_name, note)

    def remove_watchlist(self, symbol: str, group_name: str | None = None) -> None:
        self.cache.remove_watchlist(normalize_symbol(symbol), group_name)

    def clear_cache(self, data_type: str | None = None, symbol: str | None = None) -> int:
        return self.cache.clear(data_type=data_type, symbol=normalize_symbol(symbol) if symbol else None)
