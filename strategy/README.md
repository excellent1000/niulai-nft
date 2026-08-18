# 牛来永动机 · NiuLaiStrategy（$NLSTR）

模仿 token.works 的 NFTStrategy，但**方向闭环**：$NLSTR 的交易税去买牛来 NFT，
NFT 的版税继续买 $牛来 分给 999 位 NFT 持有者。

```
$NLSTR 每笔 swap 抽 10%（开盘 95% 线性衰减，金库是唯一 LP 所以全额归金库）
   ├─ 80% → nftFund：常驻收单价买入牛来 NFT，1.2× 柜台转卖
   ├─ 10% → 现有分红金库 0x3111…（每小时买 $牛来 分给 999 位持有者）
   └─ 10% → 团队
卖单侧的手续费以 NLSTR 计价 → 直接销毁
金库买/卖 NFT 时各自付 10% 版税 → 也进分红金库
```

## 合约

| 文件 | 作用 |
|---|---|
| `src/NLSTR.sol` | 标准 ERC20，**零转账税**、固定总量、无铸造权限 |
| `src/NLSTRHook.sol` | Uniswap v4 钩子：动态费率（95%→10%）、开盘单笔限额、**只有金库能加流动性** |
| `src/StrategyTreasury.sol` | 提取手续费并分账；NFT 做市（自有柜台 + Element 链上挂单）；买入销毁 NLSTR。**没有撤出流动性的函数 → LP 永久锁死** |
| `src/ElementTypes.sol` | Element ElementEx 的订单结构与接口 |

## 为什么用 v4 hook 而不是转账税

| | V2 转账税 | V4 Hook |
|---|---|---|
| 单边开盘（不出 BNB） | ❌ 建池必须两边 | ✅ 只放 NLSTR，买家的 BNB 自己填进来 |
| 代币本身 | 有转账税，易被扫描器标黄 | ✅ 干净的标准 ERC20 |
| 费率衰减 | 笨重 | ✅ 钩子里按时间算 |
| 费用去向 | 攒币→swap→BNB | ✅ 直接以 LP 手续费形式沉淀 |

## Element 集成（无需任何 API key，已链上实证）

| 能力 | 做法 | 实证 |
|---|---|---|
| 金库挂买单 | `placeBuyOrders(n, price, expiry)` → 链上 `preSignERC721BuyOrder`，合集通吃（propertyValidator=0）| ✅ 真实持有者可 `sellERC721` 卖入 |
| 金库挂卖单 | `approveListing(order)` → ERC-1271，Element 回调 `isValidSignature` | ✅ 买家 `buyERC721Ex` 成交（signatureType 3/4）|
| 成交是否计入市场数据 | — | ✅ **事件与真实成交字节级一致**（同合约同 topic `0x9c248aa1…`），索引器无法区分 |
| 撤单 | `cancelOrder(nonce)` | ✅ 撤后无法成交 |

### 做市加价必须盖过两头版税（测试挖出来的经济学 bug）

金库买入付 `bid × (1+r)`（自付版税），卖出只到手 `ask × (1−r)`，所以必须
`markup × (1−r) > (1+r)`，即 **markup > (1+r)/(1−r)**。r=10% 时至少 1.223×。
原来默认的 1.2× 每转一圈是**亏钱**的。现已把默认改为 **1.35×**，
并在 `setMarketConfig` 里用 `minMarkupBps()` 强制校验，设不出必亏的参数。

| 版税 r | 保本最低加价 | 建议加价 | 单圈毛利 |
|---|---|---|---|
| 5% | 1.106× | 1.25× | ≈ 13% |
| 10% | 1.223× | 1.35× | ≈ 10% |

**踩到的坑（已修）**：
1. 一张买单只能成交一次（第二个 tokenId 报 `ORDER_NOT_FILL`）→ 必须同时挂多张不同 nonce
2. Element 用 `transferFrom` 转 NFT，**不触发 `onERC721Received`** → 必须靠双向 `syncInventory()` 对账
3. 买单的版税以 **WBNB** 支付（现有分红金库的 `harvest` 会自动 unwrap，无需处理）
4. 手续费收入与卖货所得必须分开记账：前者走 80/10/10，后者走 `processSaleProceeds()`
5. 卖货所得**先回本金再烧利润**：`costBasis[tokenId]` 记每枚成本，卖出后本金回流 `nftFund` 继续买 NFT，
   只有盈利部分买入并销毁 $NLSTR；亏本卖出时全部回流、不销毁

**风控**：`placeBuyOrders` 强制 `price ≤ bidPrice`，`approveListing` 强制 `price ≥ askPrice()`。
即使 keeper 私钥泄露，攻击者既不能高价乱买、也不能低价甩卖。

