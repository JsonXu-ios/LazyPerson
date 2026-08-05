"""个股行业与关联概念板块。

行业：baostock 证监会行业分类（全市场一次拉取，按天缓存，本机稳定可达）。
概念：东财板块成分股反查建"股票→概念"映射（一次性拉全部概念板块成分股，
按天缓存）；东财不可达时降级为空，不阻断行业数据。
"""

from __future__ import annotations

import json

import pandas as pd

from backend.app.cache import CacheStore
from backend.app.utils import normalize_symbol, now_utc

INDUSTRY_CACHE_KEY = "industry:baostock:all"
INDUSTRY_TTL_SECONDS = 86400
CONCEPT_MAP_STATE_KEY = "sector:concept_map:v1"


def bs_code(symbol: str) -> str:
    clean = normalize_symbol(symbol)
    return f"sh.{clean}" if clean.startswith("6") else f"sz.{clean}"


def fetch_all_industries() -> pd.DataFrame:
    """全市场证监会行业分类（一次拉取约 5000+ 行）。"""
    import baostock as bs

    login = bs.login()
    if login.error_code != "0":
        raise RuntimeError(f"baostock login failed: {login.error_msg}")
    try:
        rs = bs.query_stock_industry()
        rows: list[dict] = []
        while rs.error_code == "0" and rs.next():
            record = dict(zip(rs.fields, rs.get_row_data()))
            code = str(record.get("code", ""))
            rows.append(
                {
                    "symbol": normalize_symbol(code.split(".")[-1]),
                    "name": str(record.get("code_name", "")),
                    "industry": str(record.get("industry", "")),
                    "classification": str(record.get("industryClassification", "")),
                    "updated": str(record.get("updateDate", "")),
                }
            )
        return pd.DataFrame(rows)
    finally:
        bs.logout()


class IndustryService:
    def __init__(self, cache: CacheStore):
        self.cache = cache

    def all_industries(self, refresh: bool = False) -> tuple[pd.DataFrame, list[str]]:
        warnings: list[str] = []
        if not refresh:
            cached = self.cache.read_frame(INDUSTRY_CACHE_KEY, allow_stale=False)
            if cached:
                return cached[0], warnings
        try:
            frame = fetch_all_industries()
        except Exception as exc:
            warnings.append(f"baostock:{type(exc).__name__}")
            cached = self.cache.read_frame(INDUSTRY_CACHE_KEY, allow_stale=True)
            return (cached[0] if cached else pd.DataFrame()), warnings
        if frame.empty:
            warnings.append("baostock:empty")
            return frame, warnings
        self.cache.write_frame(
            cache_key=INDUSTRY_CACHE_KEY,
            data_type="industry",
            frame=frame,
            source="baostock",
            ttl_seconds=INDUSTRY_TTL_SECONDS,
        )
        return frame, warnings

    def industry_map(self, refresh: bool = False) -> tuple[dict[str, str], list[str]]:
        frame, warnings = self.all_industries(refresh=refresh)
        if frame.empty:
            return {}, warnings
        return dict(zip(frame["symbol"], frame["industry"])), warnings

    def industry_of(self, symbol: str, refresh: bool = False) -> tuple[dict, list[str]]:
        clean = normalize_symbol(symbol)
        mapping, warnings = self.industry_map(refresh=refresh)
        concepts, concept_warnings = self.concepts_of(clean)
        return (
            {
                "symbol": clean,
                "industry": mapping.get(clean, ""),
                "concepts": concepts,
            },
            warnings + concept_warnings,
        )

    # ---------- 概念映射（股票 → 概念板块名列表） ----------

    def concepts_of(self, symbol: str) -> tuple[list[str], list[str]]:
        mapping, warnings = self.concept_map()
        return mapping.get(normalize_symbol(symbol), []), warnings

    def concept_map(self, refresh: bool = False) -> tuple[dict[str, list[str]], list[str]]:
        """股票→概念板块名映射，按天缓存在 app_state。"""
        warnings: list[str] = []
        today = now_utc().date().isoformat()
        if not refresh:
            raw = self.cache.get_state(CONCEPT_MAP_STATE_KEY)
            if raw:
                try:
                    payload = json.loads(raw)
                    if payload.get("built_at") == today:
                        return payload.get("map", {}), warnings
                except ValueError:
                    pass
        try:
            mapping = self._build_concept_map()
        except Exception as exc:
            warnings.append(f"concept_map:{type(exc).__name__}")
            raw = self.cache.get_state(CONCEPT_MAP_STATE_KEY)
            if raw:
                try:
                    return json.loads(raw).get("map", {}), warnings
                except ValueError:
                    return {}, warnings
            return {}, warnings
        self.cache.set_state(
            CONCEPT_MAP_STATE_KEY,
            json.dumps({"built_at": today, "map": mapping}, ensure_ascii=False),
        )
        return mapping, warnings

    def _build_concept_map(
        self, max_boards: int = 200, per_board: int = 200, workers: int = 8
    ) -> dict[str, list[str]]:
        """拉取涨幅前 max_boards 个概念板块的成分股，反查建映射（每天一次）。
        并发拉取：本机东财单请求约 7s，串行 200 个要 25 分钟。"""
        from concurrent.futures import ThreadPoolExecutor

        from backend.app.sectors import fetch_board_constituents, fetch_eastmoney_boards

        boards = [
            board
            for board in fetch_eastmoney_boards("concept", limit=max_boards)
            if board.get("code") and board.get("name")
        ]

        def fetch(board: dict) -> tuple[str, list[dict]]:
            try:
                return board["name"], fetch_board_constituents(board["code"], limit=per_board)
            except Exception:
                return board["name"], []

        mapping: dict[str, list[str]] = {}
        with ThreadPoolExecutor(max_workers=workers) as pool:
            for name, rows in pool.map(fetch, boards):
                for row in rows:
                    symbol = row.get("symbol")
                    if symbol and name not in mapping.setdefault(symbol, []):
                        mapping[symbol].append(name)  # 同名概念板块可能重复出现，去重
        if not mapping:
            raise RuntimeError("concept map build produced no rows")
        return mapping
