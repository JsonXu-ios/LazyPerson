from datetime import date, timedelta

from backend.app.scanner import (
    band_position,
    eligible_symbol,
    evaluate_stock,
    slice_calendar_window,
)


def make_bars(days: int, low: float, today: date | None = None) -> list[dict]:
    """生成 days 个自然日内的工作日日线，最低价 low 放在最早一根，其余为 low*1.05。"""
    today = today or date(2026, 7, 24)  # 周五
    bars = []
    for offset in range(days, -1, -1):
        day = today - timedelta(days=offset)
        if day.weekday() >= 5:
            continue
        value = low if not bars else low * 1.05
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
        # 窗口内最低 10.0，价格 13.1 → pct=31% → band=20，over=1
        bars = make_bars(200, 10.0, self.today)
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
