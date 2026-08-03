from __future__ import annotations

import json
import math
import threading
import time
from concurrent.futures import ThreadPoolExecutor
from dataclasses import asdict, dataclass, field
from datetime import date, timedelta

from backend.app.cache import CacheStore
from backend.app.config import Settings, get_settings
from backend.app.utils import now_utc

GROUP_STEP = 30.0  # 相邻两档间隔
GROUP_FINAL_BASE = 20.0  # 第 k 档"最后一天至少过"阈值 = 20 + 30*(k-1)
GROUP_PRE_OFFSET = 10.0  # "先过"线 = 阈值 - 10（第一档先过10%、第二档先过40%…）
MAX_GROUPS = 8
WINDOW_DAYS = 90
MIN_BARS = 20
OHLC_KEYS = ("open", "high", "low", "close")
ALLOWED_PREFIXES = ("60", "00")  # 仅沪深主板，排除创业板(30)/科创板(68)/北交所


def classify_group(pct: float | None) -> int | None:
    """按最新涨幅归档。一档须站上30确认：[30,40)；40是奇点，[40,50)不入档；
    二档及以上过主线即入：[50,70)、[80,100)、[110,130)…（上沿 = 下一主线−10 的奇点）；
    过渡区（70~80/100~110/…）与超250%不入档。"""
    if pct is None or pct < GROUP_FINAL_BASE + GROUP_PRE_OFFSET:  # <30：过20未站上30只是"站稳20"，不入档
        return None
    if pct < 40:
        return 1
    if pct < 50:
        return None  # 40是奇点：过了40、还没站上50（利欧 41.7%/600617 47.4% 场景）
    k = int(math.floor((pct - GROUP_FINAL_BASE) / GROUP_STEP)) + 1
    if k > MAX_GROUPS:
        return None
    offset = pct - group_threshold(k)
    if offset >= GROUP_STEP - GROUP_PRE_OFFSET:  # 到达下一奇点（主线+20）→ 过渡区
        return None
    return k


def group_entry_line(group: int) -> float:
    """入档线：一档需站上30确认，二档及以上过主线即入。"""
    return GROUP_FINAL_BASE + GROUP_PRE_OFFSET if group == 1 else group_threshold(group)


def group_threshold(group: int) -> float:
    return GROUP_FINAL_BASE + GROUP_STEP * (group - 1)


def is_falling_from_top(pct: float, max_pct: float, max_high_pct: float | None = None) -> bool:
    """异常回落判定（收回后自动恢复）：
    - 收盘曾站上的最高主线（20/50/80/…），现价跌破 → True；
    - 盘中曾冲过某奇点（40/70/100/…，用最高价判"冲高"），现价低于 奇点−10（30/60/90/…）→ True。
    例：闰土冲高71.7%（过70奇点）回落到56.8%（<60）→ True；紫光峰值79.9现66（≥60）→ False。"""
    if max_high_pct is None:
        max_high_pct = max_pct
    floor = None
    for j in range(1, MAX_GROUPS + 1):
        main = group_threshold(j)
        singular = main + GROUP_STEP - GROUP_PRE_OFFSET  # 40/70/100/…
        if max_pct >= main:
            floor = main if floor is None else max(floor, main)
        if max_high_pct >= singular:
            level = singular - GROUP_PRE_OFFSET  # 30/60/90/…
            floor = level if floor is None else max(floor, level)
    if floor is None:
        return False
    return pct < floor


def is_north_bound(window: list[dict], low_index: int) -> bool:
    """一路北上：90日整体向上——波段低点在窗口前1/3、最高点在窗口后1/3，中间回落不限。"""
    n = len(window)
    if n < 3:
        return False
    high_index = max(range(n), key=lambda i: float(window[i]["high"]))
    return low_index <= (n - 1) / 3 and high_index >= (n - 1) * 2 / 3


def is_limit_up(price: float | None, pre_close: float | None, ratio: float = 1.1) -> bool:
    """主板涨停判定：现价（收盘后即收盘价）等于 round(昨收×1.1, 2)。ST 已被排除，不考虑 5% 档。"""
    if price is None or pre_close is None or pre_close <= 0:
        return False
    return abs(float(price) - round(float(pre_close) * ratio, 2)) < 0.001


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
    """90日波段（低点→现在）分档：一档须站上30确认[30,40)，40是奇点；
    二档及以上过主线即入（[50,70)、[80,100)…）。低点不区分反转/起点（V型不排除）。
    from_top（跌破曾站上的主线且未收回）只打标记，由展示层开关决定是否显示。"""
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

    low_index = min(range(len(window)), key=lambda i: float(window[i]["low"]))
    low90 = float(window[low_index]["low"])
    if low90 <= 0:
        return None
    if low_index >= len(window) - 1:
        return None  # 低点就是最后一天，没有"低点→高点"的波段

    pct = (float(price) / low90 - 1) * 100
    group = classify_group(pct)
    if group is None:
        return None

    closes_after_low = [float(bar["close"]) for bar in window[low_index:] if bar.get("close") is not None]
    max_pct = max([(c / low90 - 1) * 100 for c in closes_after_low] + [pct])
    highs_after_low = [float(bar["high"]) for bar in window[low_index:] if bar.get("high") is not None]
    max_high_pct = max([(h / low90 - 1) * 100 for h in highs_after_low] + [pct])
    # 异常回落只打标记，由展示层筛选开关决定是否显示（收回后标记自动消失）
    from_top = is_falling_from_top(pct, max_pct, max_high_pct)
    north = is_north_bound(window, low_index)

    threshold = group_threshold(group)
    entry_level = low90 * (1 + group_entry_line(group) / 100)

    cross_date = None
    for bar in window[low_index + 1 :]:
        close = bar.get("close")
        if close is not None and float(close) >= entry_level:
            cross_date = str(bar["time"])[:10]
            break
    if cross_date is None:
        cross_date = str(window[-1]["time"])[:10]  # 只有今日盘中价过线

    return {
        "symbol": symbol,
        "name": name,
        "price": float(price),
        "low90": round(low90, 3),
        "pct": round(pct, 2),
        "group": group,
        "threshold": threshold,
        "over": round(pct - threshold, 2),
        "max_pct": round(max_pct, 2),
        "low_date": str(window[low_index]["time"])[:10],
        "cross_date": cross_date,
        "from_top": from_top,
        "north_ok": north,
    }


