"""生成 Flutter 单测的 golden 对拍数据（指标部分）。

从 data/cache/kline/day 读取真实日 K parquet，导出 bars fixture，
并用后端 indicators.py 计算 ma/ema/macd/rsi/lon 作为期望输出。
输出到 app/test/fixtures/。
"""

from __future__ import annotations

import json
import sys
from pathlib import Path

import pandas as pd

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

from backend.app.indicators import compute_indicators  # noqa: E402

SYMBOLS = ["002138", "600519", "300750", "000001"]
OUT_DIR = ROOT / "app" / "test" / "fixtures"


def export(symbol: str) -> None:
    frame = pd.read_parquet(ROOT / "data" / "cache" / "kline" / "day" / f"{symbol}.parquet")
    frame = frame.tail(140).reset_index(drop=True)
    bars = []
    for _, row in frame.iterrows():
        bars.append(
            {
                "time": str(row.get("time", "")),
                "open": _f(row.get("open")),
                "high": _f(row.get("high")),
                "low": _f(row.get("low")),
                "close": _f(row.get("close")),
                "volume": _f(row.get("volume")),
                "amount": _f(row.get("amount")),
                "pct_chg": _f(row.get("pct_chg")),
                "turnover": _f(row.get("turnover")),
            }
        )
    indicators = compute_indicators(frame, ["ma", "ema", "macd", "rsi", "lon"])
    (OUT_DIR / f"bars_{symbol}.json").write_text(
        json.dumps(bars, ensure_ascii=False), encoding="utf-8"
    )
    (OUT_DIR / f"indicators_{symbol}.json").write_text(
        json.dumps(indicators, ensure_ascii=False), encoding="utf-8"
    )
    print(f"{symbol}: {len(bars)} bars")


def _f(value):
    if value is None or pd.isna(value):
        return None
    return float(value)


if __name__ == "__main__":
    OUT_DIR.mkdir(parents=True, exist_ok=True)
    for symbol in SYMBOLS:
        export(symbol)
