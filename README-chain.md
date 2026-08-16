# 牛来 NFT · BSC 上链方案（10% 版税 → 每小时买入 $牛来 → 自动分红）

> **主网已部署（2026-08-16）**
> - NFT `0x5fd0d8FeCF408f61080cEa470249026d3e02fB3D` · 金库 `0x311188bef22479edE7bd29b61a7aE7D84bA6B55C` · owner/treasury/keeper `0xa59b…2bdd`
> - 网站 https://niulai.sbs（服务器 2.24.118.196，nginx + Let's Encrypt；`/meta` `/img` HTTPS 镜像，`/ipfs/` 自建网关）
> - IPFS：图片 `bafybeiaxbf5pzat7tyitaaodoombb5vrrg5iipbwgbppfz36ncutilxp4y`，元数据 v2 `bafybeibmduyrrt4y7i5kwthdg4xcdvoyytekzubc3qvxistsh5yclyycfu`，collection.json `bafkreigiev23gjrggidq6pbbs4q5ctxfk3ksey4zvd6qn47pxlzd3wm77y`，都 pin 在服务器 Kubo 节点（systemd `ipfs`，已开 AcceleratedDHTClient）。**链上 baseURI/contractURI 用的是自建网关 HTTPS 形式** `https://niulai.sbs/ipfs/<CID>/…`（公共网关对纯 ipfs:// 传播慢导致 OKX 取不到图，已于上线当天切换；内容仍按 CID 寻址）。要切回 `ipfs://` 只需 `setBaseURI`，前提是公共网关能解析（或再 pin 到 Pinata/Filebase）
> - keeper：服务器 systemd `niulai-keeper`（`journalctl -u niulai-keeper -f`），env 在 `/opt/niulai/keeper/.env`
> - 已 reserveMint #1 到 owner，公售已开；Sourcify 已验证源码（BscScan 验证需 API key：`forge verify-contract --chain 56 --etherscan-api-key …`）

> **市场选择（已定方案 A）**：OpenSea 自 2023-08 起不支持 BNB Chain（现支持链名单里没有 BSC），所以 NFT 留在 BSC，铸造走自己网站，二级走 **OKX NFT 市场 / Element / Binance NFT**。上架资料与各平台版税设置见 `listing/README.md`。

## 0. 一图流

```
 网站 mint / OKX·Element 二级买卖
        │  10% creator fee（BNB / WBNB，ERC-2981）
        ▼
 NiuLaiVault（金库）  ←── 铸造收入分成（可选，setMintSplit 的 vaultBps，直接是 $牛来）
        │  每小时 keeper.harvest(minOut)
        │  PancakeSwap V3：BNB →(0.01%)→ USDT →(1%)→ $牛来
        ▼
 按 tokenId 1..999 分批遍历，同一持有人聚合 → 直接转 $牛来 到钱包（distribute）
```

- `contracts/src/NiuLai.sol` — BEP-721：999 枚、**用 $牛来 铸造（默认 1000 枚/NFT，需先 approve）**、铸造收入三路分账（国库 / 金库并入下轮分红 / 销毁，`setMintSplit`）、公售/白名单/团队预留、**实时 reveal**（无盲盒，可切回盲盒）、ERC-2981 版税 10%（收款人 = 金库）、可选 ERC721-C 转账验证器
- `contracts/src/NiuLaiVault.sol` — 金库：收 BNB/WBNB（及 USDT 等 ERC20 版税，`harvestToken`）→ 每小时买入 → **自动分发**（分批、聚合、排除名单、轮次快照）
- `keeper/harvest.mjs` — 机器人：每 60s 检查，可买就用 QuoterV2 报价算 minOut（防三明治）→ `harvest` → 连续 `distribute(250)` 直到发完；金库里若有 USDT 等 ERC20 版税（`EXTRA_TOKENS`）也会换成 牛来 分发
- `web/index.html` + `web/assets/` — 落地页：影院翻拍质感（黑边/颗粒/暗角/银幕/座椅）、硬阴影按钮、棋盘格进度条、mint & 金库面板、角色巡游、正片 / 水墨主题切换；文案只保留功能性说明；ethers v6，改 CONFIG 或用 `?nft=&vault=&rpc=` 参数；未填地址时显示未部署
- `listing/` — 上架资料包（头像/横幅/精选图/中英文案/各平台版税设置步骤）
- `pipeline/export_metadata.py` — 把 999 个 metadata 转成链上格式（`1.json…999.json` + `collection.json` + `unrevealed.json`），支持 `--image-base https://你的域名/img/`（自建服务器）或 `--image-cid`（IPFS）
- `server/` — **自建服务器托管元数据**：`nginx.conf`（/meta /img CORS+缓存）、`deploy.sh`（一键 rsync 落地页+元数据+图片）、`ipfs-optional.md`（可选自建 IPFS 节点镜像）

