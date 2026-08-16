#!/usr/bin/env python
"""生成品牌素材候选：头像（正方形胸像）与横幅（宽幅全员）。
  python pipeline/gen_brand.py --kind avatar --n 3
  python pipeline/gen_brand.py --kind banner --n 3
输出 listing/gen/<kind>-<i>.png
"""
import argparse, io, sys, pathlib, concurrent.futures as cf
sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
from ark import Ark, load_env
from common import CFG, ROOT
from PIL import Image

STYLE = CFG['style']['char']
REFS_ALL = ['refs/chars/calf_body.jpg', 'refs/chars/leopard_front.jpg', 'refs/chars/mother.jpg', 'refs/chars/herd.jpg', 'refs/chars/snake.jpg', 'refs/chars/wolfdogs.jpg']
REFS_CALF = ['refs/chars/calf_face.jpg', 'refs/chars/calf_body.jpg', 'refs/chars/calf_side.jpg']

PROMPTS = {
    'avatar': {
        'refs': REFS_CALF, 'size': '2048x2048',
        'prompt': ("参考图是电影《牛来》主角「牛来」的真实正片画面。请画牛来的正面胸像特写（头部和肩膀，居中，直视镜头，占画面约70%）："
                   "亮橙黄色毛绒颗粒感贴图，下半张脸一大块白色/奶油色嘴筒和有点像人类的鼻子嘴唇，两颗小黑豆眼，头顶两只很短的灰色小角，牛耳朵，表情呆滞。"
                   "背景是纯色的浅青蓝色（像大平地的天空），没有其他物体，没有任何文字。适合做圆形头像。" + STYLE),
    },
    'avatar-leopard': {
        'refs': ['refs/chars/leopard_front.jpg', 'refs/chars/leopard_side.jpg'], 'size': '2048x2048',
        'prompt': ("参考图是电影《牛来》里「豹拉」的真实正片画面。请画豹拉的正面胸像特写（头部和肩膀，居中，直视镜头，占画面约70%）："
                   "亮黄色皮毛上是平铺重复的黑色豹纹贴图，两颗很小的黑豆眼，脸中央是明显的人类肉色鼻子和嘴唇，尖三角耳。"
                   "背景是纯色的浅青蓝色，没有其他物体，没有任何文字。适合做圆形头像。" + STYLE),
    },
    'banner': {
        'refs': REFS_ALL, 'size': '2800x800',
        'prompt': ("参考图是电影《牛来》的真实正片画面。请画一张横向宽幅画面：电影里的全部角色并排站在大平地草原上、正面直立面向镜头——"
                   "牛来（亮橙黄小牛，白嘴筒）、豹拉（黄色豹纹、白肚皮、人鼻）、牛妈（红棕色、大弯角）、灵蛇（粉色管子一样的蛇、绿色花纹）、狼狗（红棕、白胸兜、黄眼）、几头橄榄黄绿色的路人牛，天上飞着一只云雀。"
                   "地面是平铺重复的草地贴图，远处一块画上去的岩石和几棵球状树，天空是纯色浅青蓝。角色集中在画面中间三分之二，左右两侧留出干净的天空和草地作为留白。没有任何文字。" + STYLE),
    },
    'group-square': {
        'refs': REFS_ALL, 'size': '2048x2048',
        'prompt': ("参考图是电影《牛来》的真实正片画面。请画一张正方形的全员合照：牛来（亮橙黄小牛，白嘴筒）、豹拉（黄色豹纹、白肚皮、人鼻）、牛妈（红棕色、大弯角）、灵蛇（粉色管子一样的蛇、绿色花纹）、狼狗（红棕、白胸兜、黄眼）、两头橄榄黄绿色的路人牛，"
                   "全部正面直立站在大平地草原上面向镜头、排成前后两排，天上飞着一只云雀。地面是平铺重复的草地贴图，远处几棵球状树，天空纯色浅青蓝。没有任何文字。" + STYLE),
    },
    'banner-cinema': {
        'refs': REFS_ALL + ['refs/douban_f/p2934947021.jpg'], 'size': '2800x800',
        'prompt': ("参考图是电影《牛来》的真实正片画面。请画一张横向宽幅画面：电影里的全部角色（牛来、豹拉、牛妈、灵蛇、狼狗、路人牛）并排站在一排暗红色影院座椅前面，正面直立面向镜头，"
                   "身后是一块亮着的银幕（银幕上是水墨山水画的一角），整体昏暗、只有零星座位亮着。角色集中在画面中间三分之二，左右留出暗部留白。没有任何文字。" + STYLE),
    },
}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--kind', default='avatar', choices=list(PROMPTS))
    ap.add_argument('--n', type=int, default=3)
    ap.add_argument('--size')
    a = ap.parse_args()
    load_env(); ark = Ark()
    spec = PROMPTS[a.kind]; size = a.size or spec['size']
    out = ROOT / 'listing' / 'gen'; out.mkdir(parents=True, exist_ok=True)
    refs = [str(ROOT / r) for r in spec['refs'] if (ROOT / r).exists()]

    def one(i):
        data = ark.generate(spec['prompt'], refs=refs, size=size)
        p = out / f'{a.kind}-{i}.png'; Image.open(io.BytesIO(data)).convert('RGB').save(p); return p.name

    with cf.ThreadPoolExecutor(a.n) as ex:
        for f in cf.as_completed([ex.submit(one, i + 1) for i in range(a.n)]):
            try: print('✔', f.result())
            except Exception as e: print('✘', str(e)[:300])


if __name__ == '__main__':
    main()
