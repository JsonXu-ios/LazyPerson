from __future__ import annotations

import json
import math
import threading
from concurrent.futures import ThreadPoolExecutor
from dataclasses import asdict, dataclass, field
from datetime import date, timedelta

from backend.app.cache import CacheStore
from backend.app.config import Settings, get_settings
from backend.app.utils import now_utc

BAND_STEP = 20.0
BAND_MARGIN = 10.0
WINDOW_DAYS = 90
MIN_BARS = 20
OHLC_KEYS = ("open", "high", "low", "close")
ALLOWED_PREFIXES = ("60", "00", "30", "68")


def band_position(pct: float | None) -> tuple[float, float] | None:
    """返回 (档位下沿, 超出中线幅度)；不命中返回 None。命中条件：pct - band > BAND_MARGIN。"""
    if pct is None or pct < 0:
        return None
    band = math.floor(pct / BAND_STEP) * BAND_STEP
    over = pct - band - BAND_MARGIN
    if over <= 0:
        return None
    return band, over


def eligible_symbol(symbol: str, name: str) -> bool:
    clean = (symbol or "").strip()
    if not clean.startswith(ALLOWED_PREFIXES):
        return False
    if "ST" in (name or "").upper():
        return False
    return True


def _bar_date(bar: dict) -> date | None:
    raw = str(bar.get("time") or "")[:10]
    try:
        return date.fromisoformat(raw)
    except ValueError:
        return None


def _valid_bars(bars: list[dict]) -> list[dict]:
    result = []
    for bar in bars:
        day = _bar_date(bar)
        if day is None or day.weekday() >= 5:
            continue
        if any(bar.get(key) is None for key in OHLC_KEYS):
            continue
        result.append(bar)
    return result


def slice_calendar_window(bars: list[dict], days: int = WINDOW_DAYS) -> list[dict]:
    valid = _valid_bars(bars)
    if not valid:
        return []
    latest = _bar_date(valid[-1])
    cutoff = latest - timedelta(days=days)
    return [bar for bar in valid if _bar_date(bar) >= cutoff]


def evaluate_stock(
    symbol: str,
    name: str,
    price: float | None,
    bars: list[dict],
    today: date | None = None,
) -> dict | None:
    if price is None:
        return None
    today = today or date.today()
    valid = _valid_bars(bars)
    if len(valid) < MIN_BARS:
        return None
    first_day = _bar_date(valid[0])
    if first_day > today - timedelta(days=WINDOW_DAYS):
        return None
    window = slice_calendar_window(valid, WINDOW_DAYS)
    if not window:
        return None
    low90 = min(float(bar["low"]) for bar in window)
    if low90 <= 0:
        return None
    pct = (float(price) / low90 - 1) * 100
    position = band_position(pct)
    if position is None:
        return None
    band, over = position
    return {
        "symbol": symbol,
        "name": name,
        "price": float(price),
        "low90": round(low90, 3),
        "pct": round(pct, 2),
        "band": band,
        "over": round(over, 2),
    }


STATE_KEY = "moneygrab:last_scan"


@dataclass
class ScanState:
    status: str = "idle"  # idle | running | done | failed
    stage: str = ""  # snapshot | kline | ""
    total: int = 0
    done: int = 0
    hits: list[dict] = field(default_factory=list)
    started_at: str | None = None
    finished_at: str | None = None
    error: str | None = None
    trade_date: str | None = None


def _chunk(items: list, size: int) -> list[list]:
    return [items[index : index + size] for index in range(0, len(items), size)]


def _local_a_symbols(cache: CacheStore) -> list[str]:
    """本地 symbols 表中的沪深A股代码（东方财富不可达时的清单来源）。"""
    rows = cache.search_symbols("", limit=20000)
    return [
        row["symbol"]
        for row in rows
        if str(row.get("symbol", "")).isdigit() and str(row["symbol"]).startswith(ALLOWED_PREFIXES)
    ]


