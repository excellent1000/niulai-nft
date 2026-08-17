#!/usr/bin/env python
"""把成品 NFT 拼成九宫格（3×3）：listing/grids/<name>.jpg
  python pipeline/grids.py            # 需要 out/png/NNNN.png（没有的话先从服务器拉：见 README「恢复」）
  python pipeline/grids.py --list     # 只打印每个九宫格用到的 token
选片规则：按主题（稀有度 / 角色 / 混合）挑 9 枚，尽量背景、衣服、配饰互不重复；确定性随机（seed）。
"""
import argparse, glob, json, random, pathlib, sys
sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
from common import ROOT, OUT
from PIL import Image

PNG = OUT / 'png'
DST = ROOT / 'listing' / 'grids'
CELL, GAP, PAD = 1000, 12, 12          # 单格 1000px，缝 12px，外边 12px → 3048×3048
BG = (8, 6, 6)


def load_meta():
    metas = {}
    for p in glob.glob(str(OUT / 'metadata' / '*.json')):
        m = json.load(open(p, encoding='utf-8'))
        a = {x['trait_type']: x['value'] for x in m['attributes']}
        a['id'] = int(m['name'].split('#')[1]); metas[a['id']] = a
    return metas


def pick(cands, n, rnd, keys=('背景', '衣服', '配饰', '角色')):
    """贪心去重：先按所有维度不重复挑，挑不满再逐步放宽。"""
    cands = list(cands); rnd.shuffle(cands)
    chosen, used = [], {k: set() for k in keys}
    for relax in range(len(keys) + 1):
        ks = keys[:len(keys) - relax]
        for a in cands:
            if len(chosen) >= n: break
            if a in chosen: continue
            if any(a[k] in used[k] for k in ks): continue
            chosen.append(a)
            for k in keys: used[k].add(a[k])
        if len(chosen) >= n: break
    return chosen[:n]


def themes(metas):
    rnd = random.Random('niulai-grids-2026')
    by_char = {}
    for a in metas.values(): by_char.setdefault(a['角色'], []).append(a)
    tier = lambda t: [a for a in metas.values() if a['稀有度'] == t]
    T = {}
    T['01-传说与史诗'] = tier('传说') + pick(tier('史诗'), 5, rnd)
    T['02-稀有'] = pick(tier('稀有'), 9, rnd)
    for i, (label, key) in enumerate([('牛来', '牛来'), ('豹拉', '豹拉'), ('牛妈', '牛妈'), ('灵蛇', '灵蛇'), ('狼狗', '狼狗'), ('路人牛', '路人牛'), ('云雀', '云雀')], start=3):
        T[f'{i:02d}-{label}'] = pick(by_char[key], 9, rnd)
    for j in range(1, 4):
        T[f'{9 + j:02d}-混合{j}'] = pick(metas.values(), 9, rnd)
    return T


def compose(items, path):
    W = PAD * 2 + CELL * 3 + GAP * 2
    im = Image.new('RGB', (W, W), BG)
    for i, a in enumerate(items):
        p = PNG / f"{a['id']:04d}.png"
        tile = Image.open(p).convert('RGB').resize((CELL, CELL), Image.LANCZOS)
        x = PAD + (i % 3) * (CELL + GAP); y = PAD + (i // 3) * (CELL + GAP)
        im.paste(tile, (x, y))
    im.save(path, 'JPEG', quality=92, optimize=True)
    return W


def main():
    ap = argparse.ArgumentParser(); ap.add_argument('--list', action='store_true'); a = ap.parse_args()
    metas = load_meta(); T = themes(metas)
    if a.list:
        for k, v in T.items(): print(k, [x['id'] for x in v])
        print(' '.join(f"{x['id']:04d}.png" for v in T.values() for x in v)); return
    DST.mkdir(parents=True, exist_ok=True)
    for k, v in T.items():
        missing = [x['id'] for x in v if not (PNG / f"{x['id']:04d}.png").exists()]
        if missing: print(f'✘ {k}: 缺图 {missing}'); continue
        W = compose(v, DST / f'{k}.jpg'); print(f'✔ {k}.jpg  {W}×{W}  ' + ' '.join(f"#{x['id']:04d}" for x in v))


if __name__ == '__main__':
    main()