已验证：`forge test` 14 个单测全过；**BSC 主网 fork 测试**用真实 PancakeSwap V3 router 与真实 牛来/USDT 池跑通（1 BNB → 24,378 牛来 → 分发到位）；另在 **anvil 主网 fork** 上用部署脚本 + 3 个钱包 mint + 模拟版税（BNB+WBNB）+ keeper 脚本（QuoterV2 报价、`NonceManager`）完整演练了两轮买入/分发，落地页读到的就是这些链上数据。

> anvil fork 时用 `https://bsc-mainnet.public.blastapi.io`（能读历史状态）并加 `--hardfork cancun`；测试钱包用新生成的地址——BSC 上 anvil 默认地址已被人挂了 EIP-7702 委托代码，`_safeMint` 会拒收。

## 1. 关键设计决定

| 决定 | 原因 |
|---|---|
| 分红用**推送**（vault 遍历持有人直接转账），不是 claim | 你要求自动到账。gas：999 个不同持有人最坏 ~30M gas/轮（4 笔 250 的批次），BSC 0.1 gwei ≈ 0.003 BNB/小时；同一人持多枚会聚合成一笔 |
| tokenId 1..999 连续、不可销毁、无 Enumerable | 金库靠顺序遍历，省掉 Enumerable 让 mint/转账更便宜 |
| 轮次快照：`harvest` 时记 `roundSupply/roundShare`，发完才能下一轮 | 分发跨多笔交易也不会重复/漏发；被 exclude 地址（市场托管、0xdead）的份额留在金库并入下一轮 |
| `harvest` 只允许 keeper/owner（可开 publicHarvest） | 任何人能传 minOut=0 就能夹金库的买单；keeper 用 QuoterV2 报价 × (1-1.5%) |
| 买入路径 BNB→USDT→牛来（V3 0.01% + 1%） | 牛来 的流动性 99% 在 V3 牛来/USDT 1% 池，WBNB 对没水 |
| 版税收款人 = 金库地址（ERC-2981） | 市场直接把 creator fee 打给金库，无需人工归集 |

### 关于"10% 交易税"必须说清楚的一点

ERC-721 **无法在链上强制**二级市场抽成：版税只能靠市场遵守 ERC-2981（OpenSea 会读并展示，但买家可选；部分市场完全不理）。要真正强制，只有 **ERC721-C**（Limit Break 标准）：合约在 `_update` 里调用转账验证器，只放行遵守版税的市场，OpenSea 对 ERC721-C 合集会**强制**收 creator fee。`NiuLai.sol` 已内置这个钩子（`setTransferValidator`），上线前在 BSC 上找到 Limit Break 官方部署的 `CreatorTokenTransferValidator` 地址并设置、在其上把 OpenSea/Seaport 等加入白名单即可（不设置则等同普通 ERC721 + 2981，靠市场自觉）。你自己网站上的交易当然完全可控。

## 2. 部署 Runbook

```bash
cd contracts
cp .env.example .env            # DEPLOYER_PK / TREASURY / KEEPER / BSCSCAN_API_KEY / BASE_URI / MINT_PRICE / SPLIT_*
forge test                      # 单测
forge test --match-contract ForkTest --fork-url https://bsc-dataseed.binance.org -vv   # 主网 fork 验路径

# 先上测试网跑一遍（BSC 测试网没有 牛来 池，只能测 mint/版税；harvest 在主网 fork 里已验证）
# 主网部署（含 BscScan 验证）
source .env && forge script script/Deploy.s.sol:Deploy --rpc-url bsc --broadcast --verify -vvvv
```

部署后（owner 钱包）：
1. **元数据（自建服务器）**：`HOST=user@服务器 IMAGE_BASE=https://你的域名/img/ EXTERNAL=https://你的域名 VAULT=0x金库 ./server/deploy.sh`（同步落地页 + `/meta/*.json` + `/img/*.png`，nginx 配置见 `server/nginx.conf`）
   - 部署时 `BASE_URI=https://你的域名/meta/`（实时 reveal，mint 即显示）；`nft.setContractURI("https://你的域名/meta/collection.json")`
   - 想临时盲盒：`setRevealed(false)` + `setUnrevealedURI(...)`，再 `reveal(baseURI)`