def _fetch_a_quotes_via_tencent(settings: Settings, batch_size: int = 80, workers: int = 6) -> list[dict]:
    """腾讯行情兜底：本地清单分批并发拉全市场快照。"""
    from backend.app.providers.tencent_adapter import TencentAdapter

    symbols = _local_a_symbols(CacheStore(settings))
    if not symbols:
        raise RuntimeError("local symbol list is empty; refresh /api/symbols/search first")
    adapter = TencentAdapter()

    def fetch_batch(batch: list[str]) -> list[dict]:
        try:
            frame = adapter.realtime_quotes(batch)
            if frame is not None and not frame.empty:
                return frame.to_dict("records")
        except Exception:
            pass
        return []

    records: list[dict] = []
    with ThreadPoolExecutor(max_workers=workers) as pool:
        for rows in pool.map(fetch_batch, _chunk(symbols, batch_size)):
            records.extend(rows)
    if not records:
        raise RuntimeError("tencent quotes returned no rows")
    return records


QUOTE_SOURCE_KEY = "moneygrab:quote_source"


def _daily_cache_key(symbol: str, adjust: str) -> str:
    """与 MarketService.kline 的 day 缓存键完全一致（start/end 为空）。"""
    return f"kline_day:{symbol}:day:{adjust}::"


def _cached_daily_bars(
    cache: CacheStore,
    symbol: str,
    adjust: str,
    ttl_seconds: int,
    refresh: bool,
    fetch_remote,
) -> list[dict]:
    cache_key = _daily_cache_key(symbol, adjust)
    if not refresh:
        cached = cache.read_frame(cache_key, allow_stale=True)
        if cached:
            frame, _meta = cached
            bars = frame.to_dict("records")
            if bars and not _daily_bars_too_old(bars):
                return bars
    frame = fetch_remote(symbol)
    if frame is None or frame.empty:
        return []
    cache.write_frame(
        cache_key=cache_key,
        data_type="kline_day",
        frame=frame,
        source="tencent",
        symbol=symbol,
        period="day",
        ttl_seconds=ttl_seconds,
        start_at=str(frame.iloc[0].get("time", "")),
        end_at=str(frame.iloc[-1].get("time", "")),
    )
    return frame.to_dict("records")


def _daily_bars_too_old(bars: list[dict], max_lag_days: int = 14) -> bool:
    last = _bar_date(bars[-1])
    if last is None:
        return True
    return (date.today() - last).days > max_lag_days


def _fetch_quotes_from(source: str, settings: Settings) -> list[dict]:
    if source == "tencent":
        return _fetch_a_quotes_via_tencent(settings)
    if source == "efinance":
        from backend.app.providers.efinance_adapter import EFinanceAdapter

        frame = EFinanceAdapter().realtime_quotes([])
    else:
        from backend.app.providers.akshare_adapter import AKShareAdapter

        frame = AKShareAdapter().realtime_quotes([])
    if frame is None or frame.empty:
        raise RuntimeError("empty snapshot")
    return frame.to_dict("records")


def _fetch_all_a_quotes(settings: Settings) -> list[dict]:
    """全市场A股快照：efinance / akshare / 腾讯分批。记住上次成功的源，下次优先用它（东财超时很贵）。"""
    cache = CacheStore(settings)
    order = ["efinance", "akshare", "tencent"]
    preferred = cache.get_state(QUOTE_SOURCE_KEY)
    if preferred in order:
        order.remove(preferred)
        order.insert(0, preferred)
    errors: list[str] = []
    for source in order:
        try:
            records = _fetch_quotes_from(source, settings)
            if records:
                cache.set_state(QUOTE_SOURCE_KEY, source)
                return records
        except Exception as exc:
            errors.append(f"{source}:{exc}")
    raise RuntimeError("; ".join(errors) or "no quote source available")


