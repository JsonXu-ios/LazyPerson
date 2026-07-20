"""生成多个 LazyPerson logo 候选方案，输出到 app/assets/icon/options/。

共同点：大睡脸撑满画布（饱满）+ K 线元素 + zZZ。
运行后生成 option_1..4.png 和拼在一起的 contact_sheet.png。
"""

from __future__ import annotations

from pathlib import Path

from PIL import Image, ImageDraw, ImageFont

ROOT = Path(__file__).resolve().parents[1]
OUT_DIR = ROOT / "app" / "assets" / "icon" / "options"

SIZE = 1024
BG = (8, 13, 22, 255)
RISE = (242, 77, 77, 255)
FALL = (0, 168, 132, 255)
SKIN = (246, 211, 107, 255)
BLUSH = (245, 164, 97, 255)
GRID = (30, 42, 63, 255)


def base_canvas() -> tuple[Image.Image, ImageDraw.ImageDraw]:
    img = Image.new("RGBA", (SIZE, SIZE), BG)
    return img, ImageDraw.Draw(img)


def face(draw: ImageDraw.ImageDraw, cx: float, cy: float, r: float,
         eye_scale: float = 1.0):
    """睡脸：大圆 + 闭眼 + 哈气嘴 + 腮红。"""
    draw.ellipse([cx - r, cy - r, cx + r, cy + r], fill=SKIN)
    ew = r * 0.20 * eye_scale   # 眼宽的一半
    eh = r * 0.16 * eye_scale
    ey = cy - r * 0.10
    for ex in (cx - r * 0.42, cx + r * 0.42):
        draw.arc([ex - ew, ey - eh, ex + ew, ey + eh],
                 start=180, end=360, fill=BG, width=max(int(r * 0.07), 6))
    # 嘴
    mr = r * 0.13
    draw.ellipse([cx - mr, cy + r * 0.28, cx + mr, cy + r * 0.28 + mr * 2],
                 fill=BG)
    # 腮红
    bw, bh = r * 0.16, r * 0.10
    for bx in (cx - r * 0.60, cx + r * 0.60):
        draw.ellipse([bx - bw, cy + r * 0.16 - bh, bx + bw, cy + r * 0.16 + bh],
                     fill=BLUSH)


def zzz(draw: ImageDraw.ImageDraw, items, color=RISE):
    for x, y, size, width in items:
        draw.line([(x, y), (x + size, y), (x, y + size), (x + size, y + size)],
                  fill=color, width=width, joint="curve")


def candle(draw: ImageDraw.ImageDraw, x: float, top: float, bottom: float,
           color, body_w: float, wick: float = 50, wick_w: int = 14,
           radius: int = 14):
    draw.line([(x, top - wick), (x, bottom + wick)], fill=color, width=wick_w)
    draw.rounded_rectangle([x - body_w, top, x + body_w, bottom],
                           radius=radius, fill=color)


def option_1() -> Image.Image:
    """方案1：睡脸戴红色"蜡烛睡帽"（贴头的弓形帽 + 影线帽穗）。"""
    img, draw = base_canvas()
    cx, cy, r = 512, 600, 430
    face(draw, cx, cy, r)
    # 帽体：沿头顶的弓形（chord），比头略大一圈
    hr = r + 16
    draw.chord([cx - hr, cy - hr, cx + hr, cy + hr],
               start=205, end=335, fill=RISE)
    # 影线当帽穗：从帽顶伸出 + 黄色小球
    draw.line([(cx, cy - hr + 10), (cx, 80)], fill=RISE, width=34)
    draw.ellipse([cx - 52, 20, cx + 52, 124], fill=SKIN)
    zzz(draw, [(120, 150, 120, 30), (270, 90, 80, 20)])
    return img


def option_2() -> Image.Image:
    """方案2：睡脸浮在一排渐高蜡烛后面（行情做枕头）。"""
    img, draw = base_canvas()
    face(draw, 512, 470, 400)
    # 底部一排蜡烛，从左到右渐高，压住脸的下缘
    candles = [
        (130, 830, 990, RISE),
        (330, 770, 990, FALL),
        (530, 700, 990, RISE),
        (730, 620, 990, RISE),
        (920, 520, 990, RISE),
    ]
    for x, top, bottom, color in candles:
        candle(draw, x, top, bottom, color, body_w=78, wick=55, wick_w=18,
               radius=20)
    zzz(draw, [(700, 90, 120, 30), (850, 40, 75, 20)])
    return img


def option_3() -> Image.Image:
    """方案3：红色上升箭头从脸背后穿过，只露出两端。"""
    img, draw = base_canvas()
    # 完整箭头先画（会被脸盖住中段），脸后再补右上露头段
    draw.line([(30, 920), (900, 320)], fill=RISE, width=96)
    face(draw, 490, 540, 420)
    draw.line([(845, 358), (930, 300)], fill=RISE, width=96)
    draw.polygon([(1010, 230), (818, 268), (922, 428)], fill=RISE)
    zzz(draw, [(110, 130, 110, 28), (250, 70, 70, 18)])
    return img


def option_4() -> Image.Image:
    """方案4：睡脸 + 左右两侧小蜡烛贴边，zZZ 右上。"""
    img, draw = base_canvas()
    face(draw, 512, 512, 430)
    # 左右贴边蜡烛（脸前景，像睡在K线中间）
    candle(draw, 80, 560, 900, RISE, body_w=60, wick=60, wick_w=16)
    candle(draw, 944, 430, 820, RISE, body_w=60, wick=60, wick_w=16)
    candle(draw, 190, 720, 990, FALL, body_w=60, wick=45, wick_w=16)
    zzz(draw, [(660, 100, 120, 30), (810, 45, 78, 20)])
    return img


def contact_sheet(images: list[Image.Image]) -> Image.Image:
    pad = 40
    cell = 512
    cols = 2
    rows = (len(images) + 1) // 2
    sheet = Image.new("RGBA",
                      (cols * cell + pad * 3, rows * (cell + 70) + pad),
                      (30, 30, 30, 255))
    draw = ImageDraw.Draw(sheet)
    try:
        font = ImageFont.truetype("arial.ttf", 40)
    except OSError:
        font = ImageFont.load_default()
    for index, img in enumerate(images):
        col = index % cols
        row = index // cols
        x = pad + col * (cell + pad)
        y = pad + row * (cell + 70)
        sheet.alpha_composite(img.resize((cell, cell)), (x, y))
        draw.text((x + cell // 2 - 60, y + cell + 10), f"option {index + 1}",
                  fill=(255, 255, 255, 255), font=font)
    return sheet


def main():
    OUT_DIR.mkdir(parents=True, exist_ok=True)
    options = [option_1(), option_2(), option_3(), option_4()]
    for index, img in enumerate(options):
        img.save(OUT_DIR / f"option_{index + 1}.png")
    contact_sheet(options).save(OUT_DIR / "contact_sheet.png")
    print(f"{len(options)} options written to {OUT_DIR}")


if __name__ == "__main__":
    main()
