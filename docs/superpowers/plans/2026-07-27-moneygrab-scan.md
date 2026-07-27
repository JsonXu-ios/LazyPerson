# 抢钱流（全A股档位扫描）实现计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 扫描全A股，找出当前价处于 20% 主档位区间上半段（超过区间下沿 10% 以上）的股票，前端抽屉面板展示结果。

**Architecture:** 后端新增 `backend/app/scanner.py`：纯函数筛选逻辑 + 后台线程扫描任务（内存单例状态 + SQLite app_state 持久化当天结果），`main.py` 加两个路由（启动扫描 / 查询状态）。前端新增 `MoneyGrabPanel.tsx` 抽屉面板，轮询进度并展示命中表格。

**Tech Stack:** FastAPI + pandas + efinance/akshare（全市场快照）、复用 `MarketService.kline` 多源缓存；React + TypeScript（Vite）。

**Spec:** `docs/superpowers/specs/2026-07-27-moneygrab-scan-design.md`

## Global Constraints

- 筛选公式：`pct = (最新价 / low90 − 1) × 100`；`band = floor(pct / 20) × 20`；命中条件 `pct − band > 10`（严格大于）；`pct < 0` 不命中。
- `low90` = 近 90 自然日窗口内所有日线 bar 的最低 `low`（窗口切法与前端 `sliceDailyPayloadByCalendarDays` 一致：以最后一根 bar 日期为基准往前 90 自然日，剔除周末与 OHLC 缺失的 bar）。
- 排除：北交所（只保留 60/00/30/68 开头）、名称含 "ST"、上市不足 90 天（最早一根 bar 晚于今日−90天）、无最新价、有效日线不足 20 根。
- 后端测试命令：`python -m pytest tests/ -v`（在仓库根目录 `d:\JsonXu\LazyPerson` 运行）。
- 前端验证命令：`npm run build`（在 `frontend/` 目录运行）。
- 提交信息用中文，格式 `feat: ...` / `test: ...`，结尾带 `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`。

---

### Task 1: 筛选纯函数（scanner.py 核心逻辑）

**Files:**
- Create: `backend/app/scanner.py`
- Create: `tests/test_scanner.py`

**Interfaces:**
- Produces（后续 Task 依赖的确切签名）:
  - `band_position(pct: float | None) -> tuple[float, float] | None` — 返回 `(band, over)`，`over = pct - band - 10`；不命中返回 `None`
  - `slice_calendar_window(bars: list[dict], days: int = 90) -> list[dict]`
  - `eligible_symbol(symbol: str, name: str) -> bool`
  - `evaluate_stock(symbol: str, name: str, price: float | None, bars: list[dict], today: date | None = None) -> dict | None` — 命中返回 `{"symbol","name","price","low90","pct","band","over"}`，否则 `None`

- [ ] **Step 1: 写失败测试**

创建 `tests/test_scanner.py`：

