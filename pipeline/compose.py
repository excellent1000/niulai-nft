#!/usr/bin/env python
"""拼接：抽特征 → 背景 + 主体 + 衣服 + 配饰 + 特效 + 见证者 + 翻拍滤镜 → out/png/NNNN.png + out/metadata/NNNN.json

  python pipeline/compose.py --count 24 --sheet
  python pipeline/compose.py --ids 1,2,3 --debug-anchors
  python pipeline/compose.py --count 12 --set character=leopard,pose=stand   # 固定某些特征试效果
"""
from __future__ import annotations
import argparse, json, math, pathlib, sys
import numpy as np
from PIL import Image, ImageDraw, ImageFilter, ImageFont, ImageOps
sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
from common import CFG, RAW, LAYERS, OUT, SUPPLY, roll_traits, trait_labels, metadata_for, body_key, rng_for, find_font_path, TIER_SHORT

S = CFG['canvas']
FONT_PATH = find_font_path()
_font_cache: dict = {}


def font(size: int, bold: bool = False):
    k = (size, bold)
    if k not in _font_cache:
        try:
            idx = 1 if (bold and FONT_PATH and FONT_PATH.endswith('PingFang.ttc')) else 0
            _font_cache[k] = ImageFont.truetype(FONT_PATH, size, index=idx) if FONT_PATH else ImageFont.load_default()
        except Exception:
            _font_cache[k] = ImageFont.load_default()
    return _font_cache[k]


# ---------- 图层加载 ----------
_img_cache: dict = {}


def load_layer(layer: str, name: str) -> Image.Image | None:
    p = LAYERS / layer / f'{name}.png'
    if not p.exists():
        p = RAW / layer / f'{name}.png' if layer == 'bg' else p
    if not p.exists():
        return None
    if p not in _img_cache:
        _img_cache[p] = Image.open(p).convert('RGBA')
    return _img_cache[p]


def load_body(char: str, pose: str, face: str, warn: list, outfit: str = 'none'):
    """返回 (image, dressed)。dressed=True 表示用的是"衣服穿在身上生成"的主体，拼接时不再叠衣服贴纸。"""
    if outfit != 'none':
        im = load_layer('body', f'{body_key(char, pose, face)}__{outfit}')
        if im is not None:
            return im, True
    for cand in (body_key(char, pose, face), body_key(char, pose, 'bean'), body_key(char, 'stand', face), body_key(char, 'stand', 'bean')):
        im = load_layer('body', cand)
        if im is not None:
            if cand != body_key(char, pose, face):
                warn.append(f'主体回退 {body_key(char, pose, face)} → {cand}')
            return im, False
    warn.append(f'缺少主体 {char}')
    return None, False


def body_parts(body: Image.Image, anchors: dict, box, parts: list) -> Image.Image:
    """从（已缩放到画布尺寸的）主体里抠出 头 / 手臂 区域，用于盖回衣服上面制造遮挡。"""
    a = np.asarray(body.getchannel('A')).astype(np.uint8)
    H, W = a.shape
    x0, y0, x1, y1 = box
    mask = np.zeros_like(a)
    neck_y = int(anchors['neck'][1] * H)
    if 'head' in parts:
        c0, c1 = int(W * 0.18), int(W * 0.82)
        mask[:neck_y + int(0.02 * H), c0:c1] = 255
    if 'arms' in parts:
        tw = anchors.get('torso_w', 0.55)
        cx = anchors['torso'][0] * W
        half = tw * W * 0.5
        top = neck_y + int(0.03 * H); bot = int(0.78 * H)
        m2 = np.zeros_like(a); m2[top:bot, :] = 255
        xs = np.arange(W)[None, :]
        m2 = np.where((np.abs(xs - cx) > half), m2, 0)
        mask = np.maximum(mask, m2)
    part = body.copy()
    part.putalpha(Image.fromarray(np.minimum(a, mask), 'L'))
    return part


def fit_cover(im: Image.Image, w: int, h: int) -> Image.Image:
    return ImageOps.fit(im, (w, h), Image.LANCZOS)


