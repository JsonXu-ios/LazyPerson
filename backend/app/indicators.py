import pandas as pd


def _series(values: pd.Series) -> list[float | None]:
    return [None if pd.isna(value) else round(float(value), 6) for value in values]


def add_ma(frame: pd.DataFrame, windows: tuple[int, ...] = (5, 10, 20, 60)) -> dict[str, list[float | None]]:
    close = frame["close"].astype(float)
    return {f"ma{window}": _series(close.rolling(window).mean()) for window in windows}


def add_ema(frame: pd.DataFrame, spans: tuple[int, ...] = (12, 26)) -> dict[str, list[float | None]]:
    close = frame["close"].astype(float)
    return {f"ema{span}": _series(close.ewm(span=span, adjust=False).mean()) for span in spans}


def add_macd(frame: pd.DataFrame, fast: int = 12, slow: int = 26, signal: int = 9) -> dict[str, list[float | None]]:
    close = frame["close"].astype(float)
    ema_fast = close.ewm(span=fast, adjust=False).mean()
    ema_slow = close.ewm(span=slow, adjust=False).mean()
    dif = ema_fast - ema_slow
    dea = dif.ewm(span=signal, adjust=False).mean()
    hist = (dif - dea) * 2
    return {"dif": _series(dif), "dea": _series(dea), "hist": _series(hist)}


def _rsi(close: pd.Series, window: int) -> pd.Series:
    delta = close.diff()
    gain = delta.clip(lower=0)
    loss = -delta.clip(upper=0)
    avg_gain = gain.rolling(window).mean()
    avg_loss = loss.rolling(window).mean()
    rs = avg_gain / avg_loss.replace(0, pd.NA)
    return 100 - (100 / (1 + rs))


def add_rsi(frame: pd.DataFrame, windows: tuple[int, ...] = (6, 12, 24)) -> dict[str, list[float | None]]:
    close = frame["close"].astype(float)
    return {f"rsi{window}": _series(_rsi(close, window)) for window in windows}


def _sma_cn(values: pd.Series, window: int, weight: int = 1) -> pd.Series:
    result: list[float | None] = []
    previous: float | None = None
    for value in values:
        if pd.isna(value):
            result.append(previous)
            continue
        current = float(value) if previous is None else (weight * float(value) + (window - weight) * previous) / window
        previous = current
        result.append(current)
    return pd.Series(result, index=values.index, dtype="float64")


def add_lon(frame: pd.DataFrame) -> dict[str, list[float | None]]:
    close = frame["close"].astype(float)
    high = frame["high"].astype(float)
    low = frame["low"].astype(float)
    volume = frame["volume"].astype(float)
    lc = close.shift(1)
    high_2 = high.rolling(2).max()
    low_2 = low.rolling(2).min()
    denominator = ((high_2 - low_2) * 100).replace(0, pd.NA)
    vid = volume.rolling(2).sum() / denominator
    rc = (close - lc) * vid
    long = rc.fillna(0).cumsum()
    dif = _sma_cn(long, 10, 1)
    dea = _sma_cn(long, 20, 1)
    lon = dif - dea
    lonma = lon.rolling(10).mean()
    return {"lon": _series(lon), "lonma": _series(lonma), "dif": _series(dif), "dea": _series(dea)}


def compute_indicators(frame: pd.DataFrame, names: list[str]) -> dict:
    result: dict = {}
    wanted = {name.strip().lower() for name in names if name.strip()}
    if "ma" in wanted:
        result["ma"] = add_ma(frame)
    if "ema" in wanted:
        result["ema"] = add_ema(frame)
    if "macd" in wanted:
        result["macd"] = add_macd(frame)
    if "lon" in wanted:
        result["lon"] = add_lon(frame)
    if "rsi" in wanted:
        result["rsi"] = add_rsi(frame)
    return result
