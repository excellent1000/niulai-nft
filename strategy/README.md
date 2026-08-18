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
- [ ] keeper 脚本：补挂买单 / 挂卖单 / 调 syncInventory 与 processSaleProceeds
- [ ] 空投名单与发放脚本
- [ ] 网站面板：收单价 / 进度条 / 金库存货 / 销毁计数 / 柜台
- [ ] 第三方审计（hook 与金库经手全部资金流，目前只有自测）