class MoneyGrabScanner:
    def __init__(
        self,
        settings: Settings,
        quote_fetcher=None,
        kline_fetcher=None,
        max_workers: int = 16,
    ):
        self.settings = settings
        self.max_workers = max_workers
        self._quote_fetcher = quote_fetcher or (lambda: _fetch_all_a_quotes(self.settings))
        self._kline_fetcher = kline_fetcher  # None 时在 _run 内用 MarketService
        self._lock = threading.Lock()
        self._state = ScanState()
        self._thread: threading.Thread | None = None

    def status(self) -> dict:
        with self._lock:
            if self._state.status == "idle":
                restored = self._load_persisted()
                if restored is not None:
                    self._state = restored
            return asdict(self._state)

    def start(self, refresh: bool = False) -> dict:
        with self._lock:
            if self._state.status == "running":
                return asdict(self._state)
            self._state = ScanState(
                status="running",
                stage="snapshot",
                started_at=now_utc().isoformat(),
                trade_date=now_utc().date().isoformat(),
            )
            self._thread = threading.Thread(target=self._run, args=(refresh,), daemon=True)
            self._thread.start()
            return asdict(self._state)

    def _default_kline_fetcher(self, cache: CacheStore, refresh: bool):
        """扫描专用：本地缓存 → 腾讯（15s 超时）。不走 efinance/akshare 降级链，
        东财不可达时它们的内部长超时会把工作线程全部拖死。缓存键与 MarketService 一致，互相复用。"""
        from backend.app.providers.tencent_adapter import TencentAdapter

        adjust = self.settings.default_adjust
        adapter = TencentAdapter()

        def fetch_remote(symbol: str):
            start = (now_utc().date() - timedelta(days=420)).isoformat()
            return adapter.kline(symbol, "day", start, None, adjust)

        def fetch(symbol: str) -> list[dict]:
            return _cached_daily_bars(cache, symbol, adjust, self.settings.day_ttl_seconds, refresh, fetch_remote)

        return fetch

    def _run(self, refresh: bool) -> None:
        try:
            cache = CacheStore(self.settings)
            fetch_bars = self._kline_fetcher
            if fetch_bars is None:
                fetch_bars = self._default_kline_fetcher(cache, refresh)

            quotes = self._quote_fetcher()
            candidates = [
                quote
                for quote in quotes
                if eligible_symbol(str(quote.get("symbol", "")), str(quote.get("name", "")))
                and quote.get("price") is not None
            ]
            with self._lock:
                self._state.total = len(candidates)
                self._state.stage = "kline"

            def work(quote: dict) -> dict | None:
                for _ in range(2):  # 缓存写锁等瞬时失败重试一次
                    try:
                        bars = fetch_bars(str(quote["symbol"]))
                        return evaluate_stock(
                            str(quote["symbol"]), str(quote.get("name", "")), quote.get("price"), bars
                        )
                    except Exception:
                        continue
                return None

            with ThreadPoolExecutor(max_workers=self.max_workers) as pool:
                for row in pool.map(work, candidates):
                    with self._lock:
                        self._state.done += 1
                        if row is not None:
                            self._state.hits.append(row)

            with self._lock:
                self._state.hits.sort(key=lambda item: item["over"], reverse=True)
                self._state.status = "done"
                self._state.stage = ""
                self._state.finished_at = now_utc().isoformat()
                cache.set_state(STATE_KEY, json.dumps(asdict(self._state), ensure_ascii=False))
        except Exception as exc:
            with self._lock:
                self._state.status = "failed"
                self._state.error = str(exc)
                self._state.finished_at = now_utc().isoformat()

    def _load_persisted(self) -> ScanState | None:
        try:
            raw = CacheStore(self.settings).get_state(STATE_KEY)
            if not raw:
                return None
            data = json.loads(raw)
            if data.get("trade_date") != now_utc().date().isoformat():
                return None
            return ScanState(**data)
        except Exception:
            return None


_scanner: MoneyGrabScanner | None = None
_scanner_guard = threading.Lock()


def get_scanner() -> MoneyGrabScanner:
    global _scanner
    with _scanner_guard:
        if _scanner is None:
            _scanner = MoneyGrabScanner(get_settings())
        return _scanner
