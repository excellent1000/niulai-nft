"""火山方舟（Volcengine Ark）Seedream 生图客户端 + 本地 mock。

用法：
  from ark import Ark, load_env
  load_env(); ark = Ark(); png_bytes = ark.generate("prompt", refs=["path/or/url"])
命令行：
  python pipeline/ark.py probe                 # 探测可用的模型 ID
  python pipeline/ark.py test "一头直立的牛"   # 生成一张测试图到 raw/_test.png
"""
from __future__ import annotations
import base64, io, json, os, sys, time, pathlib
import requests

ROOT = pathlib.Path(__file__).resolve().parent.parent
RAW = ROOT / 'raw'

CANDIDATE_MODELS = [
    'doubao-seedream-5-0-pro',
    'doubao-seedream-5-0-pro-260128',
    'doubao-seedream-5-0-260128',
    'doubao-seedream-4-5-251128',
    'doubao-seedream-4-0-250828',
]


def load_env(path: pathlib.Path | None = None):
    """把项目根目录 .env 读入 os.environ（不覆盖已有变量）。"""
    p = path or ROOT / '.env'
    if p.exists():
        for line in p.read_text().splitlines():
            line = line.strip()
            if not line or line.startswith('#') or '=' not in line:
                continue
            k, v = line.split('=', 1)
            os.environ.setdefault(k.strip(), v.strip())


def _to_data_uri(path_or_url: str, max_side: int = 1024) -> str:
    if path_or_url.startswith('http://') or path_or_url.startswith('https://') or path_or_url.startswith('data:'):
        return path_or_url
    from PIL import Image
    im = Image.open(path_or_url).convert('RGB')
    im.thumbnail((max_side, max_side))
    buf = io.BytesIO(); im.save(buf, 'JPEG', quality=90)
    return 'data:image/jpeg;base64,' + base64.b64encode(buf.getvalue()).decode()


class ArkError(RuntimeError):
    pass


class Ark:
    def __init__(self, api_key=None, base_url=None, model=None, size=None, timeout=180):
        self.api_key = api_key or os.environ.get('ARK_API_KEY')
        if not self.api_key:
            raise ArkError('缺少 ARK_API_KEY（写在 .env 或 export）')
        self.base_url = (base_url or os.environ.get('ARK_BASE_URL') or 'https://ark.cn-beijing.volces.com/api/v3').rstrip('/')
        self.model = model or os.environ.get('ARK_IMAGE_MODEL') or CANDIDATE_MODELS[0]
        self.size = size or os.environ.get('ARK_IMAGE_SIZE') or '2K'
        self.timeout = timeout
        self.session = requests.Session()
        self.session.headers.update({'Authorization': f'Bearer {self.api_key}', 'Content-Type': 'application/json'})

    # ---- 单次调用 ----
    def _post(self, payload: dict) -> dict:
        r = self.session.post(f'{self.base_url}/images/generations', data=json.dumps(payload), timeout=self.timeout)
        try:
            body = r.json()
        except Exception:
            body = {'raw': r.text[:500]}
        if r.status_code != 200 or 'error' in body:
            raise ArkError(f'HTTP {r.status_code}: {json.dumps(body, ensure_ascii=False)[:600]}')
        return body

    def generate(self, prompt: str, refs: list[str] | None = None, size: str | None = None, seed: int | None = None,
                 watermark: bool = False, retries: int = 3, extra: dict | None = None) -> bytes:
        payload = {'model': self.model, 'prompt': prompt, 'size': size or self.size, 'response_format': 'url', 'watermark': watermark}
        if refs:
            imgs = [_to_data_uri(x) for x in refs]
            payload['image'] = imgs if len(imgs) > 1 else imgs[0]
        if seed is not None:
            payload['seed'] = seed
        if extra:
            payload.update(extra)
        last = None
        for attempt in range(retries):
            try:
                body = self._post(payload)
                item = (body.get('data') or [{}])[0]
                if item.get('b64_json'):
                    return base64.b64decode(item['b64_json'])
                url = item.get('url')
                if not url:
                    raise ArkError(f'响应里没有图片: {json.dumps(body, ensure_ascii=False)[:400]}')
                img = self.session.get(url, timeout=self.timeout)
                img.raise_for_status()
                return img.content
            except ArkError as e:
                last = e
                msg = str(e)
                # 参数类错误不重试
                if 'HTTP 4' in msg and 'RateLimit' not in msg and '429' not in msg:
                    raise
                time.sleep(2 * (attempt + 1))
            except requests.RequestException as e:
                last = ArkError(str(e)); time.sleep(2 * (attempt + 1))
        raise last or ArkError('未知错误')

    # ---- 探测模型 ----
    def probe(self, candidates=None) -> str | None:
        for m in [self.model] + [c for c in (candidates or CANDIDATE_MODELS) if c != self.model]:
            self.model = m
            try:
                self._post({'model': m, 'prompt': '一个红色的球，纯白背景', 'size': self.size, 'response_format': 'url', 'watermark': False})
                print(f'✔ 可用模型: {m}')
                return m
            except ArkError as e:
                print(f'✘ {m}: {str(e)[:160]}')
        return None


class MockArk:
    """无 key 时的占位生成：画一个色块 + 文字，方便调试抠图/拼接。"""
    def __init__(self, size='2K'):
        self.model = 'mock'; self.size = size

    def generate(self, prompt: str, refs=None, size=None, seed=None, **kw) -> bytes:
        from PIL import Image, ImageDraw
        import hashlib, random
        key = (255, 0, 255) if '品红' in prompt else (0, 177, 64)
        im = Image.new('RGB', (1024, 1024), key)
        d = ImageDraw.Draw(im)
        rnd = random.Random(int(hashlib.md5(prompt.encode()).hexdigest(), 16))
        col = tuple(rnd.randint(40, 220) for _ in range(3))
        if '场景' in prompt or '背景是' not in prompt:
            im = Image.new('RGB', (1024, 1024), col); d = ImageDraw.Draw(im)
            d.rectangle([0, 620, 1024, 1024], fill=tuple(max(0, c - 60) for c in col))
        else:
            d.rounded_rectangle([352, 200, 672, 900], radius=60, fill=col)
            d.ellipse([412, 90, 612, 290], fill=col)
            d.ellipse([460, 150, 490, 180], fill=(0, 0, 0)); d.ellipse([534, 150, 564, 180], fill=(0, 0, 0))
        d.text((20, 20), prompt[:40], fill=(255, 255, 255))
        buf = io.BytesIO(); im.save(buf, 'PNG'); return buf.getvalue()

    def probe(self, *a, **k):
        return 'mock'


if __name__ == '__main__':
    load_env()
    cmd = sys.argv[1] if len(sys.argv) > 1 else 'probe'
    ark = Ark()
    if cmd == 'probe':
        ark.probe()
    elif cmd == 'test':
        prompt = sys.argv[2] if len(sys.argv) > 2 else '一头拟人化直立站着的黄色小豹子，低多边形3D，绿幕背景'
        RAW.mkdir(exist_ok=True)
        data = ark.generate(prompt)
        (RAW / '_test.png').write_bytes(data)
        print('→ raw/_test.png', len(data), 'bytes, model', ark.model)
