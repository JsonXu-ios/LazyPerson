"""板块数据：今日热点板块排行（行业/概念）与成分股。

行业板块走同花顺（akshare 的 THS 源，本机稳定可达）；
概念板块走东财 push2delay（本机不稳，失败降级为空列表 + 警告，不阻断行业数据）。
结果按天缓存到 CacheStore，盘中 TTL 5 分钟。
"""

from __future__ import annotations

import pandas as pd
import requests

from backend.app.cache import CacheStore
from backend.app.utils import safe_float

HOT_TTL_SECONDS = 300
EASTMONEY_HOSTS = ("push2delay.eastmoney.com", "push2.eastmoney.com")
CONCEPT_FS = "m:90+t:3"
INDUSTRY_FS = "m:90+t:2"


def _ths_column(frame: pd.DataFrame, *names: str) -> pd.Series | None:
    for name in names:
        if name in frame.columns:
            return frame[name]
    return None


def normalize_ths_industry(frame: pd.DataFrame) -> list[dict]:
    """同花顺行业板块摘要 → 统一板块行。字段名随 akshare 版本略有差异，做多名兜底。"""
    if frame is None or frame.empty:
        return []
    name = _ths_column(frame, "板块", "名称")
    pct = _ths_column(frame, "涨跌幅", "涨跌幅(%)")
    amount = _ths_column(frame, "总成交额", "成交额")
    up = _ths_column(frame, "上涨家数")
    down = _ths_column(frame, "下跌家数")
    leader = _ths_column(frame, "领涨股")
    leader_pct = _ths_column(frame, "领涨股-涨跌幅", "领涨股涨跌幅")
    rows: list[dict] = []
    for index in range(len(frame)):
        if name is None:
            continue
        rows.append(
            {
                "code": "",
                "name": str(name.iloc[index]),
                "pct_chg": safe_float(pct.iloc[index]) if pct is not None else None,
                "amount": safe_float(amount.iloc[index]) if amount is not None else None,
                "up_count": safe_float(up.iloc[index]) if up is not None else None,
                "down_count": safe_float(down.iloc[index]) if down is not None else None,
                "leader": str(leader.iloc[index]) if leader is not None else "",
                "leader_pct": safe_float(leader_pct.iloc[index]) if leader_pct is not None else None,
                "kind": "industry",
                "source": "ths",
            }
        )
    rows.sort(key=lambda row: row["pct_chg"] if row["pct_chg"] is not None else -999, reverse=True)
    return rows


def fetch_ths_industries() -> list[dict]:
    import akshare as ak

    return normalize_ths_industry(ak.stock_board_industry_summary_ths())


def fetch_eastmoney_boards(kind: str, limit: int = 60, timeout: int = 8) -> list[dict]:
    """东财板块排行：概念 m:90+t:3 / 行业 m:90+t:2。任一域名成功即返回，全失败抛错。"""
    fs = CONCEPT_FS if kind == "concept" else INDUSTRY_FS
    params = {
        "pn": 1,
        "pz": limit,
        "po": 1,
        "np": 1,
        "fltt": 2,
        "invt": 2,
        "fid": "f3",
        "fs": fs,
        "fields": "f12,f14,f3,f6,f104,f105,f128,f136",
    }
    errors: list[str] = []
    for host in EASTMONEY_HOSTS:
        try:
            response = requests.get(f"https://{host}/api/qt/clist/get", params=params, timeout=timeout)
            payload = response.json()
            data = payload.get("data")
            if not data or not data.get("diff"):
                errors.append(f"{host}:empty")
                continue
            rows = []
            for item in data["diff"]:
                rows.append(
                    {
                        "code": str(item.get("f12", "")),
                        "name": str(item.get("f14", "")),
                        "pct_chg": safe_float(item.get("f3")),
                        "amount": safe_float(item.get("f6")),
                        "up_count": safe_float(item.get("f104")),
                        "down_count": safe_float(item.get("f105")),
                        "leader": str(item.get("f128", "")),
                        "leader_pct": safe_float(item.get("f136")),
                        "kind": kind,
                        "source": "eastmoney",
                    }
                )
            return rows
        except Exception as exc:
            errors.append(f"{host}:{type(exc).__name__}")
    raise RuntimeError("; ".join(errors) or "eastmoney boards unavailable")


def fetch_board_constituents(code: str, limit: int = 60, timeout: int = 8) -> list[dict]:
    """板块成分股（东财 fs=b:{code}，按涨幅降序）。同花顺无成分股接口，故统一走东财。"""
    params = {
        "pn": 1,
        "pz": limit,
        "po": 1,
        "np": 1,
        "fltt": 2,
        "invt": 2,
        "fid": "f3",
        "fs": f"b:{code}",
        "fields": "f12,f14,f2,f3,f6,f20",
    }
    errors: list[str] = []
    for host in EASTMONEY_HOSTS:
        try:
            response = requests.get(f"https://{host}/api/qt/clist/get", params=params, timeout=timeout)
            data = response.json().get("data")
            if not data or not data.get("diff"):
                errors.append(f"{host}:empty")
                continue
            return [
                {
                    "symbol": str(item.get("f12", "")),
                    "name": str(item.get("f14", "")),
                    "price": safe_float(item.get("f2")),
                    "pct_chg": safe_float(item.get("f3")),
                    "amount": safe_float(item.get("f6")),
                    "market_cap": safe_float(item.get("f20")),
                }
                for item in data["diff"]
            ]
        except Exception as exc:
            errors.append(f"{host}:{type(exc).__name__}")
    raise RuntimeError("; ".join(errors) or "eastmoney constituents unavailable")


class SectorService:
    """热点板块查询（带缓存）。行业与概念各自独立降级，互不阻断。"""

    def __init__(self, cache: CacheStore):
        self.cache = cache

    def hot_boards(self, limit: int = 20, refresh: bool = False) -> tuple[dict, list[str]]:
        warnings: list[str] = []
        industries = self._cached("sector:hot:industry", refresh, fetch_ths_industries, warnings)
        concepts = self._cached(
            "sector:hot:concept", refresh, lambda: fetch_eastmoney_boards("concept", limit=60), warnings
        )
        return (
            {
                "industries": industries[:limit],
                "concepts": concepts[:limit],
            },
            warnings,
        )

    def constituents(self, code: str, limit: int = 60, refresh: bool = False) -> tuple[list[dict], list[str]]:
        warnings: list[str] = []
        rows = self._cached(
            f"sector:cons:{code}", refresh, lambda: fetch_board_constituents(code, limit=limit), warnings
        )
        return rows[:limit], warnings

    def _cached(self, cache_key: str, refresh: bool, fetcher, warnings: list[str]) -> list[dict]:
        if not refresh:
            cached = self.cache.read_frame(cache_key, allow_stale=False)
            if cached:
                frame, _meta = cached
                return frame.to_dict("records")
        try:
            rows = fetcher()
        except Exception as exc:
            warnings.append(f"{cache_key}:{type(exc).__name__}")
            cached = self.cache.read_frame(cache_key, allow_stale=True)
            return cached[0].to_dict("records") if cached else []
        if not rows:
            warnings.append(f"{cache_key}:empty")
            return []
        self.cache.write_frame(
            cache_key=cache_key,
            data_type="sector",
            frame=pd.DataFrame(rows),
            source=rows[0].get("source", "unknown"),
            ttl_seconds=HOT_TTL_SECONDS,
        )
        return rows
