from datetime import datetime, timezone
from typing import Any

import pandas as pd


def now_utc() -> datetime:
    return datetime.now(timezone.utc)


def safe_float(value: Any) -> float | None:
    if value is None:
        return None
    try:
        if pd.isna(value):
            return None
        return float(value)
    except (TypeError, ValueError):
        return None


def normalize_symbol(symbol: str) -> str:
    clean = symbol.strip().upper()
    for suffix in (".SH", ".SZ", ".BJ", ".SS", ".US"):
        clean = clean.replace(suffix, "")
    return clean


def guess_market(symbol: str) -> str:
    clean = normalize_symbol(symbol)
    if clean.endswith("-USD"):
        return "CRYPTO"
    if clean.endswith("=F"):
        return "FUT"
    if clean.endswith("=X"):
        return "FX"
    if clean.isalpha() and 1 <= len(clean) <= 5:
        return "US"
    if clean.startswith(("5", "6", "9")):
        return "SH"
    if clean.startswith(("0", "2", "3")):
        return "SZ"
    if clean.startswith(("4", "8")):
        return "BJ"
    return ""


def is_a_share_symbol(symbol: str) -> bool:
    clean = normalize_symbol(symbol)
    return clean.isdigit() and guess_market(clean) in {"SH", "SZ", "BJ"}
