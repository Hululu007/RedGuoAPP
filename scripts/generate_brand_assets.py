import argparse
import io
import json
from pathlib import Path

import resvg_py
from PIL import Image, ImageDraw

root = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description='从统一图形生成各平台图标与电视横幅；需要 Pillow 和 resvg-py。')
parser.add_argument('--output', type=Path, default=root)
options = parser.parse_args()
output = options.output
source = (root / 'scripts/brand_icon.svg').read_text(encoding='utf-8')

def render(svg):
    png = resvg_py.svg_to_bytes(svg_string=svg, width=1024, height=1024)
    return Image.open(io.BytesIO(bytes(png))).convert('RGBA')

foreground = render(source)
silhouette = render(source.replace(' filter="url(#shadow)"', ''))
icon = Image.new('RGBA', (1024, 1024), '#CDE5F9')
icon.alpha_composite(foreground)
rounded = icon.copy()
corners = Image.new('L', (1024, 1024), 0)
ImageDraw.Draw(corners).rounded_rectangle((0, 0, 1023, 1023), radius=236, fill=255)
rounded.putalpha(corners)
icon = icon.convert('RGB')
adaptive = Image.new('RGBA', (1536, 1536))
adaptive.paste(foreground, (256, 256))
monochrome = Image.new('RGBA', (1536, 1536))
monochrome.paste(silhouette, (256, 256))

def save(image, name):
    destination = output / name
    destination.parent.mkdir(parents=True, exist_ok=True)
    image.save(destination)

for density, scale in [('mdpi', 1), ('hdpi', 1.5), ('xhdpi', 2), ('xxhdpi', 3), ('xxxhdpi', 4)]:
    legacy = round(48 * scale)
    layer = round(108 * scale)
    save(rounded.resize((legacy, legacy), Image.Resampling.LANCZOS),
         f'android/app/src/main/res/mipmap-{density}/ic_launcher.png')
    save(adaptive.resize((layer, layer), Image.Resampling.LANCZOS),
         f'android/app/src/main/res/mipmap-{density}/ic_launcher_foreground.png')
    save(monochrome.resize((layer, layer), Image.Resampling.LANCZOS),
         f'android/app/src/main/res/mipmap-{density}/ic_launcher_monochrome.png')
banner = Image.new('RGB', (640, 360), '#F5F9FC')
badge = rounded.resize((220, 220), Image.Resampling.LANCZOS)
banner.paste(badge, (210, 70), badge)
save(banner, 'android/app/src/main/res/drawable-xhdpi/tv_banner.png')
