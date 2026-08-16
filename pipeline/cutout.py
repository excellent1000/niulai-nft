#!/usr/bin/env python
"""抠图：raw/<layer>/*.png（绿幕/品红幕）→ layers/<layer>/*.png（透明 PNG，裁到内容框）

  python pipeline/cutout.py                 # 处理 body / outfit / accessory（bg 不抠）
  python pipeline/cutout.py --only body --force --method key|rembg|auto --debug
"""
from __future__ import annotations
import argparse, pathlib, sys
import numpy as np
from PIL import Image, ImageFilter
sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
from common import CFG, RAW, LAYERS

CUTOUT_LAYERS = ('body', 'outfit', 'accessory')


def key_color_for(layer: str, name: str) -> str:
    if layer == 'body':
        char = name.split('__')[0]
        return CFG['characters'].get(char, {}).get('key', 'green')
    table = CFG['outfits'] if layer == 'outfit' else CFG['accessories']
    return table.get(name, {}).get('key', 'green')


KEY_HUE = {'green': (75, 170), 'blue': (195, 265), 'magenta': (275, 345)}


def _rgb2hsv(arr: np.ndarray):
    r, g, b = arr[..., 0] / 255.0, arr[..., 1] / 255.0, arr[..., 2] / 255.0
    mx = np.maximum(np.maximum(r, g), b); mn = np.minimum(np.minimum(r, g), b)
    d = mx - mn + 1e-6
    hue = np.zeros_like(mx)
    m = mx == r; hue[m] = ((g - b) / d)[m] % 6
    m = mx == g; hue[m] = ((b - r) / d)[m] + 2
    m = mx == b; hue[m] = ((r - g) / d)[m] + 4
    hue = (hue * 60) % 360
    sat = np.where(mx > 0, d / (mx + 1e-6), 0)
    return hue, sat, mx


