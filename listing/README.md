# 上架资料包（BSC：OKX NFT 市场 / Element / Binance NFT）

## 素材（listing/）
| 文件 | 尺寸 | 用途 |
|---|---|---|
| `avatar-1000.png` / `avatar-1000-alt.png` | 1000×1000 | 合集头像（生图：牛来正面胸像 / 豹拉正面胸像）|
| `banner-1400x400.png` | 1400×400 | OKX / Element 合集横幅（生图：全员站在大平地，无字）|
| `banner-x-1500x500.png` | 1500×500 | X（Twitter）头图 |
| `og-1200x630.png` | 1200×630 | 网站分享预览图（og:image）|
| `social-1080.png` | 1080×1080 | 社媒方图（生图：全员合照）|
| `featured-600x600.png` | 600×600 | 精选/推荐位（全员合照）|
| `gen/` | — | 全部候选原图（头像 ×3、豹拉头像 ×2、横幅 ×3、合照 ×2），`pipeline/gen_brand.py` 可再生成 |
| `legendary/*.png` | 1000×1000 | 4 张传说级单图 |
| `../out/showcase.png` · `../out/png/` | — | 24 枚精选 / 全部 999 枚 |

## 文案

**名称**：牛来 NFT（NIULAI）
**一句话**：999 枚牛来 NFT，用 1 $牛来 铸造（每钱包 1 枚），10% 版税每小时买入 $牛来 并自动打到持有者钱包。

**中文简介**
> 牛来 NFT：基于 2026 年动画电影《牛来》角色的 999 枚 PFP，角色包括牛来、牛妈、豹拉、灵蛇、狼狗、云雀和路人牛，由 3 种姿势 × 5 种五官 × 13 件衣服 × 23 种配饰 × 17 个场景组合生成。
> 铸造价 1 $牛来 / 枚（每钱包限 1 枚），铸造后立即显示。二级市场 10% 版税进入金库合约，每小时用 BNB 在 PancakeSwap 买入 $牛来（0xBEEA…7777），按 999 份直接转到每个持有者钱包，无需领取。
> 稀有度：传说 ×4 / 史诗 ×19 / 稀有 ×122 / 普通 ×854。

**English**
> NIULAI is a 999-piece PFP collection based on the characters of the 2026 animated film 牛来 (Niu Lai): Niu Lai, Mother Cow, Bao La, Spirit Snake, the wolf-dogs, the lark and the herd — generated from 3 poses × 5 faces × 13 outfits × 23 accessories × 17 scenes.
> Mint price: 1 $牛来 per NFT (1 per wallet), instant reveal. 10% creator fee on every secondary sale flows into the vault contract, which buys $牛来 on PancakeSwap every hour and pushes it pro-rata straight to holders' wallets. No claiming.

**标签**：Movie · BNB Chain · Auto-dividend · $牛来

## 版税与合约信息（各平台后台需要填）
- 链：BNB Smart Chain（56）
- NFT 合约：部署后填；标准 ERC-721 + ERC-2981（版税 10%，收款人 = 金库合约地址）
- 金库合约：部署后填
- 版税比例：10%；收款地址：金库合约（不是个人钱包！）
- 官网 / X / Telegram：自行填写

## 各平台步骤（以平台当前 UI 为准）
### OKX NFT 市场（web3.okx.com/nft）
1. 部署并 mint 至少 1 枚后，合集会被自动收录；用 **owner 钱包**登录 → 我的合集 → 找到 NIULAI → 「管理/编辑合集」
2. 上传头像、横幅、简介、社媒；**版税 10%**，收款地址填金库合约
3. 想上首页/首发位：申请 **OKX NFT Launchpad**（表单在市场页底部/创作者中心），提交本资料包 + 合约地址 + 团队信息
### Element（element.market）
1. 连接 owner 钱包 → Collection Manager → 认领合集（会让你用 owner 地址签名验证）
2. 设置头像/横幅/描述、**Creator fee 10%** 与收款地址；Element 支持链上 ERC-2981，也可在后台单独设
### Binance NFT
- 二级：合集需通过审核后可交易；创作者中心提交合集信息与版税
- 首发：Binance NFT Launchpad 需商务申请，周期较长，作为备选

## 上架前检查
- [ ] BscScan 已验证合约源码（`forge script … --verify` 或 `forge verify-contract`）
- [ ] `contractURI()` 指向 `ipfs://META_CID/collection.json`（平台会读名称/头图/版税）
- [ ] 至少 mint 1 枚（团队 `reserveMint`）让平台索引到合集
- [ ] 各平台版税收款地址 = 金库合约，比例 10%
- [ ] 平台如托管 NFT（挂单时转走），把托管合约地址 `vault.setExcluded(addr, true)`
