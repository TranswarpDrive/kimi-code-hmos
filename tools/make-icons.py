#!/usr/bin/env python3
"""生成应用图标（分层图标 background/foreground + 启动页图标）。中性设计：深色底 + 白色 K + 蓝色光标。

用法：python3 tools/make-icons.py   （需要 Pillow）
"""
from pathlib import Path
from PIL import Image, ImageDraw, ImageFilter

ROOT = Path(__file__).resolve().parent.parent
SIZE = 1024
BG_TOP, BG_BOTTOM = (28, 30, 38), (10, 11, 15)
ACCENT = (64, 132, 255)
WHITE = (245, 246, 250)


def background() -> Image.Image:
    img = Image.new('RGB', (SIZE, SIZE))
    draw = ImageDraw.Draw(img)
    for y in range(SIZE):
        t = y / (SIZE - 1)
        color = tuple(round(a + (b - a) * t) for a, b in zip(BG_TOP, BG_BOTTOM))
        draw.line([(0, y), (SIZE, y)], fill=color)
    return img


def foreground() -> Image.Image:
    # 前景内容控制在中间约 56% 的安全区内，避免被系统蒙版裁切
    img = Image.new('RGBA', (SIZE, SIZE), (0, 0, 0, 0))
    draw = ImageDraw.Draw(img)
    stem_w = 92
    left, top, bottom = 330, 312, 712
    draw.rounded_rectangle([left, top, left + stem_w, bottom], radius=18, fill=WHITE)
    mid_y = (top + bottom) // 2 + 6
    # K 的两条斜笔画
    draw.line([(left + stem_w - 6, mid_y), (612, top + 28)], fill=WHITE, width=96)
    draw.line([(left + stem_w + 18, mid_y - 22), (628, bottom - 28)], fill=WHITE, width=96)
    # 蓝色输入光标
    draw.rounded_rectangle([648, bottom - 74, 748, bottom], radius=14, fill=ACCENT + (255,))
    return img


def main() -> None:
    bg, fg = background(), foreground()
    for base in (ROOT / 'AppScope/resources/base/media', ROOT / 'entry/src/main/resources/base/media'):
        bg.save(base / 'background.png')
        fg.save(base / 'foreground.png')
    start = bg.convert('RGBA')
    start.alpha_composite(fg)
    mask = Image.new('L', (SIZE, SIZE), 0)
    ImageDraw.Draw(mask).rounded_rectangle([0, 0, SIZE - 1, SIZE - 1], radius=230, fill=255)
    start.putalpha(mask.filter(ImageFilter.GaussianBlur(1)))
    start.resize((512, 512), Image.LANCZOS).save(ROOT / 'entry/src/main/resources/base/media/startIcon.png')
    start.resize((256, 256), Image.LANCZOS).save(ROOT / 'tools/icon-preview.png')
    print('icons written')


if __name__ == '__main__':
    main()