STATE_KEY = "moneygrab:last_scan:v8"  # v8: 命中行含 north_ok（一路北上）标记


def _default_fundamentals_enricher(cache: CacheStore, hits: list[dict], caps: dict) -> None:
    from backend.app.fundamentals import FundamentalsFetcher

    FundamentalsFetcher(cache).enrich(hits, caps)


def _default_lon_enricher(cache: CacheStore, hits: list[dict]) -> None:
    from backend.app.lon_check import LonChecker

    LonChecker(cache).enrich(hits)


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
    min_market_cap: float | None = None  # 亿元；None = 不过滤
    limit_up_only: bool = False  # True = 只要最后一天（今日）涨停的


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
        for attempt in range(3):  # 瞬时限流重试，静默丢批会导致残缺名单
            try:
                frame = adapter.realtime_quotes(batch)
                if frame is not None and not frame.empty:
                    return frame.to_dict("records")
            except Exception:
                pass
            time.sleep(0.5 * (attempt + 1))
        return []

    records: list[dict] = []
    with ThreadPoolExecutor(max_workers=workers) as pool:
        for rows in pool.map(fetch_batch, _chunk(symbols, batch_size)):
            records.extend(rows)
    if len(records) < len(symbols) * 0.5:
        raise RuntimeError(f"tencent quotes incomplete: {len(records)}/{len(symbols)}")
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


def _daily_bars_too_old(bars: list[dict], max_lag_days: int = 4) -> bool:
    """缓存最新一根K线距今超过 max_lag_days 自然日则重拉该股（覆盖周末+小长假内的滞后）。"""
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
        fundamentals_enricher=None,
        lon_enricher=None,
    ):
        self.settings = settings
        self.max_workers = max_workers
        self._quote_fetcher = quote_fetcher or (lambda: _fetch_all_a_quotes(self.settings))
        self._kline_fetcher = kline_fetcher  # None 时在 _run 内用 MarketService
        self._fundamentals_enricher = fundamentals_enricher or _default_fundamentals_enricher
        self._lon_enricher = lon_enricher or _default_lon_enricher
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

    def start(
        self,
        refresh: bool = False,
        min_market_cap: float | None = None,
        limit_up_only: bool = False,
    ) -> dict:
        with self._lock:
            if self._state.status == "running":
                return asdict(self._state)
            self._state = ScanState(
                status="running",
                stage="snapshot",
                started_at=now_utc().isoformat(),
                trade_date=now_utc().date().isoformat(),
                min_market_cap=min_market_cap,
                limit_up_only=limit_up_only,
            )
            self._thread = threading.Thread(
                target=self._run, args=(refresh, min_market_cap, limit_up_only), daemon=True
            )
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

    def _run(self, refresh: bool, min_market_cap: float | None = None, limit_up_only: bool = False) -> None:
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
                and (
                    min_market_cap is None
                    or (quote.get("market_cap") is not None and float(quote["market_cap"]) >= min_market_cap)
                )
                and (not limit_up_only or is_limit_up(quote.get("price"), quote.get("pre_close")))
            ]
            with self._lock:
                self._state.total = len(candidates)
                self._state.stage = "kline"

            def work(quote: dict) -> dict | None:
                for _ in range(2):  # 缓存写锁等瞬时失败重试一次
                    try:
                        bars = fetch_bars(str(quote["symbol"]))
                        row = evaluate_stock(
                            str(quote["symbol"]), str(quote.get("name", "")), quote.get("price"), bars
                        )
                        if row is not None:
                            row["limit_up"] = is_limit_up(quote.get("price"), quote.get("pre_close"))
                        return row
                    except Exception:
                        continue
                return None

            with ThreadPoolExecutor(max_workers=self.max_workers) as pool:
                for row in pool.map(work, candidates):
                    with self._lock:
                        self._state.done += 1
                        if row is not None:
                            self._state.hits.append(row)

            # 基本面标记（分红/净利润）：只查命中股，缓存3天；失败不影响扫描结果
            with self._lock:
                self._state.stage = "fundamentals"
                hits_snapshot = list(self._state.hits)
            try:
                caps = {
                    str(quote.get("symbol", "")): quote.get("market_cap")
                    for quote in candidates
                }
                self._fundamentals_enricher(cache, hits_snapshot, caps)
            except Exception:
                pass
            for row in hits_snapshot:
                row.setdefault("dividend_recent", False)
                row.setdefault("profit_ok", False)
                row.setdefault("revenue_ok", False)

            with self._lock:
                self._state.stage = "lon"
            try:
                self._lon_enricher(cache, hits_snapshot)
            except Exception:
                pass
            for row in hits_snapshot:
                row.setdefault("lon_ok", False)

            with self._lock:
                self._state.hits.sort(key=lambda item: (item["group"], -item["over"]))
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
