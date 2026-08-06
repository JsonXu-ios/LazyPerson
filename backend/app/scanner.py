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

GROUP_STEP = 30.0  # 相邻两档间隔（二档起）
GROUP_FINAL_BASE = 20.0  # 一档下沿
GROUP_PRE_OFFSET = 10.0
# 八档分界：一档 [20,40)，之后每 30 一档，分界线 = K线主线(20/50/80/110…) − 10
GROUP_LOWER = (20.0, 40.0, 70.0, 100.0, 130.0, 160.0, 190.0, 220.0)
NORTH_MAX_DRAWDOWN = 0.30  # 一路北上允许的最大回撤（收盘口径）
MAX_GROUPS = len(GROUP_LOWER)
WINDOW_DAYS = 90
MIN_BARS = 20
OHLC_KEYS = ("open", "high", "low", "close")
ALLOWED_PREFIXES = ("60", "00")  # 仅沪深主板，排除创业板(30)/科创板(68)/北交所


def classify_group(pct: float | None) -> int | None:
    """按最新收盘涨幅归档，档位分界 20/40/70/100/130/160/190/220：
    一档 [20,40)、二档 [40,70)、三档 [70,100)…八档 [220,∞)。
    过 40% 即从一档剔除、升为二档（"快到下一条主线"就升档）。"""
    if pct is None or pct < GROUP_LOWER[0]:
        return None
    group = 1
    for index, lower in enumerate(GROUP_LOWER, start=1):
        if pct >= lower:
            group = index
    return group


def is_falling_back(pct: float | None, max_pct: float | None) -> bool:
    """回落判定：历史收盘最高档高于当前档 → 是从更高档掉下来的，不算当前档。
    例：冲到 45%（二档）后回落到 35%（一档区间）→ True，要重新站上 40% 才以二档出现。"""
    current = classify_group(pct)
    peak = classify_group(max_pct)
    if current is None or peak is None:
        return False
    return peak > current


def group_threshold(group: int) -> float:
    """档位下沿（入档线）。"""
    return GROUP_LOWER[max(1, min(group, MAX_GROUPS)) - 1]


def is_north_bound(window: list[dict], low_index: int, max_drawdown: float = NORTH_MAX_DRAWDOWN) -> bool:
    """一路北上：从低到高——最高点出现在波段低点之后（排除"先见高点再跌下来反弹"），
    且低点之后的震荡回落（收盘口径最大回撤）不超过 max_drawdown（默认30%）。"""
    n = len(window)
    if n < 3:
        return False
    high_index = max(range(n), key=lambda i: float(window[i]["high"]))
    if high_index <= low_index:
        return False
    peak: float | None = None
    for bar in window[low_index:]:
        close = bar.get("close")
        if close is None:
            continue
        value = float(close)
        if peak is None or value > peak:
            peak = value
        elif peak > 0 and (peak - value) / peak > max_drawdown:
            return False  # 中间回撤超过阈值，不算一路向北
    return True


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


def recent_change(price: float, window: list[dict], days: int, today: date | None = None) -> float | None:
    """近 days 个交易日涨幅%：现价 / days 个交易日前的收盘 − 1。数据不足返回 None。
    窗口最后一根若就是今天，基准取 closes[-(days+1)]，否则取 closes[-days]。"""
    closes = [float(bar["close"]) for bar in window if bar.get("close") is not None]
    if not closes:
        return None
    today = today or date.today()
    last_is_today = _bar_date(window[-1]) == today
    offset = days + 1 if last_is_today else days
    if len(closes) < offset:
        return None
    base = closes[-offset]
    if base <= 0:
        return None
    return (price / base - 1) * 100


def evaluate_stock(
    symbol: str,
    name: str,
    price: float | None,
    bars: list[dict],
    today: date | None = None,
    turnover: float | None = None,
) -> dict | None:
    """90日波段（低点→现在）分档：档位分界 20/40/70/100/130/160/190/220，
    一档[20,40)、二档[40,70)、三档[70,100)…八档[220,∞)。低点不区分反转/起点。
    from_top（历史最高档高于当前档＝从更高档回落）只打标记，由展示层开关决定是否显示。"""
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
    # 回落只打标记，由展示层开关决定是否显示（重新站上该档下沿即自动恢复）
    from_top = is_falling_back(pct, max_pct)
    north = is_north_bound(window, low_index)

    threshold = group_threshold(group)
    entry_level = low90 * (1 + threshold / 100)

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
        "turnover": turnover,
        "chg3": _round_or_none(recent_change(float(price), window, 3, today)),
        "chg5": _round_or_none(recent_change(float(price), window, 5, today)),
    }


def _round_or_none(value: float | None) -> float | None:
    return None if value is None else round(value, 2)


STATE_KEY = "moneygrab:last_scan:v12"  # v12: 命中行含 turnover/chg3/chg5


def _default_fundamentals_enricher(cache: CacheStore, hits: list[dict], caps: dict) -> None:
    from backend.app.fundamentals import FundamentalsFetcher

    FundamentalsFetcher(cache).enrich(hits, caps)


def _default_lon_enricher(cache: CacheStore, hits: list[dict]) -> None:
    from backend.app.lon_check import LonChecker

    LonChecker(cache).enrich(hits)


def _default_sector_enricher(cache: CacheStore, hits: list[dict], hot_top: int = 15) -> None:
    """给命中行补 industry / concepts / hot_sector（所属概念在今日涨幅前 hot_top 之内）。"""
    from backend.app.industry import IndustryService
    from backend.app.sectors import SectorService

    service = IndustryService(cache)
    industries, _ = service.industry_map()
    concept_map, _ = service.concept_map()
    hot_names: set[str] = set()
    try:
        boards, _ = SectorService(cache).hot_boards(limit=hot_top)
        hot_names = {board["name"] for board in boards.get("concepts", [])}
    except Exception:
        pass
    for row in hits:
        symbol = row["symbol"]
        concepts = concept_map.get(symbol, [])
        row["industry"] = industries.get(symbol, "")
        row["concepts"] = concepts[:6]
        row["hot_sector"] = any(name in hot_names for name in concepts)


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
        sector_enricher=None,
    ):
        self.settings = settings
        self.max_workers = max_workers
        self._quote_fetcher = quote_fetcher or (lambda: _fetch_all_a_quotes(self.settings))
        self._kline_fetcher = kline_fetcher  # None 时在 _run 内用 MarketService
        self._fundamentals_enricher = fundamentals_enricher or _default_fundamentals_enricher
        self._lon_enricher = lon_enricher or _default_lon_enricher
        self._sector_enricher = sector_enricher or _default_sector_enricher
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
                            str(quote["symbol"]),
                            str(quote.get("name", "")),
                            quote.get("price"),
                            bars,
                            turnover=quote.get("turnover"),
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
                self._state.stage = "sector"
            try:
                self._sector_enricher(cache, hits_snapshot)
            except Exception:
                pass
            for row in hits_snapshot:
                row.setdefault("industry", "")
                row.setdefault("concepts", [])
                row.setdefault("hot_sector", False)

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