```python
from datetime import date, timedelta

from backend.app.scanner import (
    band_position,
    eligible_symbol,
    evaluate_stock,
    slice_calendar_window,
)


def make_bars(days: int, low: float, today: date | None = None) -> list[dict]:
    """生成 days 个自然日内的工作日日线，最低价为 low（放在最早一根），其余 low*1.05。"""
    today = today or date(2026, 7, 24)  # 周五
    bars = []
    for offset in range(days, -1, -1):
        day = today - timedelta(days=offset)
        if day.weekday() >= 5:
            continue
        value = low if offset == days or (day.weekday() < 5 and not bars) else low * 1.05
        bars.append(
            {
                "time": day.isoformat(),
                "open": value,
                "high": value * 1.02,
                "low": value,
                "close": value * 1.01,
            }
        )
    return bars


class TestBandPosition:
    def test_pct_10_not_hit(self):
        assert band_position(10.0) is None

    def test_pct_just_above_10_hits_band_0(self):
        band, over = band_position(10.5)
        assert band == 0
        assert round(over, 2) == 0.5

    def test_pct_30_boundary_not_hit(self):
        assert band_position(30.0) is None

    def test_pct_31_hits_band_20(self):
        band, over = band_position(31.0)
        assert band == 20
        assert round(over, 2) == 1.0

    def test_pct_155_hits_band_140(self):
        band, over = band_position(155.0)
        assert band == 140
        assert round(over, 2) == 5.0

    def test_negative_pct_not_hit(self):
        assert band_position(-3.0) is None

    def test_none_not_hit(self):
        assert band_position(None) is None


class TestEligibleSymbol:
    def test_sh_sz_prefixes_ok(self):
        for symbol in ["600519", "000001", "300750", "688981"]:
            assert eligible_symbol(symbol, "正常股")

    def test_beijing_excluded(self):
        assert not eligible_symbol("430047", "北交所股")
        assert not eligible_symbol("830799", "北交所股")

    def test_st_excluded(self):
        assert not eligible_symbol("600519", "ST 某某")
        assert not eligible_symbol("600519", "*ST某某")
        assert not eligible_symbol("600519", "st某某")


class TestSliceCalendarWindow:
    def test_window_cuts_by_calendar_days(self):
        bars = make_bars(200, 10.0)
        window = slice_calendar_window(bars, 90)
        first = date.fromisoformat(window[0]["time"])
        last = date.fromisoformat(window[-1]["time"])
        assert (last - first).days <= 90
        assert window[-1]["time"] == bars[-1]["time"]

    def test_drops_bars_with_missing_ohlc(self):
        bars = make_bars(30, 10.0)
        bars[5]["close"] = None
        window = slice_calendar_window(bars, 90)
        assert all(bar["close"] is not None for bar in window)


class TestEvaluateStock:
    today = date(2026, 7, 24)

    def test_hit_returns_row(self):
        # low90=10（在窗口内），价格 13.1 → pct=31% → band=20，over=1
        bars = make_bars(200, 10.0, self.today)
        # 把最低价放进 90 天窗口内
        bars[-3]["low"] = 10.0
        row = evaluate_stock("600001", "测试股", 13.1, bars, today=self.today)
        assert row is not None
        assert row["band"] == 20.0
        assert row["low90"] == 10.0
        assert round(row["pct"], 1) == 31.0

    def test_not_hit_returns_none(self):
        bars = make_bars(200, 10.0, self.today)
        bars[-3]["low"] = 10.0
        # 价格 12.5 → pct=25% → 区间下半段，不命中
        assert evaluate_stock("600001", "测试股", 12.5, bars, today=self.today) is None

    def test_new_stock_excluded(self):
        bars = make_bars(60, 10.0, self.today)  # 上市仅 60 天
        assert evaluate_stock("600001", "新股", 13.1, bars, today=self.today) is None

    def test_no_price_excluded(self):
        bars = make_bars(200, 10.0, self.today)
        assert evaluate_stock("600001", "停牌股", None, bars, today=self.today) is None

    def test_too_few_bars_excluded(self):
        bars = make_bars(200, 10.0, self.today)[:10]
        assert evaluate_stock("600001", "测试股", 13.1, bars, today=self.today) is None
```

- [ ] **Step 2: 运行确认失败**

Run: `python -m pytest tests/test_scanner.py -v`
Expected: FAIL（`ModuleNotFoundError: backend.app.scanner` 或 ImportError）

- [ ] **Step 3: 最小实现**

创建 `backend/app/scanner.py`：

```python
from __future__ import annotations

import math
from datetime import date, timedelta

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
```

- [ ] **Step 4: 运行确认通过**

Run: `python -m pytest tests/test_scanner.py -v`
Expected: 全部 PASS

- [ ] **Step 5: 提交**

```bash
git add backend/app/scanner.py tests/test_scanner.py
git commit -m "feat: 抢钱流档位筛选纯函数与测试"
```

---

### Task 2: 扫描任务（后台线程 + 进度 + 当天结果持久化）

**Files:**
- Modify: `backend/app/scanner.py`（追加）
- Modify: `tests/test_scanner.py`（追加）