2. **发售**：部署脚本默认 `MINT_PRICE=1000e18`（1000 $牛来）、`ALLOWLIST_PRICE=800e18`、每钱包 5；分账 `SPLIT_TREASURY_BPS/SPLIT_VAULT_BPS/SPLIT_BURN_BPS`（默认全进国库；例如 5000/3000/2000 = 一半国库、三成给持有者分红、两成销毁）；白名单 `setMerkleRoot`（叶子 = keccak256(abi.encodePacked(address))）；`setSaleState(公售, 白名单)`；团队 `reserveMint`
3. **金库**：`vault.setKeeper(机器人地址, true)`；需要时 `setExcluded(市场托管合约, true)`；`setRewards(callerRewardBps, distributeReward)`
4. **keeper**：`cd keeper && npm i && cp .env.example .env && npm start`（常驻）或 `npm run once` 配 cron `5 * * * *`
5. **网站**：改 `web/index.html` 里 `CONFIG.nft / CONFIG.vault / CONFIG.okx / CONFIG.element`，静态托管即可（Vercel/Cloudflare Pages/任意静态空间）
6. **市场**：mint 一枚后到 OKX NFT 市场 / Element 用 owner 钱包认领合集，设置头像/横幅、**版税 10%、收款地址 = 金库合约**（步骤见 `listing/README.md`）；合集名/头图也会从 contractURI 读

## 3. 成本

- 铸造：~110k gas/枚（含 $牛来 转账）；用户需先 approve 一次；NFT 转账 ~55k
- 每小时：harvest ~250k gas + distribute（每个不同持有人 ~30k，聚合后更少）。BSC 0.1 gwei 下 999 个持有人满打满算 ≈ 0.003 BNB/小时；keeper 报酬默认 0.5%（`callerRewardBps`）覆盖 gas
- `minHarvestAmount` 默认 0.01 BNB，版税不够就攒着不买

## 4. 安全自查（2026-08-16，自审非第三方审计）

逐项过了一遍，结论与处理：

| 项目 | 结论 |
|---|---|
| 重入 | `mint/allowlistMint/harvest/distribute/donate` 均 `nonReentrant`（合约级锁，harvest 期间 distribute 也进不来）；`_mintMany` 先改 `minted`、先收款、再 `_safeMint`（唯一外部回调点） |
| 支付 | `_collect(from = msg.sender)`：只能扣调用者自己的授权，无法替他人付款；分账三路和恒等于 cost，无下溢；$牛来 为标准 ERC20（无税/无黑名单，EIP-1167 克隆，owner 已弃权） |
| 供应上限 | 公售/白名单不能吃预留；`reserveMint` / `setReserve` 均受 `MAX_SUPPLY` 约束（本次补上）；tokenId 连续、无 burn → 金库遍历不会因 `ownerOf` 回滚而卡死 |
| 分发 | 轮次快照（`roundSupply/roundShare`），跨多笔不重不漏；同一 tx 内多次 `distribute` 用 `start` 作 transient key 盐；被排除地址份额留库并入下轮；`roundShare==0` 不开轮 |
| 灰尘捐赠 DoS | `donate` 改为仅 owner/keeper（否则任何人几 wei 就能反复开轮逼 keeper 花 30M gas 分灰尘）；普通人直接 transfer 进金库即可 |
| 三明治 | `harvest` 仅 keeper/owner，且必须自带 `minOut`（keeper 用 QuoterV2 报价 × (1−1.5%)）；`publicHarvest` 默认关 |
| keeper 空转 | `canHarvest` 现在要求 `totalSupply()>0`（本次补上） |
| Owner 权力 | `setSwapConfig`（可换 router/path）、`emergencyWithdrawBNB`、`setRewards`、`setExcluded`——这是信任假设，**owner 请用多签**；`rescueToken` 明确不能动 $牛来 |
| ERC721-C | 钩子只校验二级转账，铸造不校验；`getTransferValidationFunction` 返回 `validateTransfer(address,address,address,uint256)`；验证器地址上线前核对 |
| 精度/溢出 | 0.8 内置检查；份额向下取整、尾数留库 |
| 依赖 | OpenZeppelin v5.1.0；transient storage 需 Cancun（BSC 已支持，主网 fork 实测通过） |

仍建议主网前找第三方审计一次（两个合约合计 ~500 行，成本不高）。

## 5. 上线前清单

- [ ] 主网部署前请第三方审计或至少让另一位工程师过一遍两个合约（未审计）
- [ ] 确认 ERC721-C 验证器地址（如需强制版税）
- [ ] keeper 私钥只放 gas 钱；owner 换成多签（Safe on BSC）
- [ ] `emergencyWithdrawBNB` 是 owner 逃生口，社区可见——用多签管
- [ ] $牛来 合约本身 owner 已弃权、无转账税（已查：EIP-1167 克隆、总量 10 亿、V3 1% 池）；若将来流动性迁移，改 `setSwapConfig(router, path)` 即可
