#!/usr/bin/env python
"""按 components.json 批量生图 → raw/<layer>/<name>.png

  python pipeline/gen_components.py --only body --stage base            # 7 个角色的基准图（直立/豆眼）
  python pipeline/gen_components.py --only body --stage variants        # 以基准图为参考，生成姿势×五官变体
  python pipeline/gen_components.py --only outfit,accessory,bg          # 衣服 / 配饰 / 背景
  python pipeline/gen_components.py --all                               # 全部
  选项：--chars calf,leopard  --poses stand,tpose  --faces bean,dead  --force  --mock  --dry
        --limit N  --workers 2  --style-ref refs/still.jpg  --export-prompts
"""
from __future__ import annotations
import argparse, io, sys, pathlib, concurrent.futures as cf, time
sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
from common import CFG, RAW, ROOT, body_key
from ark import Ark, MockArk, ArkError, load_env

STYLE = CFG['style']


def key_text(key: str) -> str:
    return STYLE['keys'].get(key, STYLE['keys']['green'])


def resolve_style_ref(a) -> str | None:
    """--style-ref 优先；否则用 components.json 里的 style_ref（存在才用）；--no-style-ref 关闭。"""
    if getattr(a, 'no_style_ref', False):
        return None
    if a.style_ref:
        return a.style_ref
    cfg_ref = STYLE.get('style_ref')
    if cfg_ref and (ROOT / cfg_ref).exists():
        return str(ROOT / cfg_ref)
    return None


