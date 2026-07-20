"""生成 LazyPerson 应用 logo。

主题：慵懒小人靠坐在上升的 K 线旁。深色底 + 浅黄/上涨红点缀，
与应用深色终端主题同色系。

输出：
- app/assets/icon/icon.png            1024x1024 完整图标（圆角深色底）
- app/assets/icon/icon_foreground.png 1024x1024 自适应图标前景（内容缩到中心 66%）
"""

from __future__ import annotations

from pathlib import Path

from PIL import Image, ImageDraw

ROOT = Path(__file__).resolve().parents[1]
OUT_DIR = ROOT / "app" / "assets" / "icon"

SIZE = 1024
BG = (8, 13, 22, 255)          # #080d16
PANEL = (16, 23, 34, 255)      # #101722
RISE = (242, 77, 77, 255)      # #f24d4d
FALL = (0, 168, 132, 255)      # #00a884
YELLOW = (246, 211, 107, 255)  # #f6d36b
SKIN = (246, 211, 107, 255)
GRID = (23, 32, 51, 255)


def draw_content(draw: ImageDraw.ImageDraw, scale: float = 1.0, offset: float = 0.0):
    """画布内容按 scale 缩放、offset 平移（用于自适应前景留白）。

    构图（选定方案）：大睡脸浮在一排渐高的红绿蜡烛后面 + 右上角红色 zZZ。
    """

    def pt(x: float, y: float) -> tuple[float, float]:
        return (x * scale + offset, y * scale + offset)

    def box(x0: float, y0: float, x1: float, y1: float):
        return [pt(x0, y0), pt(x1, y1)]

    def w(value: float) -> int:
        return max(int(value * scale), 2)

    # 大睡脸（略偏上，底部留给蜡烛）
    cx, cy, r = 512, 470, 400
    draw.ellipse(box(cx - r, cy - r, cx + r, cy + r), fill=SKIN)
    # 闭眼（∩ 弧线，惬意）
    eye_w = w(28)
    draw.arc(box(264, 366, 424, 494), start=180, end=360, fill=BG, width=eye_w)
    draw.arc(box(600, 366, 760, 494), start=180, end=360, fill=BG, width=eye_w)
    # 微张的嘴（睡觉哈气）
    draw.ellipse(box(460, 582, 564, 686), fill=BG)
    # 腮红（肤色与上涨红的预混实色，ImageDraw 不做透明混合）
    blush = (245, 164, 97, 255)
    for bx in (272, 752):
        draw.ellipse(box(bx - 64, 494, bx + 64, 574), fill=blush)

    # 前排渐高蜡烛（红涨绿跌），压住脸的下缘
    candles = [
        (130, 830, 990, RISE),
        (330, 770, 990, FALL),
        (530, 700, 990, RISE),
        (730, 620, 990, RISE),
        (920, 520, 990, RISE),
    ]
    for x, top, bottom, color in candles:
        draw.line([pt(x, top - 55), pt(x, bottom + 20)], fill=color, width=w(18))
        draw.rounded_rectangle(box(x - 78, top, x + 78, bottom),
                               radius=20 * scale, fill=color)

    # zZZ 从右上角飘出（上涨红），逐个变小
    for zx, zy, zs, zw in [(690, 110, 120, 30), (835, 70, 78, 20)]:
        z = zs * scale
        x0, y0 = pt(zx, zy)
        draw.line([(x0, y0), (x0 + z, y0), (x0, y0 + z), (x0 + z, y0 + z)],
                  fill=RISE, width=w(zw), joint="curve")


def main():
    OUT_DIR.mkdir(parents=True, exist_ok=True)

    # 完整图标：深色圆角底
    # 完整图标：满幅方形，不带圆角（遮罩由系统启动器负责，
    # 自带透明圆角会被二次裁剪导致图标显小）
    icon = Image.new("RGBA", (SIZE, SIZE), BG)
    draw = ImageDraw.Draw(icon)
    draw_content(draw)
    icon.save(OUT_DIR / "icon.png")

    # 自适应前景：透明底。主体是圆脸，可以顶到可见区边缘
    # （squircle 遮罩可见区约 72/108 ≈ 0.667，圆形主体取 0.76 基本占满）
    fg = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
    fg_draw = ImageDraw.Draw(fg)
    scale = 0.76
    offset = SIZE * (1 - scale) / 2
    draw_content(fg_draw, scale=scale, offset=offset)
    fg.save(OUT_DIR / "icon_foreground.png")

    print(f"logo written to {OUT_DIR}")


if __name__ == "__main__":
    main()