def chroma_key(im: Image.Image, key: str = 'green', s_lo: float = 0.09, s_hi: float = 0.20) -> Image.Image:
    """HSV 色键：色相落在 key 区间且有一定饱和度 → 背景（软边）。对发灰/带暗角的幕布也稳。"""
    arr = np.asarray(im.convert('RGB')).astype(np.float32)
    r, g, b = arr[..., 0], arr[..., 1], arr[..., 2]
    hue, sat, val = _rgb2hsv(arr)
    h0, h1 = KEY_HUE.get(key, KEY_HUE['green'])
    # 色相软掩膜（区间内 1，区间外 12° 内线性过渡）
    inside = np.clip(np.minimum(hue - h0, h1 - hue) / 12.0 + 1.0, 0, 1)
    inside = np.where((hue >= h0) & (hue <= h1), 1.0, inside * ((hue > h0 - 12) & (hue < h1 + 12)))
    s_w = np.clip((sat - s_lo) / (s_hi - s_lo), 0, 1)
    v_w = np.clip((val - 0.06) / 0.08, 0, 1)          # 极暗像素不算幕布（保护黑色轮廓/眼睛）
    bg = inside * s_w * v_w
    # 第二判据：用画面边框取样估计实际幕布颜色（发灰/带暗角的幕布也能抓到），按 RGB 距离再判一次
    H, W = hue.shape
    fw = max(8, min(H, W) // 60)
    border = np.concatenate([arr[:fw].reshape(-1, 3), arr[-fw:].reshape(-1, 3), arr[:, :fw].reshape(-1, 3), arr[:, -fw:].reshape(-1, 3)])
    est = np.median(border, axis=0)
    dist = np.sqrt(((arr - est) ** 2).sum(axis=-1))
    hue_broad = ((hue > h0 - 25) & (hue < h1 + 25)) | (sat < 0.14)
    bg2 = np.clip((70.0 - dist) / 30.0, 0, 1) * hue_broad * v_w
    bg = np.maximum(bg, bg2)
    alpha = 1.0 - bg
    alpha = np.where(alpha < 0.35, 0.0, np.where(alpha > 0.78, 1.0, alpha))   # 压掉半透明的雾，只保留窄软边
    # 溢色抑制：所有非完全透明像素里，把 key 通道压到不超过其余通道 + 10
    keep = alpha > 0
    if key == 'magenta':
        cap = g + 10
        r2 = np.where(keep & (r > cap) & (inside > 0), cap, r); b2 = np.where(keep & (b > cap) & (inside > 0), cap, b); g2 = g
    elif key == 'blue':
        cap = np.maximum(r, g) + 10
        r2, g2 = r, g; b2 = np.where(keep & (b > cap) & (inside > 0), cap, b)
    else:
        cap = np.maximum(r, b) + 10
        r2, b2 = r, b; g2 = np.where(keep & (g > cap) & (inside > 0), cap, g)
    # 去掉边缘的黑边/白条/信箱条：从四边向内，整行/列几乎全黑、全白（或已被抠掉）的都视为背景
    dark = (r + g + b) < 90
    white = (r > 228) & (g > 228) & (b > 228)
    bgish = dark | white | (alpha < 0.05)
    H, W = alpha.shape
    def strip(axis_rows: bool):
        n = H if axis_rows else W
        for edge in (0, 1):
            rng = range(n) if edge == 0 else range(n - 1, -1, -1)
            for i in rng:
                line = bgish[i, :] if axis_rows else bgish[:, i]
                if line.mean() > 0.985:
                    if axis_rows: alpha[i, :] = 0
                    else: alpha[:, i] = 0
                else:
                    break
    strip(True); strip(False)
    a8 = (alpha * 255).astype(np.uint8)
    rgba = np.dstack([np.clip(r2, 0, 255), np.clip(g2, 0, 255), np.clip(b2, 0, 255), a8]).astype(np.uint8)
    out = Image.fromarray(rgba, 'RGBA')
    # 羽化 + 去杂点
    a = out.getchannel('A').filter(ImageFilter.GaussianBlur(0.8))
    a = a.point(lambda x: 0 if x < 24 else x)
    out.putalpha(a)
    return out


def rembg_cut(im: Image.Image) -> Image.Image | None:
    try:
        from rembg import remove  # type: ignore
    except Exception:
        return None
    return remove(im.convert('RGBA'))


def crop_to_content(im: Image.Image, pad: int = 8) -> Image.Image:
    bbox = im.getchannel('A').point(lambda x: 255 if x > 40 else 0).getbbox()
    if not bbox:
        return im
    x0, y0, x1, y1 = bbox
    return im.crop((max(0, x0 - pad), max(0, y0 - pad), min(im.width, x1 + pad), min(im.height, y1 + pad)))


def process(src: pathlib.Path, dst: pathlib.Path, key: str, method: str, debug: bool):
    im = Image.open(src)
    out = None
    if method in ('rembg', 'auto'):
        out = rembg_cut(im)
        if out is None and method == 'rembg':
            raise SystemExit('未安装 rembg：.venv/bin/pip install rembg  （或改用 --method key）')
    if out is None:
        out = chroma_key(im, key)
    out = crop_to_content(out)
    dst.parent.mkdir(parents=True, exist_ok=True)
    out.save(dst, 'PNG')
    if debug:
        chk = Image.new('RGBA', out.size, (0, 0, 0, 0))
        # 棋盘格底，方便肉眼检查边缘
        px = np.indices((out.height, out.width)).sum(axis=0) // 32 % 2
        board = np.where(px[..., None] == 0, 200, 140).astype(np.uint8)
        chk = Image.fromarray(np.dstack([board, board, board, np.full_like(board, 255)]), 'RGBA')
        chk.alpha_composite(out)
        chk.save(dst.with_suffix('.check.png'))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--only'); ap.add_argument('--force', action='store_true'); ap.add_argument('--debug', action='store_true')
    ap.add_argument('--method', default='key', choices=['key', 'rembg', 'auto'])
    a = ap.parse_args()
    layers = a.only.split(',') if a.only else CUTOUT_LAYERS
    n = 0
    for layer in layers:
        src_dir = RAW / layer
        if not src_dir.exists():
            continue
        for src in sorted(src_dir.glob('*.png')):
            if src.name.startswith('_'):
                continue
            dst = LAYERS / layer / src.name
            if dst.exists() and not a.force:
                continue
            key = key_color_for(layer, src.stem)
            process(src, dst, key, a.method, a.debug)
            n += 1
            print(f'  ✂ {layer}/{src.name}  ({key})')
    print(f'✔ 抠图 {n} 张 → layers/')


if __name__ == '__main__':
    main()
