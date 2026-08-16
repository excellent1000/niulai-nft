# 牛来 NFT —— 组件生图 + 拼接管线

一套按《牛来》正片截图质感做的生成式 PFP：**角色主体 / 姿势 / 五官 / 衣服 / 配饰 / 背景**各自用 Seedream 生图，抠图后按稀有度随机拼接，再叠**贴图故障、弹幕、票房计数器、加场印章、影院翻拍滤镜**。

## 0. 一分钟上手

```bash
cd niulai-nft
cp .env.example .env            # 填 ARK_API_KEY（火山方舟）；模型 ID 见下
uv venv .venv && uv pip install --python .venv/bin/python pillow numpy requests

.venv/bin/python pipeline/ark.py probe                                  # 探测模型是否可用
.venv/bin/python pipeline/gen_components.py --only body --stage base    # ① 7 个角色基准图（直立/豆眼）→ raw/body/
#   看一眼 raw/body/*.png，不满意的删掉重跑（或 --force --chars leopard）
.venv/bin/python pipeline/gen_components.py --only body --stage variants # ② 以基准图为参考图生成 姿势×五官 变体（98 张）
.venv/bin/python pipeline/gen_components.py --only outfit,accessory,bg   # ③ 衣服 5 / 配饰 11 / 背景 7
.venv/bin/python pipeline/gen_components.py --only body --stage outfits --used-only  # ③b（推荐）衣服"穿在身上"生成，--used-only 只烤 supply 里真正出现的 角色×姿势×五官×衣服 组合（999 枚约 375 张 ≈ ¥82），彻底解决围巾/马甲的穿模贴纸感
.venv/bin/python pipeline/cutout.py                                      # ④ 绿幕/品红幕抠图 → layers/
.venv/bin/python pipeline/compose.py --count 24 --sheet                  # ⑤ 拼接 → out/png、out/metadata、out/sheet.png
```

没有 key 也能先看管线：`gen_components.py --all --mock` 会画占位图，后面步骤照跑。

**模型与价格**（方舟官方，元/张）：5.0-Pro ≤1.5K 0.30 / >1.5K 0.60（+第 2 张参考图起 0.02）；**5.0-lite 0.22**；4.5 0.25；4.0 0.20。实测带参考图的角色/穿衣任务 **lite ≈ 5.0 ≈ Pro**（看不出差别），4.5/4.0 会跑偏成光滑玩具——所以 `.env` 默认 `ARK_IMAGE_MODEL=doubao-seedream-5-0-lite-260128`。`ARK_IMAGE_SIZE=2048x2048` 写死正方形（否则带参考图时输出会跟着参考图的宽高比走）；若切回 Pro 记得用 1536x1536 落在便宜档。
账号需先在方舟控制台「模型广场」开通该模型（否则 `ModelNotOpen`），并关闭「安全体验模式」的限额（否则几十张后 `SetLimitExceeded`）。`ark.py probe` 会依次探测候选 ID。

**参考图才是关键**：纯文字怎么写模型都会画成"精致可爱的低多边形玩具"。`refs/chars/` 里是从观众翻拍的正片画面裁出来的角色参考（牛来/牛妈/路人牛/豹拉/灵蛇/狼狗），`components.json` 里每个角色的 `refs` 指向它们；基准图 = 角色参考图 + 文字，变体 = 基准图 + 一张角色参考图。云雀没有找到正片画面，只用文字 + 质感参考。

## 1. 组件设计（`components.json`）

所有组件、prompt、权重、锚点都在 `components.json`，改它不用改代码。

### 角色主体（7 个，全部**拟人直立**——电影最大特征）

| key | 角色 | 权重 | 电影出处 |
|---|---|---|---|
| calf | 牛来 | 26 | 主角。**亮橙黄色毛绒贴图、下半张脸一大块白色嘴筒（人类感的鼻子嘴唇）、豆眼、小灰角、白手蹄**。出生趴地起不来，牛妈起名"牛来" |
| bystander | 路人牛 | 20 | 牛群里的一头，**橄榄黄绿色**，同款白嘴筒（用品红幕抠图，黄绿色会被绿幕误伤） |
| leopard | 豹拉 | 18 | 少年豹，装可怜喝牛妈的奶，摘"保龄球果子"，最后挡在牛来身前——**本片最出圈的一张脸**（平铺豹纹、豆眼、人鼻人嘴、白肚皮） |
| mother | 牛妈 | 12 | **红棕偏橙、大弯灰角、白嘴筒**。望见牛角古树后转身断后，牺牲 |
| snake | 灵蛇 | 9 | 正片里就是一根**肉粉色的弯管子、背脊一条绿色花纹、小扁头**（蓝幕抠图） |
| wolfdog | 狼狗 | 9 | 凭空刷新的三只反派之一：**红棕色、白色胸兜、黄眼睛** |
| lark | 云雀 | 6 | 从荒漠飞来的旁观者/叙述者（没找到正片画面，文字生成）；也作为"见证者"缩小放在其他 NFT 右上角 |