**Interfaces:**
- Consumes: Task 1 的 `eligible_symbol` / `evaluate_stock`；`backend.app.cache.CacheStore`（`get_state`/`set_state`）；`backend.app.services.MarketService.kline`；`backend.app.providers.efinance_adapter.EFinanceAdapter.realtime_quotes([])`（空列表 = 返回全市场快照，见 efinance_adapter.py:24-30）
- Produces:
  - `class MoneyGrabScanner:`
    - `__init__(self, settings, quote_fetcher=None, kline_fetcher=None, max_workers=8)` — 两个 fetcher 参数用于测试注入：`quote_fetcher() -> list[dict]`（每项含 symbol/name/price），`kline_fetcher(symbol: str) -> list[dict]`（返回日线 bars）
    - `start(self, refresh: bool = False) -> dict` — 幂等；running 时直接返回当前状态
    - `status(self) -> dict` — 返回 `{"status","total","done","hits","started_at","finished_at","error","trade_date"}`；idle 时尝试加载当天持久化结果
  - `get_scanner() -> MoneyGrabScanner` — 模块级单例

- [ ] **Step 1: 写失败测试**

在 `tests/test_scanner.py` 追加（文件顶部补充 import）：

```python
import json
import time

from backend.app.config import Settings
from backend.app.scanner import MoneyGrabScanner
```

```python
def make_settings(tmp_path) -> Settings:
    return Settings(cache_dir=tmp_path / "cache", sqlite_path=tmp_path / "cache" / "app.db")


class TestMoneyGrabScanner:
    today = date(2026, 7, 24)

    def _fetchers(self):
        quotes = [
            {"symbol": "600001", "name": "命中股", "price": 13.1},   # pct=31% 命中
            {"symbol": "600002", "name": "未中股", "price": 12.5},   # pct=25% 不命中
            {"symbol": "430047", "name": "北交所", "price": 13.1},   # 排除
            {"symbol": "600003", "name": "ST某某", "price": 13.1},  # 排除
        ]
        bars = make_bars(200, 10.0, self.today)
        bars[-3]["low"] = 10.0
        return (lambda: quotes), (lambda symbol: bars)

    def _wait_done(self, scanner, timeout=5.0):
        deadline = time.time() + timeout
        while time.time() < deadline:
            state = scanner.status()
            if state["status"] in ("done", "failed"):
                return state
            time.sleep(0.05)
        raise AssertionError("scan did not finish in time")

    def test_scan_filters_and_reports_progress(self, tmp_path):
        quote_fetcher, kline_fetcher = self._fetchers()
        scanner = MoneyGrabScanner(
            make_settings(tmp_path), quote_fetcher=quote_fetcher, kline_fetcher=kline_fetcher, max_workers=2
        )
        state = scanner.start()
        assert state["status"] in ("running", "done")  # 小数据集可能瞬间扫完
        state = self._wait_done(scanner)
        assert state["status"] == "done"
        assert state["total"] == 2  # 北交所与 ST 在候选阶段就被排除
        assert state["done"] == 2
        assert [hit["symbol"] for hit in state["hits"]] == ["600001"]
        assert state["hits"][0]["band"] == 20.0

    def test_start_is_idempotent_while_running(self, tmp_path):
        quote_fetcher, kline_fetcher = self._fetchers()

        def slow_kline(symbol):
            time.sleep(0.3)
            return kline_fetcher(symbol)

        scanner = MoneyGrabScanner(
            make_settings(tmp_path), quote_fetcher=quote_fetcher, kline_fetcher=slow_kline, max_workers=1
        )
        scanner.start()
        second = scanner.start()
        assert second["status"] == "running"
        self._wait_done(scanner)

    def test_result_persisted_and_restored(self, tmp_path):
        quote_fetcher, kline_fetcher = self._fetchers()
        settings = make_settings(tmp_path)
        scanner = MoneyGrabScanner(settings, quote_fetcher=quote_fetcher, kline_fetcher=kline_fetcher)
        scanner.start()
        self._wait_done(scanner)

        fresh = MoneyGrabScanner(settings, quote_fetcher=quote_fetcher, kline_fetcher=kline_fetcher)
        state = fresh.status()
        # 持久化的 trade_date 是真实运行日，与结果一同恢复
        assert state["status"] == "done"
        assert [hit["symbol"] for hit in state["hits"]] == ["600001"]

    def test_quote_fetcher_failure_sets_failed(self, tmp_path):
        def broken():
            raise RuntimeError("snapshot down")

        scanner = MoneyGrabScanner(make_settings(tmp_path), quote_fetcher=broken, kline_fetcher=lambda s: [])
        scanner.start()
        state = self._wait_done(scanner)
        assert state["status"] == "failed"
        assert "snapshot down" in state["error"]
```