## 代币分配

| 份额 | 去向 | 说明 |
|---|---|---|
| 80% | **单边入池，永久锁死** | 金库合约里没有撤出流动性的函数 |
| 10% | NFT 持有者空投 | 按 999 枚的持有量快照发放 |
| 10% | dev | 不锁 |

**没有免税白名单**：项目方、金库、做市商与散户完全同一费率，合约里不存在任何减免入口。

## 空投（10%，1 亿枚）

**必须实时快照**：这个合集 24 小时成交 1,644 笔，持有者名单一天换一遍，
用几天前的旧快照等于把钱发给早就跑掉的人。

但"实时"不等于"边发边读"——379 个地址发不完一个区块，
边发边读会让中途买卖的人重复领或漏领。正确流程是**读一次 → 冻结 → 再发**：

```bash
node scripts/snapshot.mjs                            # 在当前区块读全部 999 枚 ownerOf，冻结成名单
node scripts/allocate.mjs airdrop/snapshot-<N>.json  # 按稀有度加权算额度（默认 10/5/2/1）
DRY=1 node scripts/airdrop.mjs airdrop/alloc-<N>.json          # 先空跑核对
SENDER_PK=.. NLSTR=.. BATCH_SENDER=.. node scripts/airdrop.mjs airdrop/alloc-<N>.json   # 批量发（断点续传）
```

**稀有度加权 10 / 5 / 2 / 1**（单枚 NFT 可得）：

| 层级 | 枚数 | 权重 | 单枚可得 |
|---|---:|---:|---:|
| 传说 | 4 | ×10 | 811,030 |
| 史诗 | 19 | ×5 | 405,515 |
| 稀有 | 122 | ×2 | 162,206 |
| 普通 | 854 | ×1 | 81,103 |

选这个比例的原因：379 个持有者里 **283 人（75%）手上全是普通**，
权重再高就是从这批小散身上抽血补给少数人。10× 已经让稀有溢价明显，
普通只被稀释 19%。4 枚传说分散在 4 个不同地址，不会变成给单个巨鲸送钱。

## keeper

`scripts/keeper.mjs` 每分钟：提手续费分账 → 双向对账库存 →
卖货所得回本金/烧利润 → 维持 N 张 Element 买单 → 给库存挂卖单 → 闲置 WBNB 换回。

> 买单和卖单都要把订单 JSON 发布到网站上，对手方才能发现（我们不上 Element 订单簿，
> 但成交走 Element 合约，成交量与地板价照常计入）。keeper 会把 `BUY_ORDER` / `SELL_ORDER` 打到日志。

### 实测一整圈（anvil BSC 分叉，真实 Element 合约）

```
keeper 挂 2 张买单 @0.2 BNB（链上 preSign，无 API）
真实持有者 sellERC721 吃单 → #300 进金库，卖家净收 0.2，分红池 +0.02 WBNB 版税
keeper syncInventory 入库 1，记成本 0.22（= 0.2 + 自付版税）
keeper approveListing #300 → 净收 0.243（柜台价 0.27）
买家 buyERC721Ex 付 0.27 → #300 到手，分红池 +0.027 BNB 版税
keeper syncInventory 出库 1 → processSaleProceeds：
    本金 0.22 回流收购基金，利润 0.023 → 销毁 1,369,807 枚 NLSTR
库存清空，待回本金 0
```

**一枚 NFT 转一圈：分红池进账 0.047 BNB，销毁 137 万枚 NLSTR，本金全额回流。**

### keeper 测试中挖出的 bug

1. `inv.filter(async ...)` —— 异步回调过滤永远为真，出库对账完全失效
2. **`unwrapIdle()` 每轮把挂单占用的 WBNB 全换回 BNB**，导致买单成交时报
   `_transferERC20/TRANSFER_FAILED`。已在合约里加 `committedWbnb` 记账保护，
   并提供 `cancelBuyOrders()` 撤单后一次性释放
3. `JSON.stringify` 遇 BigInt 抛异常被外层 try 吞掉，订单数据根本没发布出去

## 网站面板 `web/machine.html`

单文件静态页，与主站同一套视觉。所有依赖自托管（`assets/ethers.umd.min.js`、
`assets/lwc.js` = TradingView lightweight-charts v5.2），不走 CDN——国内网络能开。

- **行情**：自建 OHLC 索引（`scripts/candles.mjs` 读 v4 `Swap` 事件 → `candles.json`），
  蜡烛图 + 成交量，1分/5分/1时切换。**纵轴画的是 FDV 不是原始价**——价格是 1e-8 量级，
  画出来是一串 `0.0000000759`，没人看得懂。