每个角色 = **3 姿势 × 5 五官** = 15 张：
姿势 `直立呆站 / T-pose残留 / 单手举起`；五官 `豆眼 / 死鱼眼 / 斗鸡眼 / 少了一只眼 / 五星眼`。
基准图（直立+豆眼）用纯文本生成，其余变体把基准图当参考图做 i2i，保证同一角色。

### 衣服（13）· 配饰（23）· 背景（17）

- 衣服：红披风（海报同款）、股民西装马甲、红领巾、黑皮夹克、7号球衣、校服外套、白大褂、红唐装、"牛来"卫衣、勇士铠甲、黄雨衣、牛马工牌衬衫、皮草大衣
  - 两种拼法：**穿身版**（`--stage outfits`，图1=角色主体、图2=衣服 → 模型把衣服穿到角色身上，遮挡/包裹全对，文件名 `body/<角色>__<姿势>__<五官>__<衣服>.png`）优先；没有穿身版时退回**贴纸版 + 遮挡修补**（拼完衣服再把主体的头/手臂盖回最上层，`components.json` 里 `occlude` 控制）
- 配饰：电影票根、方向盘（驱车30公里）、爆米花桶、K线小旗、保龄球果子、牛奶瓶、股民墨镜、3D眼镜、五星胸牌、牺牲光环（牛妈专属概率）、金冠（传说专属）、场记板、金元宝、一把韭菜、篮球、麦克风、奖杯、锦旗、折扇、安全帽、耳机、口罩、假胡子
- 背景：大平地、荒漠、梦境、影厅（四个座位亮着）、涨停板、悬崖推土车、牛角古树、牛群集会、贴图树林、山洞里、水墨河谷、荒漠夜、云上梦境、牛马工位、跌停板（「跌停」两字模型总写错，拼接时代码重画）、影院门口、深渊

### 代码层特征（不用生图）

- 贴图：原厂 / UV接缝可见 / 贴图丢失（品红黑棋盘格，局部或整体） / 牛市金身
- 特效：弹幕 / 穿模标注 / 票房计数器（¥7,705）/ 涨停标签 / 加场印章
- 见证者：云雀在场 / 缺席
- 画质：影院翻拍（糊、提黑、噪点、暗角、反光、上下黑边、前排座椅剪影）/ 片源直出

### 稀有度（总量 999）

| 层级 | 数量 | 梗 | 强制特征 |
|---|---|---|---|
| 传说 | 4 | 8/14 全国仅剩 4 场排片 | 牛来/豹拉/灵蛇/牛妈各 1，金身、五星眼、金冠、红披风、影厅、票房计数器 |
| 史诗 | 19 | 8/14 全国只有 19 名观众 | 电影票根、影厅或梦境 |
| 稀有 | 122 | 首日 122 位观众 | 加场印章或弹幕、云雀在场 |
| 普通 | 854 | 纯手工制作，全无投资 | 随机 |

（`collection.supply` 改回 7705 即可回到"票房总量"版；分层数量在 `collection.tiers`）

分层与特征都由 `collection.seed` 确定性生成：同一 tokenId 永远同一结果，可复现、可审计。

## 2. 目录

```
components.json      组件/prompt/权重/锚点（设计的唯一真源）
pipeline/ark.py      方舟客户端（探测模型、重试、参考图 base64、mock）
pipeline/gen_components.py  批量生图（base → variants → 衣服/配饰/背景），--export-prompts 导出手动清单
pipeline/cutout.py   色键抠图（绿/品红，溢色抑制、羽化、裁切），可选 rembg
pipeline/compose.py  拼接：抽特征→背景→主体归一化→衣服/配饰锚点→特效→翻拍滤镜→PNG+metadata
prompts/PROMPTS.md   全部 128 条 prompt（手动生图对照用）
refs/                风格参考图（可选：放一张正片截图，gen 时 --style-ref refs/xxx.jpg）
raw/ layers/ out/    生图原图 / 抠好的透明层 / 成品
_svg-prototype/      第一版纯 SVG 原型（已弃用，留档）
```

## 3. 常用操作

- 某个角色不像：`gen_components.py --only body --stage base --chars leopard --force`，满意后再 `--stage variants --chars leopard --force`
- 只想先看效果：`compose.py --count 12 --set character=leopard,pose=stand --sheet`
- 调锚点（配饰位置不对）：改 `components.json` 的 `anchors`，`compose.py --ids 1,2,3 --debug-anchors` 看红点
- 出全量：`compose.py --count 999 --sheet`（约 2 分钟）；metadata 里 `image` 前缀改成上传后的 CID
- 更好的抠图：`.venv/bin/pip install rembg` 后 `cutout.py --method rembg --force`

## 4. 提醒

- 角色名与形象源自受版权保护的电影，作为致敬/戏仿项目请自行评估风险；对外发行可考虑改名（如 豹拉→豹哥、牛来→牛来了）并避免使用正片截图作参考图。
- `.env` 已 gitignore，key 不要提交。