注意：`Settings` 的字段名以 `backend/app/config.py` 为准，若构造参数不是 `cache_dir`/`sqlite_path`，改用其实际字段（实现者先读该文件确认）。

- [ ] **Step 2: 运行确认失败**

Run: `python -m pytest tests/test_scanner.py -v -k Scanner`
Expected: FAIL（`ImportError: MoneyGrabScanner`）

- [ ] **Step 3: 实现**

在 `backend/app/scanner.py` 追加：

```python
import json
import threading
from concurrent.futures import ThreadPoolExecutor
from dataclasses import asdict, dataclass, field

from backend.app.cache import CacheStore
from backend.app.config import Settings, get_settings
from backend.app.utils import now_utc

STATE_KEY = "moneygrab:last_scan"


@dataclass
class ScanState:
    status: str = "idle"  # idle | running | done | failed
    total: int = 0
    done: int = 0
    hits: list[dict] = field(default_factory=list)
    started_at: str | None = None
    finished_at: str | None = None
    error: str | None = None
    trade_date: str | None = None


def _fetch_all_a_quotes() -> list[dict]:
    """全市场A股快照：efinance 优先，akshare 兜底。传空列表 = 不过滤，返回全部。"""
    from backend.app.providers.akshare_adapter import AKShareAdapter
    from backend.app.providers.efinance_adapter import EFinanceAdapter

    errors: list[str] = []
    for adapter_cls in (EFinanceAdapter, AKShareAdapter):
        try:
            frame = adapter_cls().realtime_quotes([])
            if frame is not None and not frame.empty:
                return frame.to_dict("records")
        except Exception as exc:
            errors.append(f"{adapter_cls.__name__}:{exc}")
    raise RuntimeError("; ".join(errors) or "no quote source available")


class MoneyGrabScanner:
    def __init__(
        self,
        settings: Settings,
        quote_fetcher=None,
        kline_fetcher=None,
        max_workers: int = 8,
    ):
        self.settings = settings
        self.max_workers = max_workers
        self._quote_fetcher = quote_fetcher or _fetch_all_a_quotes
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
                started_at=now_utc().isoformat(),
                trade_date=now_utc().date().isoformat(),
            )
            self._thread = threading.Thread(target=self._run, args=(refresh,), daemon=True)
            self._thread.start()
            return asdict(self._state)

    def _default_kline_fetcher(self, service, refresh: bool):
        def fetch(symbol: str) -> list[dict]:
            payload, _ = service.kline(symbol, period="day", indicators=[], limit=140, refresh=refresh)
            return payload["bars"]

        return fetch

    def _run(self, refresh: bool) -> None:
        try:
            cache = CacheStore(self.settings)
            fetch_bars = self._kline_fetcher
            if fetch_bars is None:
                from backend.app.services import MarketService

                fetch_bars = self._default_kline_fetcher(MarketService(self.settings, cache), refresh)

            quotes = self._quote_fetcher()
            candidates = [
                quote
                for quote in quotes
                if eligible_symbol(str(quote.get("symbol", "")), str(quote.get("name", "")))
                and quote.get("price") is not None
            ]
            with self._lock:
                self._state.total = len(candidates)

            def work(quote: dict) -> dict | None:
                try:
                    bars = fetch_bars(str(quote["symbol"]))
                    return evaluate_stock(
                        str(quote["symbol"]), str(quote.get("name", "")), quote.get("price"), bars
                    )
                except Exception:
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
```