- **买卖**：走 Uniswap v4 Universal Router。买入直接付 BNB；卖出自动处理
  ERC20→Permit2→UniversalRouter 两段授权。
- **滑点可自定义**：0.5/1/2/5% 预设 + 任意输入，记在 localStorage。
  `amountOutMinimum` 由链上 **v4 Quoter** 报价 ×(1−滑点) 算出，并同时显示价格冲击。
- **金库面板**：收单价阶梯、下次收单进度条、库存柜台（一键买走）、链上挂单表。

### 页面上踩到的坑

1. **税率显示错**（用户发现）：倒计时用本地 `Date.now()`、税率取自链上 `block.timestamp`，
   两者不同步时会出现"已降到底"却显示 93%。改成全部按链上时间算，并在刷新时与
   `currentFeePips()` 交叉校验。
2. **`TransactionDeadlinePassed()`**：同一类问题——swap 的 deadline 也必须用链上时间，
   否则用户本地时钟稍慢就会以一个看不懂的错误失败。
3. **滑点是假的**：面板写着"滑点上限 2%"，实际 `amountOutMinimum` 传的是 `0`，
   等于毫无保护。现在真的用 Quoter 算 minOut。
4. **`bad address checksum`**：ethers v6 严格校验地址大小写，URL 参数里粘进来的
   小写地址会让每个调用静默失败。统一 `getAddress()` 规范化。

本地预览：
```bash
cd web && python3 -m http.server 8891
open "http://127.0.0.1:8891/machine.html?rpc=<节点>&treasury=0x..&nlstr=0x..&hook=0x.."
```

> ⚠️ `strategy/broadcast/` 不进 git。anvil 分叉出来的 chainid 也是 56，
> 演练会把 `broadcast/Deploy.s.sol/56/run-latest.json` 写成一份"看起来像主网"的部署记录，
> 真上线时极易被当成已部署。以线上合约地址为准，不要读这个文件。

## 部署：拆成两步，**部署 ≠ 开盘**

`launchTime` 是在 `PM.initialize()` 那一刻写死的，95%→10% 的衰减和 0.5 BNB 单笔上限都只在
开盘后 5 分钟内有效。合约验证、往网站填地址、发推文这些事没法在 5 分钟里做完，所以拆成两个脚本：

| | 做什么 | 做完的状态 |
|---|---|---|
| `Deploy` | 部署 NLSTR / Treasury / Hook（CREATE2 挖地址）、互相指认、设收单价、分配 80/10/10 | **买不到**：池子不存在，Quoter 报 `PoolNotInitialized` |
| `Launch` | 建池 + 单边注入 80% | **开盘**，衰减开始跑 |

```bash
# 第一步（随时可做）
DEPLOYER_PK=0x.. DEV_WALLET=0x.. AIRDROP_WALLET=0x.. TEAM_WALLET=0x.. INIT_BID=120000000000000000 \
  forge script script/Deploy.s.sol:Deploy --rpc-url bsc --broadcast --verify

# 中间：验证合约、把三个地址填进 web/machine.html 的 CONFIG、部署网站、写好推文

# 第二步（想开盘的那一秒）
DEPLOYER_PK=0x.. NLSTR_ADDR=0x.. HOOK_ADDR=0x.. TREASURY_ADDR=0x.. \
  forge script script/Deploy.s.sol:Launch --rpc-url bsc --broadcast
```

`Launch` 开跑前会自检：hook/nlstr 已互相指认、`launchTime==0`、金库里正好有 80% 的币，
任一不满足直接 revert，不会开出一个半残的盘。

### `INIT_BID` 必须自己定

`bidPrice` 初始是 0，**为 0 时金库会一直攒钱但一枚 NFT 都不收**（`sellToTreasury` 直接
revert `BidDisabled`），整个飞轮是死的。不传 `INIT_BID` 部署脚本会打印大写警告。

定价原则：**开在地板价下面**。收单价只涨不跌（每收一枚 +2%），开高了会被人瞬间倒货掏空基金；
开低了它就是个慢慢往上爬的托底买单。加价 1.35× 之后要落在近期成交带里才卖得掉。

## keeper 上服务器

`./server/deploy-keeper.sh` 把 `keeper.mjs` + `candles.mjs` 装成两个 systemd 服务
（`nlstr-keeper` / `nlstr-candles`），输出直接落到 `/var/www/niulai/nlstr/`，网站就能读到。
装完是 **disabled** 状态——合约没部署就启动只会每 20 秒崩一次刷日志。

