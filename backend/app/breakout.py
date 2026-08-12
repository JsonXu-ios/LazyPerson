"""破势：按已突破的最高主线（20/50/80/110/…）给个股分组。

与八档局的档位（分界 20/40/70/100…）是两套独立视图：
八档局看"落在哪个档位区间"，破势看"最近站上了哪条主线"。
每只股票只归到它突破的最高那条线所在的组，不重复计入前面的组。
"""

from __future__ import annotations

# K线图上的加粗主线，与 frontend majorLineAnchor=20/step=30 一致
MAIN_LINES = (20.0, 50.0, 80.0, 110.0, 140.0, 170.0, 200.0, 230.0)


def breakout_stage(pct: float | None) -> int | None:
    """已突破的最高主线序号（1=站上20、2=站上50、3=站上80…），未过20返回 None。
    序号 k 对应的分组标签是「MAIN_LINES[k-2] → MAIN_LINES[k-1]」（k≥2）。"""
    if pct is None or pct < MAIN_LINES[0]:
        return None
    stage = 1
    for index, line in enumerate(MAIN_LINES, start=1):
        if pct >= line:
            stage = index
    return stage


def stage_label(stage: int) -> str:
    """分组标签：2 → "20→50"、3 → "50→80"…；1（只站上20没到50）→ "0→20"。"""
    if stage <= 1:
        return f"0→{MAIN_LINES[0]:.0f}"
    upper = MAIN_LINES[min(stage, len(MAIN_LINES)) - 1]
    lower = MAIN_LINES[min(stage, len(MAIN_LINES)) - 2]
    return f"{lower:.0f}→{upper:.0f}"


#: 蓄势待发的"刚过线"阈值：站上主线后超出不超过这么多个百分点
BUILDUP_MAX_OVER = 5.0


def _crossed_line(pct: float | None) -> float | None:
    """已站上的最高主线；没过 20% 返回 None。"""
    if pct is None or pct < MAIN_LINES[0]:
        return None
    line = None
    for value in MAIN_LINES:
        if pct >= value:
            line = value
    return line


def buildup_over(pct: float | None, max_over: float = BUILDUP_MAX_OVER) -> float | None:
    """蓄势待发：刚刚站上某条主线、还没走远，返回超出该主线几个百分点。

    走太远（> max_over）或还没过 20% 都返回 None。
    例：52 → 2（刚过 50 线）；58 → None（超出 8，已经走远）。
    """
    line = _crossed_line(pct)
    if line is None:
        return None
    over = round(pct - line, 2)
    return over if over <= max_over else None


def buildup_line(pct: float | None, max_over: float = BUILDUP_MAX_OVER) -> float | None:
    """蓄势待发刚站上的那条主线；不满足条件返回 None。"""
    if buildup_over(pct, max_over) is None:
        return None
    return _crossed_line(pct)


def stage_line(stage: int) -> float:
    """该组已突破的那条主线（分组下沿）。"""
    return MAIN_LINES[min(max(stage, 1), len(MAIN_LINES)) - 1]
