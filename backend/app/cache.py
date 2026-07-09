from __future__ import annotations

import hashlib
import sqlite3
from contextlib import contextmanager
from datetime import datetime, timezone
from pathlib import Path
from typing import Iterable

import pandas as pd

from backend.app.config import Settings
from backend.app.utils import now_utc


class CacheStore:
    def __init__(self, settings: Settings):
        self.settings = settings
        self.root = settings.cache_dir
        self.db_path = settings.sqlite_path
        self.root.mkdir(parents=True, exist_ok=True)
        self._init_db()

    def _connect(self) -> sqlite3.Connection:
        conn = sqlite3.connect(self.db_path)
        conn.row_factory = sqlite3.Row
        return conn

    @contextmanager
    def _connection(self):
        conn = self._connect()
        try:
            yield conn
            conn.commit()
        finally:
            conn.close()

    def _init_db(self) -> None:
        with self._connection() as conn:
            conn.executescript(
                """
                create table if not exists symbols (
                    symbol text primary key,
                    market text not null default '',
                    name text not null default '',
                    pinyin text not null default '',
                    listed_at text,
                    updated_at text not null
                );

                create table if not exists watchlist (
                    id integer primary key autoincrement,
                    symbol text not null,
                    group_name text not null default 'default',
                    sort_order integer not null default 0,
                    note text not null default '',
                    created_at text not null,
                    unique(symbol, group_name)
                );

                create table if not exists cache_index (
                    cache_key text primary key,
                    data_type text not null,
                    symbol text not null default '',
                    period text not null default '',
                    path text not null,
                    source text not null,
                    start_at text,
                    end_at text,
                    updated_at text not null,
                    ttl_seconds integer not null
                );

                create table if not exists app_state (
                    key text primary key,
                    value text not null,
                    updated_at text not null
                );
                """
            )

    def upsert_symbols(self, rows: Iterable[dict]) -> None:
        now = now_utc().isoformat()
        with self._connection() as conn:
            conn.executemany(
                """
                insert into symbols(symbol, market, name, pinyin, listed_at, updated_at)
                values(:symbol, :market, :name, :pinyin, :listed_at, :updated_at)
                on conflict(symbol) do update set
                    market=excluded.market,
                    name=excluded.name,
                    pinyin=excluded.pinyin,
                    listed_at=excluded.listed_at,
                    updated_at=excluded.updated_at
                """,
                [
                    {
                        "symbol": row.get("symbol", ""),
                        "market": row.get("market", ""),
                        "name": row.get("name", ""),
                        "pinyin": row.get("pinyin", ""),
                        "listed_at": row.get("listed_at"),
                        "updated_at": row.get("updated_at", now),
                    }
                    for row in rows
                    if row.get("symbol")
                ],
            )

    def search_symbols(self, query: str, limit: int = 20) -> list[dict]:
        like = f"%{query.strip()}%"
        with self._connection() as conn:
            rows = conn.execute(
                """
                select symbol, market, name, pinyin
                from symbols
                where symbol like ? or name like ? or pinyin like ?
                order by
                    case when symbol = ? then 0 when symbol like ? then 1 else 2 end,
                    symbol
                limit ?
                """,
                (like, like, like, query, f"{query}%", limit),
            ).fetchall()
        return [dict(row) for row in rows]

    def add_watchlist(self, symbol: str, group_name: str = "default", note: str = "") -> None:
        with self._connection() as conn:
            max_order = conn.execute(
                "select coalesce(max(sort_order), 0) from watchlist where group_name = ?",
                (group_name,),
            ).fetchone()[0]
            conn.execute(
                """
                insert into watchlist(symbol, group_name, sort_order, note, created_at)
                values(?, ?, ?, ?, ?)
                on conflict(symbol, group_name) do update set note=excluded.note
                """,
                (symbol, group_name, max_order + 1, note, now_utc().isoformat()),
            )

    def remove_watchlist(self, symbol: str, group_name: str | None = None) -> None:
        with self._connection() as conn:
            if group_name:
                conn.execute(
                    "delete from watchlist where symbol = ? and group_name = ?",
                    (symbol, group_name),
                )
            else:
                conn.execute("delete from watchlist where symbol = ?", (symbol,))

    def list_watchlist(self, group_name: str | None = None) -> list[dict]:
        sql = """
            select w.symbol, coalesce(s.market, '') as market, coalesce(s.name, '') as name,
                   w.group_name, w.sort_order, w.note
            from watchlist w
            left join symbols s on s.symbol = w.symbol
        """
        params: tuple = ()
        if group_name:
            sql += " where w.group_name = ?"
            params = (group_name,)
        sql += " order by w.group_name, w.sort_order, w.symbol"
        with self._connection() as conn:
            rows = conn.execute(sql, params).fetchall()
        return [dict(row) for row in rows]

    def get_state(self, key: str) -> str | None:
        with self._connection() as conn:
            row = conn.execute("select value from app_state where key = ?", (key,)).fetchone()
        return row["value"] if row else None

    def set_state(self, key: str, value: str) -> None:
        with self._connection() as conn:
            conn.execute(
                """
                insert into app_state(key, value, updated_at)
                values(?, ?, ?)
                on conflict(key) do update set
                    value=excluded.value,
                    updated_at=excluded.updated_at
                """,
                (key, value, now_utc().isoformat()),
            )

    def cache_path(self, data_type: str, symbol: str = "", period: str = "", cache_key: str | None = None) -> Path:
        suffix = f"_{hashlib.sha1(cache_key.encode('utf-8')).hexdigest()[:12]}" if cache_key else ""
        if data_type == "kline_day":
            return self.root / "kline" / "day" / f"{symbol}{suffix}.parquet"
        if data_type == "kline_minute":
            return self.root / "kline" / "minute" / period / f"{symbol}{suffix}.parquet"
        if data_type == "money_flow":
            return self.root / "money_flow" / f"{symbol}.parquet"
        if data_type == "quote":
            return self.root / "quote" / f"{symbol or 'realtime'}.parquet"
        if data_type == "symbols":
            return self.root / "symbols" / "symbols.parquet"
        return self.root / data_type / f"{symbol or 'data'}.parquet"

    def write_frame(
        self,
        cache_key: str,
        data_type: str,
        frame: pd.DataFrame,
        source: str,
        symbol: str = "",
        period: str = "",
        ttl_seconds: int = 60,
        start_at: str | None = None,
        end_at: str | None = None,
    ) -> Path:
        path = self.cache_path(data_type, symbol, period, cache_key)
        path.parent.mkdir(parents=True, exist_ok=True)
        frame.to_parquet(path, index=False)
        with self._connection() as conn:
            conn.execute(
                """
                insert into cache_index(cache_key, data_type, symbol, period, path, source,
                                        start_at, end_at, updated_at, ttl_seconds)
                values(?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                on conflict(cache_key) do update set
                    path=excluded.path,
                    source=excluded.source,
                    start_at=excluded.start_at,
                    end_at=excluded.end_at,
                    updated_at=excluded.updated_at,
                    ttl_seconds=excluded.ttl_seconds
                """,
                (
                    cache_key,
                    data_type,
                    symbol,
                    period,
                    str(path),
                    source,
                    start_at,
                    end_at,
                    now_utc().isoformat(),
                    ttl_seconds,
                ),
            )
        return path

    def read_frame(self, cache_key: str, allow_stale: bool = True) -> tuple[pd.DataFrame, dict] | None:
        with self._connection() as conn:
            row = conn.execute(
                "select * from cache_index where cache_key = ?",
                (cache_key,),
            ).fetchone()
        if not row:
            return None
        meta = dict(row)
        path = Path(meta["path"])
        if not path.exists():
            return None
        updated_at = datetime.fromisoformat(meta["updated_at"])
        if updated_at.tzinfo is None:
            updated_at = updated_at.replace(tzinfo=timezone.utc)
        age = (now_utc() - updated_at).total_seconds()
        meta["stale"] = age > int(meta["ttl_seconds"])
        if meta["stale"] and not allow_stale:
            return None
        return pd.read_parquet(path), meta

    def clear(self, data_type: str | None = None, symbol: str | None = None) -> int:
        with self._connection() as conn:
            sql = "select cache_key, path from cache_index where 1=1"
            params: list[str] = []
            if data_type:
                sql += " and data_type = ?"
                params.append(data_type)
            if symbol:
                sql += " and symbol = ?"
                params.append(symbol)
            rows = conn.execute(sql, params).fetchall()
            for row in rows:
                path = Path(row["path"])
                if path.exists():
                    path.unlink()
                conn.execute("delete from cache_index where cache_key = ?", (row["cache_key"],))
        return len(rows)
