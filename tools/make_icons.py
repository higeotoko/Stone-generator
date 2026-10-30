"""ツールバーアイコン（SVG + PNG）を生成する。  python3 tools/make_icons.py"""
import os
from PIL import Image, ImageDraw

OUT = os.path.join(os.path.dirname(__file__), '..', 'src', 'stone_layout_generator', 'images')
STONE = '#c9c2b6'
EDGE = '#6b6459'
ACCENT = '#1f6feb'
ORANGE = '#f08c00'

# 各アイコンは 32x32 の座標系で図形を並べる: ('rect', x, y, w, h, fill) / ('line', x1, y1, x2, y2, color, width) / ('poly', [(x,y)...], fill)
def running_bond():
    rows = [(3, [(2, 13), (16, 14)]), (11, [(2, 6), (9, 13), (23, 7)]), (19, [(2, 13), (16, 14)])]
    out = []
    for y, stones in rows:
        for x, w in stones:
            out.append(('rect', x, y, w - 1, 7, STONE))
    out.append(('rect', 2, 27, 28, 2, ORANGE))  # 選択面
    return out

def edit_joint():
    out = []
    for x, w in [(2, 12), (18, 12)]:
        for y in (4, 16):
            out.append(('rect', x, y, w - 1, 11, STONE))
    out.append(('line', 16.5, 2, 16.5, 29, ACCENT, 3))
    out.append(('poly', [(6, 22), (11, 18.5), (11, 25.5)], ACCENT))
    out.append(('poly', [(27, 22), (22, 18.5), (22, 25.5)], ACCENT))
    return out

def settings():
    out = [
        ('poly', [(4, 12), (20, 6), (28, 10), (12, 16)], '#e2ddd3'),   # 上面
        ('poly', [(4, 12), (12, 16), (12, 26), (4, 22)], '#a39b8e'),    # 小口
        ('poly', [(12, 16), (28, 10), (28, 20), (12, 26)], STONE),      # 表面
        ('line', 30, 10, 30, 20, ACCENT, 2),                           # 石厚の寸法線
        ('line', 28, 10, 31, 10, ACCENT, 1.5),
        ('line', 28, 20, 31, 20, ACCENT, 1.5),
    ]
    return out

def schedule():
    # 一覧表（見出し行＋行）と石
    out = [('rect', 3, 4, 26, 24, '#ffffff'), ('rect', 3, 4, 26, 6, '#acc5df')]
    for y in (14, 19, 24):
        out.append(('line', 6, y, 26, y, EDGE, 1.2))
    out.append(('line', 12, 10, 12, 28, EDGE, 1))
    out.append(('rect', 5, 12, 5, 3, STONE))
    out.append(('rect', 5, 17, 5, 3, STONE))
    out.append(('rect', 5, 22, 5, 3, STONE))
    return out

ICONS = {'generate': running_bond, 'edit': edit_joint, 'settings': settings, 'schedule': schedule}

def svg(shapes):
    parts = ['<svg xmlns="http://www.w3.org/2000/svg" width="32" height="32" viewBox="0 0 32 32">']
    for s in shapes:
        if s[0] == 'rect':
            _, x, y, w, h, f = s
            parts.append(f'<rect x="{x}" y="{y}" width="{w}" height="{h}" rx="0.5" fill="{f}" stroke="{EDGE}" stroke-width="1"/>')
        elif s[0] == 'line':
            _, x1, y1, x2, y2, c, w = s
            parts.append(f'<line x1="{x1}" y1="{y1}" x2="{x2}" y2="{y2}" stroke="{c}" stroke-width="{w}" stroke-linecap="round"/>')
        else:
            _, pts, f = s
            d = ' '.join(f'{x},{y}' for x, y in pts)
            parts.append(f'<polygon points="{d}" fill="{f}" stroke="{EDGE if f != ACCENT else ACCENT}" stroke-width="1" stroke-linejoin="round"/>')
    parts.append('</svg>')
    return '\n'.join(parts) + '\n'

def png(shapes, size):
    ss = 8  # スーパーサンプリング
    k = size * ss / 32.0
    img = Image.new('RGBA', (size * ss, size * ss), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    for s in shapes:
        if s[0] == 'rect':
            _, x, y, w, h, f = s
            d.rectangle([x * k, y * k, (x + w) * k, (y + h) * k], fill=f, outline=EDGE, width=max(1, int(k)))
        elif s[0] == 'line':
            _, x1, y1, x2, y2, c, w = s
            d.line([x1 * k, y1 * k, x2 * k, y2 * k], fill=c, width=max(1, int(w * k)))
        else:
            _, pts, f = s
            d.polygon([(x * k, y * k) for x, y in pts], fill=f, outline=EDGE if f != ACCENT else ACCENT, width=max(1, int(k)))
    return img.resize((size, size), Image.LANCZOS)

os.makedirs(OUT, exist_ok=True)
for name, fn in ICONS.items():
    shapes = fn()
    with open(os.path.join(OUT, f'{name}.svg'), 'w') as fh:
        fh.write(svg(shapes))
    for size in (24, 32):
        png(shapes, size).save(os.path.join(OUT, f'{name}_{size}.png'))
print('icons written to', os.path.abspath(OUT))