def paste_center(canvas: Image.Image, im: Image.Image, cx: float, cy: float, width: float | None = None, height: float | None = None,
                 anchor: str = 'center', rotate: float = 0):
    if im is None:
        return
    if width is not None:
        sc = width / im.width
    elif height is not None:
        sc = height / im.height
    else:
        sc = 1
    im2 = im.resize((max(1, int(im.width * sc)), max(1, int(im.height * sc))), Image.LANCZOS)
    if rotate:
        im2 = im2.rotate(rotate, expand=True, resample=Image.BICUBIC)
    if anchor == 'center':
        x, y = cx - im2.width / 2, cy - im2.height / 2
    elif anchor == 'bottom':
        x, y = cx - im2.width / 2, cy - im2.height
    elif anchor == 'top':
        x, y = cx - im2.width / 2, cy
    else:
        x, y = cx, cy
    canvas.alpha_composite(im2, (int(x), int(y)))


# ---------- 贴图后处理（作用于主体 RGBA） ----------
def texture_fx(body: Image.Image, kind: str, rnd) -> Image.Image:
    if kind == 'flat':
        return body
    arr = np.asarray(body).astype(np.float32)
    a = arr[..., 3:4] / 255.0
    rgb = arr[..., :3]
    lum = (0.299 * rgb[..., 0] + 0.587 * rgb[..., 1] + 0.114 * rgb[..., 2])[..., None] / 255.0
    H, W = arr.shape[:2]
    if kind == 'seams':
        yy, xx = np.indices((H, W))
        step = max(24, int(min(H, W) / 14))
        grid = ((xx % step) < 2) | ((yy % step) < 2)
        rgb = np.where(grid[..., None], rgb * 0.62, rgb)
    elif kind == 'missing':
        yy, xx = np.indices((H, W))
        step = max(16, int(min(H, W) / 16))
        chk = ((xx // step + yy // step) % 2 == 0)
        col = np.where(chk[..., None], np.array([255, 0, 220], np.float32), np.array([20, 20, 20], np.float32))
        shade = 0.55 + 0.6 * lum
        # 只丢一部分贴图（随机一块区域）或整个身体
        if rnd.random() < 0.75:
            cx, cy, r = rnd.uniform(0.3, 0.7) * W, rnd.uniform(0.2, 0.7) * H, rnd.uniform(0.18, 0.34) * min(H, W)
            region = ((xx - cx) ** 2 + (yy - cy) ** 2) < r * r
            rgb = np.where(region[..., None], col * shade, rgb)
        else:
            rgb = col * shade
    elif kind == 'gold':
        dark = np.array([120, 84, 20], np.float32); light = np.array([255, 226, 120], np.float32)
        rgb = dark + (light - dark) * np.clip(lum * 1.15, 0, 1)
        # 加一点硬高光条纹
        yy, xx = np.indices((H, W))
        stripe = ((xx + yy) % 90) < 10
        rgb = np.where(stripe[..., None], np.minimum(255, rgb + 40), rgb)
    out = np.dstack([np.clip(rgb, 0, 255), arr[..., 3]]).astype(np.uint8)
    return Image.fromarray(out, 'RGBA')


# ---------- 特效（代码绘制） ----------
def outlined_text(d: ImageDraw.ImageDraw, xy, text, size, fill, outline=(0, 0, 0), width=4, bold=True, anchor='la'):
    f = font(size, bold)
    d.text(xy, text, font=f, fill=fill, stroke_width=width, stroke_fill=outline, anchor=anchor)


def draw_fx(canvas: Image.Image, kind: str, rnd, body_box):
    d = ImageDraw.Draw(canvas)
    if kind == 'danmaku':
        pool = list(CFG['danmaku_pool']); rnd.shuffle(pool)
        specs = [((30, 70), 44, (255, 255, 255)), ((S * 0.45, 190), 36, (255, 224, 102)), ((60, S * 0.78), 40, (255, 255, 255)), ((S * 0.5, S * 0.93), 34, (142, 227, 255))]
        for (xy, size, col), txt in zip(specs, pool[:4]):
            outlined_text(d, xy, txt, size, col)
    elif kind == 'clipnote':
        x0, y0, x1, y1 = body_box
        cx, cy = (x0 + x1) / 2, y0 + (y1 - y0) * 0.55
        rx, ry = (x1 - x0) * 0.42, (y1 - y0) * 0.16
        d.ellipse([cx - rx, cy - ry, cx + rx, cy + ry], outline=(200, 65, 43), width=8)
        ax, ay = cx + rx, cy - ry * 0.4
        bx, by = min(S - 40, ax + 150), max(60, ay - 110)
        d.line([ax, ay, bx, by], fill=(200, 65, 43), width=8)
        d.polygon([(ax, ay), (ax + 34, ay - 26), (ax + 22, ay + 12)], fill=(200, 65, 43))
        outlined_text(d, (bx + 6, by - 30), '穿模', 52, (200, 65, 43), outline=(255, 255, 255), width=6)
    elif kind == 'counter':
        d.rounded_rectangle([26, 26, 26 + 340, 26 + 112], radius=14, fill=(17, 17, 17, 225))
        d.text((44, 44), '累计票房 · 上映第10天', font=font(20), fill=(187, 187, 187))
        d.text((44, 74), '¥7,705', font=font(50, True), fill=(227, 201, 58))
    elif kind == 'limitup':
        w = 300
        d.rounded_rectangle([S - w - 26, 26, S - 26, 26 + 76], radius=10, fill=(181, 48, 28))
        d.text((S - w - 6, 40), '牛来 +10.00% ▲', font=font(34, True), fill=(255, 255, 255))
    elif kind == 'stamp':
        stamp = Image.new('RGBA', (260, 260), (0, 0, 0, 0))
        sd = ImageDraw.Draw(stamp)
        sd.ellipse([8, 8, 252, 252], outline=(200, 65, 43, 235), width=9)
        sd.ellipse([26, 26, 234, 234], outline=(200, 65, 43, 235), width=3)
        sd.text((130, 130), '加场', font=font(74, True), fill=(200, 65, 43, 235), anchor='mm')
        stamp = stamp.rotate(18, resample=Image.BICUBIC, expand=False)
        canvas.alpha_composite(stamp, (S - 300, 60))


# ---------- 翻拍滤镜 ----------
def filmlook(im: Image.Image, rnd) -> Image.Image:
    rgb = im.convert('RGB')
    rgb = rgb.resize((int(S * 0.9), int(S * 0.9)), Image.BILINEAR).resize((S, S), Image.BICUBIC)   # 糊一点
    rgb = rgb.filter(ImageFilter.GaussianBlur(0.6))
    arr = np.asarray(rgb).astype(np.float32)
    arr = arr * 0.86 + 22                                    # 提黑
    arr[..., 0] *= 1.02; arr[..., 2] *= 0.97                # 一点点偏暖
    noise = np.random.default_rng(rnd.randrange(1 << 30)).normal(0, 5.5, arr.shape)
    arr = arr + noise
    # 暗角
    yy, xx = np.indices((S, S))
    dist = np.sqrt(((xx - S / 2) / (S / 2)) ** 2 + ((yy - S / 2) / (S / 2)) ** 2)
    vign = np.clip(1.0 - 0.32 * (dist ** 2.2), 0.6, 1.0)
    arr = arr * vign[..., None]
    # 屏幕反光：左上一片淡淡的亮斑
    glare = np.clip(1.0 - np.sqrt(((xx - S * 0.2) / (S * 0.5)) ** 2 + ((yy - S * 0.15) / (S * 0.35)) ** 2), 0, 1) * 26
    arr = arr + glare[..., None]
    out = Image.fromarray(np.clip(arr, 0, 255).astype(np.uint8), 'RGB').convert('RGBA')
    d = ImageDraw.Draw(out)
    bar = int(S * 0.065)
    d.rectangle([0, 0, S, bar], fill=(6, 5, 5, 255)); d.rectangle([0, S - bar, S, S], fill=(6, 5, 5, 255))
    # 前排座椅剪影（偶尔）
    if rnd.random() < 0.55:
        for i in range(rnd.randint(1, 3)):
            w = rnd.randint(int(S * 0.22), int(S * 0.36)); x = rnd.randint(-w // 3, S - w * 2 // 3)
            h = rnd.randint(int(S * 0.08), int(S * 0.16))
            d.rounded_rectangle([x, S - bar - h, x + w, S], radius=26, fill=(9, 8, 8, 255))
    return out


# ---------- 自动锚点：从主体 alpha 推断 头顶 / 手 / 躯干 ----------
def auto_anchors(body: Image.Image, pose: str, kind_snake: bool) -> dict:
    """返回相对 bbox 的归一化坐标 (0..1)，键同 components.json anchors。"""
    a = np.asarray(body.getchannel('A')) > 60
    H, W = a.shape
    ys, xs = np.nonzero(a)
    if len(xs) == 0:
        return {}
    cx = 0.5
    # 头顶：中间 ±22% 列里最高的不透明像素
    c0, c1 = int(W * 0.28), int(W * 0.72)
    mid = a[:, c0:c1]
    rows = np.nonzero(mid.any(axis=1))[0]
    head_top_y = rows[0] / H if len(rows) else 0.0
    # 全图最高点（举手时是手）
    top_y = ys.min(); top_x = np.median(xs[ys == top_y]) / W
    # 最左/最右
    right_x = xs.max(); right_y = np.median(ys[xs == right_x]) / H
    left_x = xs.min(); left_y = np.median(ys[xs == left_x]) / H
    if kind_snake:  # 蛇的头在弯管顶端，不一定在中间
        cx, head_top_y = float(top_x), top_y / H
    out = {'head_top': [cx, head_top_y]}
    out['head'] = [cx, head_top_y + 0.11 * (1 - head_top_y)]
    out['face'] = [cx, head_top_y + 0.13 * (1 - head_top_y)]
    out['mouth'] = [cx, head_top_y + 0.20 * (1 - head_top_y)]
    out['neck'] = [cx, head_top_y + 0.27 * (1 - head_top_y)]
    out['chest'] = [cx, head_top_y + 0.42 * (1 - head_top_y)]
    out['torso'] = [cx, head_top_y + 0.48 * (1 - head_top_y)]
    out['belly'] = [cx, head_top_y + 0.58 * (1 - head_top_y)]
    if kind_snake:
        out['hand'] = [cx, 0.42]
    elif pose == 'raise' and abs(top_x - 0.5) > 0.14 and top_y / H < head_top_y - 0.03:
        out['hand'] = [top_x, top_y / H + 0.02]
    elif pose == 'tpose':
        out['hand'] = [right_x / W - 0.02, right_y]
    else:
        # 直立：下半身带里最靠右的点
        band = a[int(H * 0.45):int(H * 0.8), :]
        bx = np.nonzero(band.any(axis=0))[0]
        if len(bx):
            rx = bx.max(); ry = (int(H * 0.45) + np.median(np.nonzero(band[:, rx])[0])) / H
            out['hand'] = [rx / W - 0.02, ry]
        else:
            out['hand'] = [0.9, 0.6]
    return out


# ---------- 合成一枚 ----------
def compose(t: dict, debug_anchors=False):
    warn = []
    rnd = rng_for(t['id'], 'compose')
    canvas = Image.new('RGBA', (S, S), (60, 60, 60, 255))
    # 背景
    bg = load_layer('bg', t['bg'])
    if bg is not None:
        canvas.alpha_composite(fit_cover(bg, S, S))
        if t['bg'] == 'limitdown':  # 模型总把「跌停」写错，用代码盖掉重画
            d0 = ImageDraw.Draw(canvas)
            d0.rounded_rectangle([S - 340, 14, S - 14, 104], radius=12, fill=(20, 110, 55, 255))
            d0.text((S - 322, 30), '跌停 -10.00% ▼', font=font(38, True), fill=(255, 255, 255))
    else:
        warn.append(f"缺少背景 {t['bg']}")
        ImageDraw.Draw(canvas).rectangle([0, S * 0.55, S, S], fill=(76, 122, 58, 255))
        ImageDraw.Draw(canvas).rectangle([0, 0, S, S * 0.55], fill=(127, 178, 217, 255))
    # 主体归一化（若存在"衣服穿在身上生成"的主体，优先用它）
    outfit = t['outfit']
    body, dressed = load_body(t['character'], t['pose'], t['face'], warn, outfit)
    ch = CFG['characters'][t['character']]
    anchors = dict(CFG['anchors']['snake' if t['character'] == 'snake' else t['pose']])
    body_box = (S * 0.3, S * 0.13, S * 0.7, S * 0.93)
    body_r = None
    if body is not None:
        anchors.update(auto_anchors(body, t['pose'], t['character'] == 'snake'))
        body = texture_fx(body, t['texture'], rnd)
        bh = S * 0.80
        sc = bh / body.height
        bw = body.width * sc
        if bw > S * 0.96:  # T-pose 太宽时按宽度限制
            sc = S * 0.96 / body.width; bw = body.width * sc; bh = body.height * sc
        body_r = body.resize((int(bw), int(bh)), Image.LANCZOS)
        bx = (S - bw) / 2; by = S * 0.93 - bh
        body_box = (bx, by, bx + bw, by + bh)

    def A(name):
        ax, ay = anchors[name]
        x0, y0, x1, y1 = body_box
        return x0 + ax * (x1 - x0), y0 + ay * (y1 - y0)
    x0, y0, x1, y1 = body_box
    bw_, bh_ = x1 - x0, y1 - y0
    ocfg = CFG['outfits'].get(outfit, {})
    use_overlay = outfit != 'none' and not dressed

    # 披风（主体之后）
    if use_overlay and ocfg.get('z') == 'behind':
        im = load_layer('outfit', outfit)
        if im is None:
            warn.append(f'缺少衣服 {outfit}')
        else:
            nx, ny = A('neck')
            paste_center(canvas, im, nx, ny - 0.02 * bh_, width=bw_ * (1.05 if t['pose'] == 'tpose' else 1.35), anchor='top')
    if body_r is not None:
        canvas.alpha_composite(body_r, (int(x0), int(y0)))
    # 前层衣服（贴纸）+ 遮挡修补：把主体的头/手臂盖回衣服上面
    if use_overlay and ocfg.get('z') == 'front':
        im = load_layer('outfit', outfit)
        if im is None:
            warn.append(f'缺少衣服 {outfit}')
        else:
            slot = ocfg.get('slot')
            if slot == 'neck':
                nx, ny = A('neck'); paste_center(canvas, im, nx, ny - 0.01 * bh_, width=bw_ * 0.5, anchor='top')
            else:
                # 用肩宽（脖子下方一点的主体宽度）决定衣服宽度
                a_ = np.asarray(body_r.getchannel('A')) > 60
                sy = min(body_r.height - 1, int((anchors['neck'][1] + 0.05) * body_r.height))
                cols = np.nonzero(a_[sy])[0]
                shoulder_w = (cols.max() - cols.min()) if len(cols) else bw_ * anchors['torso_w']
                if t['pose'] == 'tpose':          # T-pose 时肩线那一行就是整个臂展，改用配置的躯干宽
                    gw = bw_ * anchors.get('torso_w', 0.42) * 1.15
                else:
                    gw = min(shoulder_w * 1.08, bw_ * 0.85)
                tx, ty = A('torso'); paste_center(canvas, im, tx, ty, width=gw)
            if body_r is not None and ocfg.get('occlude'):
                part = body_parts(body_r, anchors, body_box, ocfg['occlude'])
                canvas.alpha_composite(part, (int(x0), int(y0)))
    # 配饰
    acc = t['accessory']
    if acc != 'none':
        im = load_layer('accessory', acc)
        if im is None:
            warn.append(f'缺少配饰 {acc}')
        else:
            slot = CFG['accessories'][acc]['slot']
            if slot == 'hand':
                hx, hy = A('hand'); paste_center(canvas, im, hx, hy, height=bh_ * 0.24, rotate=rnd.uniform(-12, 12))
            elif slot == 'face':
                fx_, fy = A('face'); paste_center(canvas, im, fx_, fy, width=bw_ * (0.42 if t['pose'] != 'tpose' else 0.30))
            elif slot == 'head':
                if CFG['accessories'][acc].get('place') == 'over':
                    hx, hy = A('head'); paste_center(canvas, im, hx, hy - 0.01 * bh_, width=bw_ * (0.5 if t['pose'] != 'tpose' else 0.34))
                else:
                    hx, hy = A('head_top'); paste_center(canvas, im, hx, hy + 0.04 * bh_, width=bw_ * (0.42 if t['pose'] != 'tpose' else 0.3), anchor='bottom')
            elif slot == 'mouth':
                mx, my = A('mouth'); paste_center(canvas, im, mx, my, width=bw_ * (0.34 if t['pose'] != 'tpose' else 0.24))
            elif slot == 'chest':
                cx, cy = A('chest'); paste_center(canvas, im, cx, cy, width=bw_ * 0.26)
            elif slot == 'halo':
                hx, hy = A('head_top'); paste_center(canvas, im, hx, hy - 0.05 * bh_, width=bw_ * (0.6 if t['pose'] != 'tpose' else 0.4))
    # 见证者
    if t['witness'] == 'yes':
        lark = load_layer('body', body_key('lark', 'stand', 'bean'))
        if lark is not None:
            paste_center(canvas, lark, S * 0.86, S * 0.16, height=S * 0.17)
        else:
            warn.append('缺少云雀（见证者）')
    # 特效
    draw_fx(canvas, t['fx'], rnd, body_box)
    # 画质
    if t['quality'] == 'filmlook':
        canvas = filmlook(canvas, rnd)
    if debug_anchors:
        d = ImageDraw.Draw(canvas)
        for name in ('hand', 'head', 'head_top', 'face', 'chest', 'belly', 'torso', 'neck'):
            x, y = A(name); d.ellipse([x - 7, y - 7, x + 7, y + 7], fill=(255, 0, 0, 255)); d.text((x + 9, y - 8), name, font=font(18), fill=(255, 255, 0))
        d.rectangle(body_box, outline=(255, 0, 0, 255), width=2)
    return canvas.convert('RGB'), warn


def contact_sheet(paths: list[pathlib.Path], cols=6, cell=300) -> Image.Image:
    rows = math.ceil(len(paths) / cols)
    sheet = Image.new('RGB', (cols * cell, rows * cell), (17, 17, 17))
    for i, p in enumerate(paths):
        im = Image.open(p).convert('RGB').resize((cell, cell), Image.LANCZOS)
        sheet.paste(im, ((i % cols) * cell, (i // cols) * cell))
    return sheet


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--count', type=int, default=12); ap.add_argument('--ids'); ap.add_argument('--from', dest='from_', type=int, default=1)
    ap.add_argument('--supply', type=int, default=SUPPLY); ap.add_argument('--out', default=str(OUT))
    ap.add_argument('--sheet', action='store_true'); ap.add_argument('--debug-anchors', action='store_true')
    ap.add_argument('--set', help='固定特征，如 character=leopard,pose=stand,accessory=ticket')
    ap.add_argument('--tier', choices=['legendary', 'epic', 'rare', 'common'])
    a = ap.parse_args()
    out = pathlib.Path(a.out); (out / 'png').mkdir(parents=True, exist_ok=True); (out / 'metadata').mkdir(parents=True, exist_ok=True)
    ids = [int(x) for x in a.ids.split(',')] if a.ids else list(range(a.from_, a.from_ + a.count))
    override = dict(kv.split('=') for kv in a.set.split(',')) if a.set else None
    paths = []; allwarn = {}
    for i in ids:
        t = roll_traits(i, a.supply, override, tier=a.tier)
        img, warn = compose(t, a.debug_anchors)
        p = out / 'png' / f'{i:04d}.png'; img.save(p, 'PNG', optimize=True); paths.append(p)
        (out / 'metadata' / f'{i:04d}.json').write_text(json.dumps(metadata_for(t), ensure_ascii=False, indent=2), encoding='utf-8')
        lab = trait_labels(t)
        print(f"#{i:04d} {TIER_SHORT[t['tier']]} {lab['角色']:<4} {lab['姿势']}/{lab['五官']}/{lab['贴图']}/{lab['衣服']}/{lab['配饰']}/{lab['背景']}/{lab['特效']}/{lab['画质']}" + (f"   ⚠ {'; '.join(warn)}" if warn else ''))
        for w in warn:
            allwarn[w] = allwarn.get(w, 0) + 1
    if a.sheet:
        sh = contact_sheet(paths, cols=min(6, len(paths)))
        sh.save(out / 'sheet.png'); print(f'→ {out}/sheet.png')
    if allwarn:
        print('缺失汇总:', json.dumps(allwarn, ensure_ascii=False))
    print(f'✔ {len(ids)} 枚 → {out}/png')


if __name__ == '__main__':
    main()