注意：`test_result_persisted_and_restored` 里持久化的 `trade_date` 是 `now_utc().date()`（真实当天），恢复校验用同一口径，所以测试无需 mock 日期。

- [ ] **Step 4: 运行确认通过**

Run: `python -m pytest tests/test_scanner.py -v`
Expected: 全部 PASS

- [ ] **Step 5: 提交**

```bash
git add backend/app/scanner.py tests/test_scanner.py
git commit -m "feat: 抢钱流后台扫描任务与进度状态"
```

---

### Task 3: API 路由

**Files:**
- Modify: `backend/app/main.py`
- Create: `tests/test_moneygrab_api.py`

**Interfaces:**
- Consumes: Task 2 的 `get_scanner()`（`start(refresh)` / `status()`）
- Produces:
  - `POST /api/moneygrab/scan?refresh=false` → `ApiResponse(data=<state dict>)`
  - `GET /api/moneygrab/scan/status` → `ApiResponse(data=<state dict>)`

- [ ] **Step 1: 写失败测试**

创建 `tests/test_moneygrab_api.py`：

```python
from fastapi.testclient import TestClient

import backend.app.main as main_module


class FakeScanner:
    def __init__(self):
        self.started_with = None
        self.state = {
            "status": "done",
            "total": 2,
            "done": 2,
            "hits": [
                {"symbol": "600001", "name": "命中股", "price": 13.1, "low90": 10.0, "pct": 31.0, "band": 20.0, "over": 1.0}
            ],
            "started_at": "2026-07-27T01:00:00+00:00",
            "finished_at": "2026-07-27T01:05:00+00:00",
            "error": None,
            "trade_date": "2026-07-27",
        }

    def start(self, refresh=False):
        self.started_with = refresh
        return {**self.state, "status": "running"}

    def status(self):
        return self.state


def make_client(monkeypatch) -> tuple[TestClient, FakeScanner]:
    fake = FakeScanner()
    monkeypatch.setattr(main_module, "get_scanner", lambda: fake)
    return TestClient(main_module.create_app()), fake


def test_start_scan(monkeypatch):
    client, fake = make_client(monkeypatch)
    response = client.post("/api/moneygrab/scan?refresh=true")
    assert response.status_code == 200
    assert response.json()["data"]["status"] == "running"
    assert fake.started_with is True


def test_scan_status(monkeypatch):
    client, _ = make_client(monkeypatch)
    response = client.get("/api/moneygrab/scan/status")
    assert response.status_code == 200
    data = response.json()["data"]
    assert data["status"] == "done"
    assert data["hits"][0]["symbol"] == "600001"
```

- [ ] **Step 2: 运行确认失败**

Run: `python -m pytest tests/test_moneygrab_api.py -v`
Expected: FAIL（404 或 AttributeError: get_scanner）

- [ ] **Step 3: 实现**

`backend/app/main.py`：顶部 import 区加一行：

```python
from backend.app.scanner import get_scanner
```

在 `create_app()` 内（`refresh_cache` 路由之前）追加：

```python
    @app.post("/api/moneygrab/scan", response_model=ApiResponse)
    def start_moneygrab_scan(refresh: bool = False) -> ApiResponse:
        return ApiResponse(data=get_scanner().start(refresh=refresh))

    @app.get("/api/moneygrab/scan/status", response_model=ApiResponse)
    def moneygrab_scan_status() -> ApiResponse:
        return ApiResponse(data=get_scanner().status())
```

- [ ] **Step 4: 运行确认通过**

Run: `python -m pytest tests/ -v`
Expected: 全部 PASS（含既有测试不回归）

- [ ] **Step 5: 提交**

```bash
git add backend/app/main.py tests/test_moneygrab_api.py
git commit -m "feat: 抢钱流扫描 API 路由"
```

---

### Task 4: 前端类型与 API 客户端

**Files:**
- Modify: `frontend/src/types.ts`
- Modify: `frontend/src/api.ts`

