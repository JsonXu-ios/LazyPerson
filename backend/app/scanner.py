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