def build_jobs(a) -> list[dict]:
    jobs = []
    only = set(a.only.split(',')) if a.only else {'body', 'outfit', 'accessory', 'bg'}
    chars = a.chars.split(',') if a.chars else list(CFG['characters'].keys())
    poses = a.poses.split(',') if a.poses else list(CFG['poses'].keys())
    faces = a.faces.split(',') if a.faces else list(CFG['faces'].keys())
    sref = resolve_style_ref(a)
    p_base = (STYLE.get('ref_prefix_base', '') + ' ') if sref else ''
    p_var = (' ' + STYLE.get('ref_prefix_variant', '')) if sref else ''
    p_prop = (STYLE.get('ref_prefix_prop', '') + ' ') if sref else ''

    if 'body' in only:
        for c in chars:
            ch = CFG['characters'][c]
            key = key_text(ch.get('key', 'green'))
            framing = STYLE['framing_char'].replace('{KEY}', key)
            pose_txt = lambda p: (ch.get('poses') or {}).get(p) or CFG['poses'][p]['prompt']
            base_out = RAW / 'body' / f"{body_key(c, 'stand', 'bean')}.png"
            char_refs = [str(ROOT / r) for r in ch.get('refs', []) if (ROOT / r).exists()][:3]
            if a.stage in ('base', 'all'):
                if char_refs:
                    standing = ch.get('standing') or STYLE.get('default_standing', '两脚直立、双臂下垂的标准站姿')
                    prefix = STYLE.get('ref_prefix_char', '').replace('{KEY}', key).replace('{POSE}', standing) + ' '
                    refs = char_refs
                else:
                    prefix = p_base
                    refs = [sref] if sref else []
                prompt = f"{prefix}{ch['prompt']} {pose_txt('stand')} {CFG['faces']['bean']['prompt']} {STYLE['char']} {framing}"
                jobs.append({'layer': 'body', 'name': body_key(c, 'stand', 'bean'), 'prompt': prompt, 'refs': refs, 'out': base_out, 'char': c})
            if a.stage in ('variants', 'all'):
                second = char_refs[0] if char_refs else sref
                for p in poses:
                    for f in faces:
                        if p == 'stand' and f == 'bean':
                            continue
                        suffix = STYLE.get('variant_suffix', '').replace('{CHAR}', ch['prompt'])
                        prompt = (f"{STYLE['variant_prefix'].replace('{KEY}', key)} {pose_txt(p)} {CFG['faces'][f]['prompt']} "
                                  f"其余一切保持不变。{p_var if second else ''} {suffix} {STYLE['char']} {framing}")
                        jobs.append({'layer': 'body', 'name': body_key(c, p, f), 'prompt': prompt,
                                     'refs': [str(base_out)] + ([second] if second else []),
                                     'out': RAW / 'body' / f'{body_key(c, p, f)}.png', 'char': c, 'needs': base_out})
    if 'body' in only and a.stage == 'outfits':
        # "穿在身上"生成：图1=角色某姿势某五官的主体，图2=衣服；输出 body/<char>__<pose>__<face>__<outfit>.png
        wanted = a.outfits.split(',') if a.outfits else [k for k, v in CFG['outfits'].items() if v.get('bake')]
        used = None
        if getattr(a, 'used_only', False):
            from common import roll_traits, SUPPLY
            used = set()
            for i in range(1, SUPPLY + 1):
                t = roll_traits(i)
                if t['outfit'] != 'none':
                    used.add((t['character'], t['pose'], t['face'], t['outfit']))
        for c in chars:
            ch = CFG['characters'][c]
            key = key_text(ch.get('key', 'green'))
            framing = STYLE['framing_char'].replace('{KEY}', key)
            for p in poses:
                for f in faces:
                    src = RAW / 'body' / f'{body_key(c, p, f)}.png'
                    for o in wanted:
                        it = CFG['outfits'][o]
                        if not it.get('bake'):
                            continue
                        if used is not None and (c, p, f, o) not in used:
                            continue
                        garment = RAW / 'outfit' / f'{o}.png'
                        refs = [str(src)] + ([str(garment)] if garment.exists() else [])
                        prompt = (f"{STYLE['wear_prefix'].replace('{KEY}', key)}{it.get('wear') or it['prompt']} "
                                  f"{STYLE['char']} {framing}")
                        jobs.append({'layer': 'body', 'name': f'{body_key(c, p, f)}__{o}', 'prompt': prompt, 'refs': refs,
                                     'out': RAW / 'body' / f'{body_key(c, p, f)}__{o}.png', 'char': c, 'needs': src})
    if 'outfit' in only:
        for k, it in CFG['outfits'].items():
            if not it.get('prompt'):
                continue
            prompt = f"{p_prop}{it['prompt']} {STYLE['char']} {STYLE['framing_prop'].replace('{KEY}', key_text(it.get('key', 'green')))}"
            jobs.append({'layer': 'outfit', 'name': k, 'prompt': prompt, 'refs': [sref] if sref else [], 'out': RAW / 'outfit' / f'{k}.png'})
    if 'accessory' in only:
        for k, it in CFG['accessories'].items():
            if not it.get('prompt'):
                continue
            prompt = f"{p_prop}{it['prompt']} {STYLE['char']} {STYLE['framing_prop'].replace('{KEY}', key_text(it.get('key', 'green')))}"
            jobs.append({'layer': 'accessory', 'name': k, 'prompt': prompt, 'refs': [sref] if sref else [], 'out': RAW / 'accessory' / f'{k}.png'})
    if 'bg' in only:
        for k, it in CFG['backgrounds'].items():
            bg_refs = [str(ROOT / r) for r in (STYLE.get('bg_refs') or {}).get(k, []) if (ROOT / r).exists()]
            if bg_refs:
                prompt = f"{STYLE.get('ref_prefix_bg', '')} {it['prompt']} {STYLE['char']} {STYLE['framing_bg']}"
            else:
                prompt = f"{p_prop}{it['prompt']} {STYLE['char']} {STYLE['framing_bg']}"
                bg_refs = [sref] if sref else []
            jobs.append({'layer': 'bg', 'name': k, 'prompt': prompt, 'refs': bg_refs, 'out': RAW / 'bg' / f'{k}.png'})
    return jobs


def save_png(data: bytes, out: pathlib.Path, size: int):
    from PIL import Image
    im = Image.open(io.BytesIO(data)).convert('RGB')
    if max(im.size) != size:
        im = im.resize((size, size), Image.LANCZOS) if im.size[0] == im.size[1] else im.resize((size, int(size * im.size[1] / im.size[0])), Image.LANCZOS)
    out.parent.mkdir(parents=True, exist_ok=True)
    im.save(out, 'PNG')


