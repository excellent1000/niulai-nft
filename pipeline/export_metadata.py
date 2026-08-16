#!/usr/bin/env python
"""把 out/metadata/NNNN.json 转成链上用的 tokenURI 文件：out/chain/{1..999}.json（文件名不补零，配合合约 tokenURI = baseURI + id + ".json"）

  自建服务器：python pipeline/export_metadata.py --image-base https://niulai.xyz/img/ --external https://niulai.xyz --vault 0x...
              → 把 out/png 放到服务器 /img/，out/chain 放到 /meta/，合约 baseURI = https://niulai.xyz/meta/
  IPFS：      python pipeline/export_metadata.py --image-cid bafy... → 上传 out/chain 得到 META_CID → baseURI = ipfs://META_CID/
  同时生成 out/chain/collection.json（contractURI）与 out/chain/unrevealed.json
"""
import argparse, json, pathlib, sys
sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
from common import OUT, CFG

ap = argparse.ArgumentParser()
ap.add_argument('--image-cid', help='IPFS 图片目录 CID（与 --image-base 二选一）')
ap.add_argument('--image-base', help='自建服务器图片目录 URL，如 https://niulai.xyz/img/（与 --image-cid 二选一）')
ap.add_argument('--external', default='https://niulai.example')
ap.add_argument('--vault', default='0x0000000000000000000000000000000000000000')
ap.add_argument('--cover', default='0001.png', help='合集头图文件名（在图片目录里）')
a = ap.parse_args()
if not a.image_cid and not a.image_base:
    ap.error('需要 --image-cid 或 --image-base')
IMG = (a.image_base.rstrip('/') + '/') if a.image_base else f'ipfs://{a.image_cid}/'

src = OUT / 'metadata'; dst = OUT / 'chain'; dst.mkdir(parents=True, exist_ok=True)
n = 0
for p in sorted(src.glob('*.json')):
    m = json.loads(p.read_text(encoding='utf-8'))
    tid = int(p.stem)
    m['image'] = f"{IMG}{tid:04d}.png"
    m['external_url'] = f"{a.external}/token/{tid}"
    (dst / f'{tid}.json').write_text(json.dumps(m, ensure_ascii=False, indent=2), encoding='utf-8'); n += 1

col = CFG['collection']
(dst / 'collection.json').write_text(json.dumps({
    'name': col['name'], 'symbol': col['symbol'],
    'description': '牛来 NFT，共 999 枚（BNB Chain）。二级市场 10% 版税进入金库，每小时买入 $牛来 并自动分发给持有者。',
    'image': f"{IMG}{a.cover}", 'external_link': a.external,
    'seller_fee_basis_points': 1000, 'fee_recipient': a.vault,
}, ensure_ascii=False, indent=2), encoding='utf-8')
(dst / 'unrevealed.json').write_text(json.dumps({
    'name': '牛来 NFT（未揭晓）', 'description': '牛来 NFT，揭晓后显示。',
    'image': f"{IMG}{a.cover}",
}, ensure_ascii=False, indent=2), encoding='utf-8')
print(f'✔ {n} 个 token 元数据 → {dst}/  (+ collection.json, unrevealed.json)')
