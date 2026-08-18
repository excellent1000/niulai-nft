// 自建 OHLC 索引：读 v4 PoolManager 的 Swap 事件 → 算价格 → 聚合成 K 线 → candles.json
// 我们的池子 currency0 = 原生 BNB、currency1 = NLSTR，价格 = NLSTR/BNB，
// 展示时取倒数（1 枚 NLSTR 值多少 BNB），并按 10 亿总量折成 FDV。
//   node scripts/candles.mjs                # 增量更新
//   ONCE=1 ... ；env: RPC_URL POOL_ID CANDLES_OUT [INTERVAL=60] [FROM_BLOCK]
import fs from 'node:fs';
import { ethers } from 'ethers';

const RPC = process.env.RPC_URL || 'https://lb.drpc.live/bsc/AsVs23QoLEOwisC7Py3FTOo-9Orrf6UR8a6vijtBrJVX';
const PM = process.env.POOL_MANAGER || '0x28e2Ea090877bF75740558f6BFB36A5ffeE9e9dF';
// poolId = keccak256(abi.encode(poolKey))。给了 NLSTR+HOOK 就自己算，省得手抄一串 bytes32 抄错。
const POOL_ID = process.env.POOL_ID || (process.env.NLSTR && process.env.HOOK
  ? ethers.keccak256(ethers.AbiCoder.defaultAbiCoder().encode(
      ['(address,address,uint24,int24,address)'],
      [[ethers.ZeroAddress, ethers.getAddress(process.env.NLSTR), 0x800000, 60, ethers.getAddress(process.env.HOOK)]]))
  : undefined);
if (!POOL_ID) { console.error('缺 POOL_ID（或 NLSTR + HOOK 让脚本自己算）'); process.exit(1); }
const OUT = process.env.CANDLES_OUT || '../web/candles.json';
const INTERVAL = Number(process.env.INTERVAL || 60); // 每根 K 线秒数
const SUPPLY = 1e9;
const STEP = Number(process.env.LOG_STEP || 20000);  // 每次拉多少区块（避开节点范围限制）
const ONCE = process.env.ONCE === '1';
const POLL = Number(process.env.POLL_SEC || 30) * 1000;

// Swap(PoolId indexed id, address indexed sender, int128 amount0, int128 amount1,
//      uint160 sqrtPriceX96, uint128 liquidity, int24 tick, uint24 fee)
const SWAP_TOPIC = '0x40e9cecb9f5f1f1c5b9c97dec2917b7ee92e57ba5563708daca94dd84ad7112f';
const provider = new ethers.JsonRpcProvider(RPC, 56, { staticNetwork: ethers.Network.from(56) });
const coder = ethers.AbiCoder.defaultAbiCoder();
const log = (...a) => console.log(new Date().toISOString(), ...a);

function loadState() {
  try { return JSON.parse(fs.readFileSync(OUT, 'utf8')); }
  catch { return { poolId: POOL_ID, interval: INTERVAL, lastBlock: 0, candles: [], volumeBnb: 0, trades: 0 }; }
}

// sqrtPriceX96 → 1 枚 NLSTR 值多少 BNB
function priceFromSqrt(sqrtX96) {
  // price(token1/token0) = (sqrt/2^96)^2 ；token0=BNB token1=NLSTR
  const s = Number(sqrtX96) / 2 ** 96;
  const nlstrPerBnb = s * s;
  return nlstrPerBnb > 0 ? 1 / nlstrPerBnb : 0;   // BNB per NLSTR
}

async function sync() {
  const st = loadState();
  const head = await provider.getBlockNumber();
  let from;
  if (st.lastBlock) from = st.lastBlock + 1;
  else if (process.env.FROM_BLOCK) {
    from = Number(process.env.FROM_BLOCK);
    // 传进来一个负数/空值/未来区块，会让下面的循环从头扫整条链（几小时、把 CPU 打满）
    if (!Number.isInteger(from) || from <= 0 || from > head) {
      console.error(`FROM_BLOCK=${process.env.FROM_BLOCK} 不合法（当前高度 ${head}），拒绝启动`);
      process.exit(1);
    }
  } else from = head - 5000;
  const steps = Math.ceil((head - from + 1) / STEP);
  if (steps > 500) {
    console.error(`要扫 ${head - from + 1} 个区块 / ${steps} 次请求，太多了。把 FROM_BLOCK 设成开盘区块。`);
    process.exit(1);
  }
  console.log(`扫描 ${from} → ${head}（${steps} 次请求）`);
  if (from > head) return st;

  const byBucket = new Map(st.candles.map(c => [c.time, { ...c }]));
  const blockTs = new Map();
  let added = 0;

  let step = STEP;   // 节点各家的 getLogs 范围上限不一样，失败就对半砍，砍到 100 还不行才放弃
  while (from <= head) {
    const to = Math.min(from + step - 1, head);
    let logs;
    try {
      logs = await provider.getLogs({ address: PM, topics: [SWAP_TOPIC, POOL_ID], fromBlock: from, toBlock: to });
    } catch (e) {
      if (step > 100) { step = Math.floor(step / 2); log(`拉 ${from}-${to} 失败，步长降到 ${step} 重试`); continue; }
      throw e;
    }
    for (const l of logs) {
      if (!blockTs.has(l.blockNumber)) blockTs.set(l.blockNumber, (await provider.getBlock(l.blockNumber)).timestamp);
      const ts = blockTs.get(l.blockNumber);
      const [a0, a1, sqrtX96] = coder.decode(['int128', 'int128', 'uint160', 'uint128', 'int24', 'uint24'], l.data);
      const price = priceFromSqrt(sqrtX96);
      const bnbVol = Math.abs(Number(a0)) / 1e18;
      const t = Math.floor(ts / INTERVAL) * INTERVAL;
      const c = byBucket.get(t);
      if (!c) byBucket.set(t, { time: t, open: price, high: price, low: price, close: price, volume: bnbVol });
      else { c.high = Math.max(c.high, price); c.low = Math.min(c.low, price); c.close = price; c.volume += bnbVol; }
      st.volumeBnb = (st.volumeBnb || 0) + bnbVol; st.trades = (st.trades || 0) + 1;
      added++;
    }
    from = to + 1;
  }

  st.candles = [...byBucket.values()].sort((a, b) => a.time - b.time).slice(-1500);
  st.lastBlock = head;
  st.poolId = POOL_ID; st.interval = INTERVAL; st.supply = SUPPLY;
  st.updatedAt = Math.floor(Date.now() / 1000);
  const last = st.candles.at(-1);
  if (last) { st.price = last.close; st.fdv = last.close * SUPPLY; }
  fs.writeFileSync(OUT, JSON.stringify(st));
  if (added) log(`+${added} 笔成交 → ${st.candles.length} 根 K 线，最新价 ${st.price?.toExponential(4)} BNB，FDV ${st.fdv?.toFixed(2)} BNB`);
  return st;
}

if (!POOL_ID) { console.error('需要 POOL_ID（bytes32）'); process.exit(1); }
log(`K 线索引启动 pool ${POOL_ID.slice(0, 12)}… 周期 ${INTERVAL}s`);
do {
  try { await sync(); } catch (e) { log('错误:', e.shortMessage || e.message); }
  if (!ONCE) await new Promise(r => setTimeout(r, POLL));
} while (!ONCE);
