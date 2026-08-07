"""人气股：东方财富人气榜前 N 名，补上名称/现价/涨跌幅与所属行业、概念板块。

榜单接口只返回代码与排名（sc/rk/rc），行情走现有腾讯适配器（本机稳定），
行业与概念走 IndustryService 的按天缓存，不额外增加取数成本。
"""

from __future__ import annotations

import time

import pandas as pd
import requests

from backend.app.cache import CacheStore
from backend.app.utils import normalize_symbol, safe_float

RANK_URL = "https://emappdata.eastmoney.com/stockrank/getAllCurrentList"
RANK_TTL_SECONDS = 300
CACHE_KEY = "popularity:rank"


def fetch_rank(limit: int = 100, timeout: int = 12, attempts: int = 3) -> list[dict]:
    """东财人气榜：返回 [{symbol, rank, rank_change}]，按人气排名升序。
    东财偶发超时，重试几次再放弃（由调用方降级到缓存）。"""
    payload = {
        "appId": "appId01",
        "globalId": "786e4c21-70dc-435a-93bb-38",
        "marketType": "",
        "pageNo": 1,
        "pageSize": max(1, min(limit, 100)),
    }
    rows: list[dict] = []
    errors: list[str] = []
    for attempt in range(attempts):
        try:
            response = requests.post(
                RANK_URL,
                json=payload,
                timeout=timeout,
                headers={"User-Agent": "Mozilla/5.0", "Content-Type": "application/json"},
            )
            rows = response.json().get("data") or []
            if rows:
                break
            errors.append("empty")
        except Exception as exc:
            errors.append(f"{type(exc).__name__}")
        if attempt < attempts - 1:
            time.sleep(0.6 * (attempt + 1))
    if not rows:
        raise RuntimeError("; ".join(errors) or "popularity rank unavailable")
    result: list[dict] = []
    for row in rows:
        raw = str(row.get("sc", ""))
        symbol = normalize_symbol(raw[2:] if raw[:2].isalpha() else raw)
        if not symbol:
            continue
        result.append(
            {
                "symbol": symbol,
                "rank": int(row.get("rk", 0) or 0),
                # rc 是较上一次的排名变化（正=上升名次）
                "rank_change": safe_float(row.get("rc")),
            }
        )
    result.sort(key=lambda item: item["rank"])
    return result[:limit]


class PopularityService:
    """人气榜 + 行情 + 行业/概念，结果缓存 5 分钟。"""

    def __init__(self, cache: CacheStore):
        self.cache = cache

    def hot_stocks(self, limit: int = 100, refresh: bool = False) -> tuple[list[dict], list[str]]:
        warnings: list[str] = []
        if not refresh:
            cached = self.cache.read_frame(CACHE_KEY, allow_stale=False)
            if cached:
                return cached[0].to_dict("records")[:limit], warnings

        try:
            ranks = fetch_rank(limit=limit)
        except Exception as exc:
            warnings.append(f"rank:{type(exc).__name__}")
            cached = self.cache.read_frame(CACHE_KEY, allow_stale=True)
            return (cached[0].to_dict("records")[:limit] if cached else []), warnings
        if not ranks:
            warnings.append("rank:empty")
            return [], warnings

        quotes = self._quotes({row["symbol"] for row in ranks}, warnings)
        industries, concepts = self._sectors(warnings)

        rows: list[dict] = []
        for row in ranks:
            symbol = row["symbol"]
            quote = quotes.get(symbol, {})
            rows.append(
                {
                    **row,
                    "name": quote.get("name", ""),
                    "price": quote.get("price"),
                    "pct_chg": quote.get("pct_chg"),
                    "turnover": quote.get("turnover"),
                    "market_cap": quote.get("market_cap"),
                    "industry": industries.get(symbol, ""),
                    "concepts": concepts.get(symbol, [])[:4],
                }
            )
        self.cache.write_frame(
            cache_key=CACHE_KEY,
            data_type="popularity",
            frame=pd.DataFrame(rows),
            source="eastmoney",
            ttl_seconds=RANK_TTL_SECONDS,
        )
        return rows, warnings

    def _quotes(self, symbols: set[str], warnings: list[str]) -> dict[str, dict]:
        """人气榜含沪深主板/创业板/科创板，腾讯行情按 80 只一批取。"""
        from backend.app.providers.tencent_adapter import TencentAdapter

        adapter = TencentAdapter()
        wanted = sorted(symbols)
        found: dict[str, dict] = {}
        for start in range(0, len(wanted), 80):
            batch = wanted[start : start + 80]
            try:
                frame = adapter.realtime_quotes(batch)
                for record in frame.to_dict("records"):
                    found[normalize_symbol(str(record.get("symbol", "")))] = record
            except Exception as exc:
                warnings.append(f"quotes:{type(exc).__name__}")
        return found

    def _sectors(self, warnings: list[str]) -> tuple[dict[str, str], dict[str, list[str]]]:
        from backend.app.industry import IndustryService

        service = IndustryService(self.cache)
        industries, industry_warnings = service.industry_map()
        concepts, concept_warnings = service.concept_map()
        warnings.extend(industry_warnings + concept_warnings)
        return industries, concepts
