#!/usr/bin/env python3
"""将 imagegen 生成的图标母版整理为鸿蒙分层资源和启动页图标。

用法：python3 tools/make-icons.py（需要 Pillow）
母版：tools/artwork/icon-master.png。图案在 imagegen 中修改，本脚本只适配资源格式和尺寸。
"""
from pathlib import Path
from PIL import Image, ImageDraw, ImageFilter

ROOT = Path(__file__).resolve().parent.parent
SOURCE = ROOT / 'tools/artwork/icon-master.png'
SIZE = 1024


def main() -> None:
    with Image.open(SOURCE) as source:
        if source.width != source.height or source.width < 512:
            raise ValueError('图标母版必须是至少 512 × 512 的正方形')
        if source.convert('RGBA').getchannel('A').getextrema() != (255, 255):
            raise ValueError('图标母版必须完全不透明，避免透明层丢失白色标志')
        icon = source.convert('RGB').resize((SIZE, SIZE), Image.Resampling.LANCZOS)

    # 母版已有完整背景和标志，统一放入背景层；透明前景只用于保持分层资源结构。
    # 系统负责桌面图标的外形蒙版，母版中心留白保证圆形/圆角裁切不损失标志。
    foreground = Image.new('RGBA', (SIZE, SIZE), (0, 0, 0, 0))
    for base in (ROOT / 'AppScope/resources/base/media',
                 ROOT / 'entry/src/main/resources/base/media'):
        icon.save(base / 'background.png', optimize=True)
        foreground.save(base / 'foreground.png', optimize=True)

    start = icon.convert('RGBA')
    mask = Image.new('L', (SIZE, SIZE), 0)
    ImageDraw.Draw(mask).rounded_rectangle(
        [0, 0, SIZE - 1, SIZE - 1], radius=230, fill=255)
    start.putalpha(mask.filter(ImageFilter.GaussianBlur(1)))
    start.resize((512, 512), Image.Resampling.LANCZOS).save(
        ROOT / 'entry/src/main/resources/base/media/startIcon.png', optimize=True)
    start.resize((256, 256), Image.Resampling.LANCZOS).save(
        ROOT / 'tools/icon-preview.png', optimize=True)
    print('已生成分层图标、启动页图标和预览图')


if __name__ == '__main__':
    main()