def run_job(client, job, a):
    out: pathlib.Path = job['out']
    if out.exists() and not a.force:
        return 'skip'
    if job.get('needs') and not job['needs'].exists():
        return f"缺少基准图 {job['needs'].name}，先跑 --stage base"
    t0 = time.time()
    data = client.generate(job['prompt'], refs=job['refs'] or None)
    save_png(data, out, CFG['canvas'])
    return f'ok {time.time() - t0:.0f}s'


def export_prompts(jobs):
    p = ROOT / 'prompts' / 'PROMPTS.md'
    p.parent.mkdir(exist_ok=True)
    lines = ['# 牛来 NFT 组件生图 Prompt 清单\n', '手动生图时按此清单逐张生成，保存为对应文件名放到 `raw/<layer>/` 下，再跑 `cutout.py` 与 `compose.py`。\n']
    cur = None
    for j in jobs:
        if j['layer'] != cur:
            cur = j['layer']; lines.append(f"\n## {cur}\n")
        ref = f"（参考图：{', '.join(pathlib.Path(r).name for r in j['refs'])}）" if j['refs'] else ''
        lines.append(f"### `raw/{j['layer']}/{j['name']}.png` {ref}\n\n{j['prompt']}\n")
    p.write_text('\n'.join(lines), encoding='utf-8')
    print(f'→ {p}')


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--only'); ap.add_argument('--all', action='store_true')
    ap.add_argument('--stage', default='all', choices=['base', 'variants', 'outfits', 'all'])
    ap.add_argument('--outfits', help='outfits 阶段只生成这些衣服，如 scarf,vest')
    ap.add_argument('--used-only', action='store_true', help='outfits 阶段只烤 supply 里真正会出现的 角色×姿势×五官×衣服 组合')
    ap.add_argument('--chars'); ap.add_argument('--poses'); ap.add_argument('--faces')
    ap.add_argument('--force', action='store_true'); ap.add_argument('--mock', action='store_true'); ap.add_argument('--dry', action='store_true')
    ap.add_argument('--limit', type=int); ap.add_argument('--workers', type=int, default=2)
    ap.add_argument('--style-ref'); ap.add_argument('--no-style-ref', action='store_true'); ap.add_argument('--export-prompts', action='store_true')
    a = ap.parse_args()
    if a.all:
        a.only = None
    load_env()
    jobs = build_jobs(a)
    if a.export_prompts:
        export_prompts(jobs); return
    if a.limit:
        jobs = jobs[:a.limit]
    print(f'共 {len(jobs)} 个生图任务' + ('（dry-run，只打印）' if a.dry else ''))
    if a.dry:
        for j in jobs:
            print(f"- [{j['layer']}] {j['name']}  refs={[pathlib.Path(r).name for r in j['refs']]}\n    {j['prompt'][:140]}…")
        return
    client = MockArk() if a.mock else Ark()
    print('模型:', client.model)
    # base 必须先于 variants（同一批时按依赖排序）
    base_jobs = [j for j in jobs if j['layer'] == 'body' and not j.get('needs')]
    other = [j for j in jobs if j not in base_jobs]
    for batch, title in ((base_jobs, '基准图'), (other, '其余')):
        if not batch:
            continue
        print(f'— {title}：{len(batch)} 张，{a.workers} 并发')
        with cf.ThreadPoolExecutor(max_workers=a.workers) as ex:
            futs = {ex.submit(run_job, client, j, a): j for j in batch}
            for fut in cf.as_completed(futs):
                j = futs[fut]
                try:
                    r = fut.result()
                except ArkError as e:
                    r = f'FAIL {str(e)[:200]}'
                except Exception as e:  # noqa
                    r = f'FAIL {type(e).__name__}: {str(e)[:200]}'
                print(f"  [{j['layer']}] {j['name']:<28} {r}")


if __name__ == '__main__':
    main()