```bash
./server/deploy-keeper.sh                                   # 装代码 + unit（不启动）
ssh root@2.24.118.196 'nano /opt/niulai/strategy/.env'      # 填 KEEPER_PK / TREASURY / NLSTR / HOOK
./server/deploy-keeper.sh --restart                         # enable + start
ssh root@2.24.118.196 'journalctl -u nlstr-keeper -f'       # 看日志
```

`FROM_BLOCK` 记得设成开盘区块，否则 K 线只会有最近 5000 块。

### 装的时候踩到的三个坑

1. **`candles.mjs` 的「缩小步长重试」是假的**：`STEP` 是模块级 const，失败时
   `return sync()` 递归调用，步长根本没变，等于死循环。改成局部变量真的对半砍
   （2500→1250→…→100）。
2. **非法 `FROM_BLOCK` 会让它从头扫整条链**：我手滑传了个负数，它就老老实实准备扫
   1.16 亿个区块，CPU 打满跑了十分钟。现在开扫前先校验并打印区块范围与请求数，
   超过 500 次直接拒绝。
3. **公共节点 `bsc-dataseed` 对 PoolManager 的 `getLogs` 直接拒**（`limit exceeded`，
   降到 78 块还是拒）。服务器上得用付费节点。

## 主网 fork 演练

```bash
BSC_RPC_URL=<你的BSC节点> forge test -vv
# 可调开盘曲线：TICK_UPPER=189300 TICK_LOWER=-887220 forge test --match-test test_08 -vv
```

**25 个用例全部通过**，全部打真实合约（v4 PoolManager / Element ElementEx / 牛来 NFT / 分红金库）：

- `ForkE2E`（14）单边开盘 · 费率衰减 · 80-10-10 分账 · 收单价阶梯 · 柜台买卖 · 流动性锁死 ·
  价格曲线 · 卖单税销毁 · 开盘防巨鲸 · **完整飞轮走 Element** · 亏本卖出处理 · 单圈资金守恒
- `ElementFill`（3）合约挂卖单成交 · 带版税成交 · 成交事件与真实成交比对
- `ElementBuyOrder`（5）链上挂买单 · 合集通吃 · 单张成交次数 · 撤单 · nonce 复用
- `ElementProbe`（2）签名类型探测
- `UniversalRouterBuy`（1）**用 BSC 上真实的 Uniswap Universal Router 买入**（真实用户路径）

## 开盘曲线参数（已定）

- `TICK_UPPER = 189300` → 开盘 FDV ≈ **6 BNB**
- `TICK_LOWER = -887220`（最低可用 tick）→ **无 FDV 上限**
  区间下界决定"价格最多能涨到哪"，设到最低即无上限，代价只是流动性少约 1%。

实测曲线（净买入 → 已售出 / 边际 FDV）：
1 BNB → 128M / 7 BNB · 5 BNB → 408M / 16 BNB · 10 BNB → 561M / 32 BNB ·
20 BNB → 691M / 76 BNB · 50 BNB → 803M / 269 BNB

卖出时币会回到池子（价格回落，别人又能买），但**卖单的 10% 手续费以 NLSTR 计价并被销毁**，
所以每次卖出只有 90% 回池，10% 永久消失。

## 部署顺序

1. 部署 `NLSTR`（全部铸给部署者）
2. 部署 `StrategyTreasury(poolManager, 牛来NFT, 分红金库, team, owner)` → `setNlstr`
3. **挖 hook 地址**（低 14 位须等于 `BEFORE_INITIALIZE|BEFORE_ADD_LIQUIDITY|BEFORE_SWAP`），CREATE2 部署 `NLSTRHook`
4. `treasury.setPoolKey(...)` → `poolManager.initialize(key, sqrtPriceAtTick(TICK_UPPER))`
5. 转 90% NLSTR 给金库 → `treasury.addLiquidity(TICK_LOWER, TICK_UPPER, L)`
6. 10% 按快照空投给 999 枚 NFT 的持有者
7. `setMarketConfig` / `setBidPrice` / `fundBid` 开启 NFT 收单

## 未完成

- [x] 部署脚本 `script/Deploy.s.sol`（含 hook 地址 CREATE2 挖矿）——
      anvil 主网分叉实测：**全新钱包只需 0.01 BNB，实际耗 gas 0.00032 BNB**
- [x] 空投：快照 / 加权 / 批量发放脚本
- [x] keeper 脚本 —— **anvil 主网分叉上端到端跑通一整圈**（见下）


- [ ] 第三方审计（hook 与金库经手全部资金流，目前只有自测）