**Interfaces:**
- Consumes: Task 3 的两个 HTTP 端点
- Produces:
  - `type MoneyGrabHit = { symbol: string; name: string; price: number; low90: number; pct: number; band: number; over: number }`
  - `type MoneyGrabStatus = { status: "idle" | "running" | "done" | "failed"; total: number; done: number; hits: MoneyGrabHit[]; started_at: string | null; finished_at: string | null; error: string | null; trade_date: string | null }`
  - `api.startMoneyGrabScan(refresh?: boolean)` / `api.getMoneyGrabScanStatus()`

- [ ] **Step 1: 加类型**

`frontend/src/types.ts` 追加：

```typescript
export type MoneyGrabHit = {
  symbol: string;
  name: string;
  price: number;
  low90: number;
  pct: number;
  band: number;
  over: number;
};

export type MoneyGrabStatus = {
  status: "idle" | "running" | "done" | "failed";
  total: number;
  done: number;
  hits: MoneyGrabHit[];
  started_at: string | null;
  finished_at: string | null;
  error: string | null;
  trade_date: string | null;
};
```

- [ ] **Step 2: 加 API 方法**

`frontend/src/api.ts`：import 里加 `MoneyGrabStatus`，`api` 对象追加：

```typescript
  startMoneyGrabScan: (refresh = false) =>
    request<MoneyGrabStatus>(`/api/moneygrab/scan?refresh=${refresh}`, { method: "POST" }),
  getMoneyGrabScanStatus: () => request<MoneyGrabStatus>("/api/moneygrab/scan/status"),
```

- [ ] **Step 3: 编译验证**

Run: `cd frontend && npm run build`
Expected: 构建成功，无类型错误

- [ ] **Step 4: 提交**

```bash
git add frontend/src/types.ts frontend/src/api.ts
git commit -m "feat: 前端抢钱流类型与 API 客户端"
```

---

### Task 5: 抢钱流面板与 App 集成

**Files:**
- Create: `frontend/src/components/MoneyGrabPanel.tsx`
- Modify: `frontend/src/App.tsx`（drawer 类型、入口按钮、drawer 渲染分支）
- Modify: `frontend/src/styles.css`（追加面板样式）

**Interfaces:**
- Consumes: Task 4 的 `api.startMoneyGrabScan` / `api.getMoneyGrabScanStatus`、`MoneyGrabStatus`；App.tsx 现有 drawer 模式（App.tsx:104、App.tsx:416-457）与 `selectPanelSymbol`
- Produces: `MoneyGrabPanel({ onSelect: (symbol: string) => void })`

- [ ] **Step 1: 创建面板组件**

创建 `frontend/src/components/MoneyGrabPanel.tsx`：

