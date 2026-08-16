"""共享：配置、确定性随机、稀有度分层、特征抽取、字体。"""
from __future__ import annotations
import hashlib, json, pathlib, random, os

ROOT = pathlib.Path(__file__).resolve().parent.parent
CFG_PATH = ROOT / 'components.json'
CFG = json.loads(CFG_PATH.read_text(encoding='utf-8'))
RAW = ROOT / 'raw'
LAYERS = ROOT / 'layers'
OUT = ROOT / 'out'

COL = CFG['collection']
SUPPLY = COL['supply']
SEED = COL['seed']
TIER_LABEL = {k: v['name'] for k, v in COL['tiers'].items()}
TIER_SHORT = {'legendary': '传说', 'epic': '史诗', 'rare': '稀有', 'common': '普通'}


def h(s: str) -> int:
    return int(hashlib.sha256(s.encode('utf-8')).hexdigest()[:16], 16)


def rng_for(token_id: int, salt: str = '') -> random.Random:
    return random.Random(h(f'{SEED}:{token_id}:{salt}'))


def weighted(rnd: random.Random, table: dict) -> str:
    items = [(k, v.get('weight', 0)) for k, v in table.items() if not k.startswith('_') and v.get('weight', 0) > 0]
    total = sum(w for _, w in items)
    r = rnd.random() * total
    for k, w in items:
        r -= w
        if r <= 0:
            return k
    return items[-1][0]


_tier_cache: dict = {}


def tier_map(supply: int = SUPPLY) -> dict:
    if supply in _tier_cache:
        return _tier_cache[supply]
    ids = list(range(1, supply + 1))
    random.Random(h(f'{SEED}:tiers')).shuffle(ids)
    m = {}
    cur = 0
    for t in ('legendary', 'epic', 'rare'):
        n = COL['tiers'][t]['count']
        for i in ids[cur:cur + n]:
            m[i] = t
        cur += n
    _tier_cache[supply] = m
    return m


def tier_of(token_id: int, supply: int = SUPPLY) -> str:
    return tier_map(supply).get(token_id, 'common')


def tokens_of_tier(tier: str, supply: int = SUPPLY) -> list[int]:
    return sorted(i for i, t in tier_map(supply).items() if t == tier)


def body_key(char: str, pose: str, face: str) -> str:
    return f'{char}__{pose}__{face}'


def roll_traits(token_id: int, supply: int = SUPPLY, override: dict | None = None, tier: str | None = None) -> dict:
    tier = tier or tier_of(token_id, supply)
    rnd = rng_for(token_id, 'traits')
    t = {
        'id': token_id,
        'tier': tier,
        'character': weighted(rnd, CFG['characters']),
        'pose': weighted(rnd, CFG['poses']),
        'face': weighted(rnd, CFG['faces']),
        'texture': weighted(rnd, CFG['textures']),
        'outfit': weighted(rnd, CFG['outfits']),
        'accessory': weighted(rnd, CFG['accessories']),
        'bg': weighted(rnd, CFG['backgrounds']),
        'fx': weighted(rnd, CFG['fx']),
        'witness': weighted(rnd, CFG['witness']),
        'quality': weighted(rnd, CFG['quality']),
    }
    if t['character'] == 'mother' and rnd.random() < 0.25:
        t['accessory'] = 'halo'
    if t['character'] == 'lark':
        t['witness'] = 'no'
    if tier == 'legendary':
        legs = tokens_of_tier('legendary', supply)
        idx = legs.index(token_id) if token_id in legs else 0
        t['character'] = ['calf', 'leopard', 'snake', 'mother'][idx % 4]
        t['pose'] = ['raise', 'stand', 'tpose', 'stand'][idx % 4]
        t.update(face='star', texture='gold', accessory='crown', bg='cinema', fx='counter', witness='yes', quality='clean', outfit='cape')
    elif tier == 'epic':
        t['accessory'] = 'ticket'
        t['bg'] = rnd.choice(['cinema', 'dream'])
        if rnd.random() < 0.5:
            t['fx'] = 'counter'
    elif tier == 'rare':
        t['fx'] = rnd.choice(['stamp', 'danmaku'])
        t['witness'] = 'yes' if t['character'] != 'lark' else 'no'
    if override:
        t.update(override)
    return t


def trait_labels(t: dict) -> dict:
    C = CFG
    return {
        '稀有度': TIER_LABEL[t['tier']],
        '角色': C['characters'][t['character']]['label'],
        '姿势': C['poses'][t['pose']]['label'],
        '五官': C['faces'][t['face']]['label'],
        '贴图': C['textures'][t['texture']]['label'],
        '衣服': C['outfits'][t['outfit']]['label'],
        '配饰': C['accessories'][t['accessory']]['label'],
        '背景': C['backgrounds'][t['bg']]['label'],
        '特效': C['fx'][t['fx']]['label'],
        '见证者': C['witness'][t['witness']]['label'],
        '画质': C['quality'][t['quality']]['label'],
    }


def metadata_for(t: dict, image_base='ipfs://<CID>/') -> dict:
    ch = CFG['characters'][t['character']]
    id4 = f"{t['id']:04d}"
    attrs = [{'trait_type': k, 'value': v} for k, v in trait_labels(t).items()]
    return {
        'name': f'牛来 #{id4}',
        'description': f"牛来 NFT #{id4}。角色：{ch['label']}，稀有度：{TIER_LABEL[t['tier']]}。共 999 枚，二级市场 10% 版税每小时买入 $牛来 并自动分发给持有者。",
        'image': f'{image_base}{id4}.png',
        'attributes': attrs,
    }


# ---------- 字体 ----------
_FONT_CANDIDATES = [
    '/System/Library/Fonts/PingFang.ttc',
    '/System/Library/Fonts/Hiragino Sans GB.ttc',
    '/System/Library/Fonts/STHeiti Medium.ttc',
    '/System/Library/Fonts/Supplemental/Songti.ttc',
    '/usr/share/fonts/opentype/noto/NotoSansCJK-Regular.ttc',
    '/usr/share/fonts/truetype/noto/NotoSansCJK-Regular.ttc',
    'C:/Windows/Fonts/msyh.ttc',
]


def find_font_path() -> str | None:
    env = os.environ.get('NIULAI_FONT')
    if env and pathlib.Path(env).exists():
        return env
    for p in _FONT_CANDIDATES:
        if pathlib.Path(p).exists():
            return p
    return None
