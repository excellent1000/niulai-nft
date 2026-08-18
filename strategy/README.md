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
| `src/StrategyTreasury.sol` | 提取手续费并分账；NFT 收单价做市；柜台转卖；买入销毁 NLSTR。**没有撤出流动性的函数 → LP 永久锁死** |

## 为什么用 v4 hook 而不是转账税

| | V2 转账税 | V4 Hook |
|---|---|---|
| 单边开盘（不出 BNB） | ❌ 建池必须两边 | ✅ 只放 NLSTR，买家的 BNB 自己填进来 |
| 代币本身 | 有转账税，易被扫描器标黄 | ✅ 干净的标准 ERC20 |
| 费率衰减 | 笨重 | ✅ 钩子里按时间算 |
| 费用去向 | 攒币→swap→BNB | ✅ 直接以 LP 手续费形式沉淀 |

## 主网 fork 演练

```bash
BSC_RPC_URL=<你的BSC节点> forge test -vv
# 可调开盘曲线：TICK_UPPER=173220 TICK_LOWER=92100 forge test --match-test test_08 -vv
```

10 个用例覆盖：单边开盘 / 费率衰减 / 80-10-10 分账 / 收单价买 NFT 且阶梯上调 /
柜台卖出并销毁 NLSTR / 流动性锁死 / 价格曲线 / 卖单税销毁 / 开盘防巨鲸。

## 部署顺序

1. 部署 `NLSTR`（全部铸给部署者）
2. 部署 `StrategyTreasury(poolManager, 牛来NFT, 分红金库, team, owner)` → `setNlstr`
3. **挖 hook 地址**（低 14 位须等于 `BEFORE_INITIALIZE|BEFORE_ADD_LIQUIDITY|BEFORE_SWAP`），CREATE2 部署 `NLSTRHook`
4. `treasury.setPoolKey(...)` → `poolManager.initialize(key, sqrtPriceAtTick(TICK_UPPER))`
5. 转 90% NLSTR 给金库 → `treasury.addLiquidity(TICK_LOWER, TICK_UPPER, L)`
6. 10% 按快照空投给 999 枚 NFT 的持有者
7. `setMarketConfig` / `setBidPrice` / `fundBid` 开启 NFT 收单

## 未完成

- [ ] 部署脚本 `script/Deploy.s.sol`（含 hook 地址挖矿）
- [ ] 空投名单与发放脚本
- [ ] 网站面板：收单价 / 进度条 / 金库存货 / 销毁计数 / 柜台
- [ ] 第三方审计（hook 与金库经手全部资金流，目前只有自测）