```tsx
import { useCallback, useEffect, useRef, useState } from "react";
import { api } from "../api";
import type { MoneyGrabStatus } from "../types";
import { normalizeError } from "../utils/format";

const POLL_MS = 2000;

export function MoneyGrabPanel({ onSelect }: { onSelect: (symbol: string) => void }) {
  const [status, setStatus] = useState<MoneyGrabStatus | null>(null);
  const [error, setError] = useState("");
  const timerRef = useRef<number | null>(null);

  const loadStatus = useCallback(async () => {
    try {
      const response = await api.getMoneyGrabScanStatus();
      setStatus(response.data);
      setError("");
      return response.data;
    } catch (exc) {
      setError(normalizeError(exc));
      return null;
    }
  }, []);

  useEffect(() => {
    loadStatus();
    return () => {
      if (timerRef.current !== null) window.clearInterval(timerRef.current);
    };
  }, [loadStatus]);

  useEffect(() => {
    if (status?.status !== "running") {
      if (timerRef.current !== null) {
        window.clearInterval(timerRef.current);
        timerRef.current = null;
      }
      return;
    }
    if (timerRef.current === null) {
      timerRef.current = window.setInterval(loadStatus, POLL_MS);
    }
  }, [status?.status, loadStatus]);

  async function startScan() {
    try {
      const response = await api.startMoneyGrabScan();
      setStatus(response.data);
      setError("");
    } catch (exc) {
      setError(normalizeError(exc));
    }
  }

  const running = status?.status === "running";
  const progress = status && status.total > 0 ? Math.round((status.done / status.total) * 100) : 0;

  return (
    <div className="moneygrab-panel">
      <h3>抢钱流 · A股档位扫描</h3>
      <p className="moneygrab-desc">
        筛选：现价超过所在 20% 档位区间下沿 10% 以上（如 20%~40% 档中高于 +30%）。基准为 90 自然日最低价。
      </p>
      <div className="moneygrab-actions">
        <button className="terminal-button" disabled={running} onClick={startScan}>
          {running ? "扫描中…" : status?.status === "done" ? "重新扫描" : "开始扫描"}
        </button>
        {status?.status === "done" && status.finished_at && (
          <span className="moneygrab-meta">
            {status.trade_date} · 命中 {status.hits.length} / 扫描 {status.total}
          </span>
        )}
      </div>
      {error && <p className="moneygrab-error">{error}</p>}
      {status?.status === "failed" && <p className="moneygrab-error">扫描失败：{status.error}</p>}
      {running && (
        <div className="moneygrab-progress">
          <div className="moneygrab-progress-bar" style={{ width: `${progress}%` }} />
          <span>
            {status?.done ?? 0} / {status?.total ?? 0}
          </span>
        </div>
      )}
      {status?.status === "done" && (
        <div className="moneygrab-table-wrap">
          <table className="moneygrab-table">
            <thead>
              <tr>
                <th>代码</th>
                <th>名称</th>
                <th>最新价</th>
                <th>90日低点</th>
                <th>涨幅</th>
                <th>档位</th>
                <th>超出</th>
              </tr>
            </thead>
            <tbody>
              {status.hits.map((hit) => (
                <tr key={hit.symbol} onClick={() => onSelect(hit.symbol)}>
                  <td>{hit.symbol}</td>
                  <td>{hit.name}</td>
                  <td>{hit.price.toFixed(2)}</td>
                  <td>{hit.low90.toFixed(2)}</td>
                  <td>{hit.pct.toFixed(1)}%</td>
                  <td>
                    {hit.band}%~{hit.band + 20}%
                  </td>
                  <td>+{hit.over.toFixed(1)}%</td>
                </tr>
              ))}
              {!status.hits.length && (
                <tr>
                  <td colSpan={7}>今日无命中</td>
                </tr>
              )}
            </tbody>
          </table>
        </div>
      )}
    </div>
  );
}
```

注意：`normalizeError` 的实际导出以 `frontend/src/utils/format.ts` 为准（App.tsx:12 已在用，签名一致）。

- [ ] **Step 2: App.tsx 集成**

三处修改：

1. import 区（App.tsx 顶部）：

```tsx
import { MoneyGrabPanel } from "./components/MoneyGrabPanel";
```

lucide-react import 行追加 `Zap`（现有行已 import `Search`、`Star`）。

2. drawer 状态类型（App.tsx:104）改为：

```tsx
const [drawer, setDrawer] = useState<"watchlist" | "summary" | "moneygrab" | null>(null);
```

3. 入口按钮：`workbench-actions` 里（"资产信息"按钮之后，App.tsx:376-379 附近）加：

```tsx
{activePanel === "a_share" && (
  <button className="terminal-button" onClick={() => setDrawer("moneygrab")}>
    <Zap size={15} />
    抢钱流
  </button>
)}
```

4. drawer 渲染（App.tsx:422 的 `drawer === "watchlist" ? ... : ...` 三元）改为：

```tsx
{drawer === "watchlist" ? (
  <WatchlistPanel ... 原有 props 不动 ... />
) : drawer === "moneygrab" ? (
  <MoneyGrabPanel
    onSelect={(symbol) => {
      selectPanelSymbol(symbol);
      setPeriod("day");
      setDrawer(null);
    }}
  />
) : (
  <StockSummary ... 原有 props 不动 ... />
)}
```

- [ ] **Step 3: 样式**

`frontend/src/styles.css` 末尾追加：

```css
/* 抢钱流面板 */
.moneygrab-panel {
  display: flex;
  flex-direction: column;
  gap: 12px;
  height: 100%;
  overflow: hidden;
}

.moneygrab-panel h3 {
  margin: 0;
}

.moneygrab-desc {
  margin: 0;
  font-size: 12px;
  opacity: 0.75;
}

.moneygrab-actions {
  display: flex;
  align-items: center;
  gap: 10px;
}

.moneygrab-meta {
  font-size: 12px;
  opacity: 0.75;
}

.moneygrab-error {
  margin: 0;
  color: #f24d4d;
  font-size: 12px;
}

.moneygrab-progress {
  position: relative;
  height: 18px;
  border: 1px solid rgba(255, 255, 255, 0.2);
  border-radius: 4px;
  overflow: hidden;
  font-size: 11px;
}

.moneygrab-progress-bar {
  position: absolute;
  inset: 0 auto 0 0;
  background: rgba(31, 111, 235, 0.55);
  transition: width 0.4s ease;
}

.moneygrab-progress span {
  position: relative;
  display: block;
  text-align: center;
  line-height: 18px;
}

.moneygrab-table-wrap {
  flex: 1;
  overflow-y: auto;
}

.moneygrab-table {
  width: 100%;
  border-collapse: collapse;
  font-size: 12px;
}

.moneygrab-table th,
.moneygrab-table td {
  padding: 6px 8px;
  text-align: right;
  border-bottom: 1px solid rgba(255, 255, 255, 0.08);
  white-space: nowrap;
}

.moneygrab-table th:nth-child(-n + 2),
.moneygrab-table td:nth-child(-n + 2) {
  text-align: left;
}

.moneygrab-table tbody tr {
  cursor: pointer;
}

.moneygrab-table tbody tr:hover {
  background: rgba(255, 255, 255, 0.06);
}
```

（若 styles.css 是亮色主题，边框/hover 的白色透明度改为 `rgba(0,0,0,0.08)` 一类，按现有变量风格调整。）

- [ ] **Step 4: 编译验证**

Run: `cd frontend && npm run build`
Expected: 构建成功

- [ ] **Step 5: 提交**

```bash
git add frontend/src/components/MoneyGrabPanel.tsx frontend/src/App.tsx frontend/src/styles.css
git commit -m "feat: 抢钱流面板与A股工作台入口"
```

---

### Task 6: 全量验证与真实冒烟

**Files:**
- 无新增（只跑验证）

- [ ] **Step 1: 后端全量测试**

Run: `python -m pytest tests/ -v`
Expected: 全部 PASS

- [ ] **Step 2: 前端构建**

Run: `cd frontend && npm run build`
Expected: 成功

- [ ] **Step 3: 真实冒烟（需网络）**

启动后端（项目现有启动方式，如 `python -m uvicorn backend.app.main:app --port 8000`，端口以 `docs/V3_9_BACKEND_PORT_MIGRATION.md` / vite 代理配置为准），然后：

```bash
curl -X POST "http://127.0.0.1:8000/api/moneygrab/scan"
# 等 10 秒
curl "http://127.0.0.1:8000/api/moneygrab/scan/status"
```

Expected: 第一次返回 `status: running`；第二次 `done` 计数在增长（total 约 5000+）。不必等全量扫完，确认进度推进即可；若等到扫完，抽查 1~2 只命中股在前端 K 线图上确认价格确实处于档位区间上半段。

- [ ] **Step 4: 前端手动冒烟**

启动前端 dev server，A股面板点"抢钱流"→ 开始扫描 → 进度条推进 → 结果表点击一行能切换主图。

- [ ] **Step 5: 收尾**

如有文档更新需要（docs/UPDATES.md 是项目更新日志），追加一条记录后提交：

```bash
git add docs/UPDATES.md
git commit -m "docs: 记录抢钱流功能上线"
```
