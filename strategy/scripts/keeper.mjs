// 永动机 keeper：维持 Element 买单、挂卖单、对账、处理卖货所得。
//   node scripts/keeper.mjs           # 常驻
//   ONCE=1 node scripts/keeper.mjs    # 跑一轮
// env: KEEPER_PK RPC_URL TREASURY NLSTR ELEMENT NFT  [OPEN_ORDERS=3 POLL_SEC=60 ORDER_TTL_H=24]
import fs from 'node:fs';
import { ethers } from 'ethers';

const RPC = process.env.RPC_URL || 'https://lb.drpc.live/bsc/AsVs23QoLEOwisC7Py3FTOo-9Orrf6UR8a6vijtBrJVX';
const TREASURY = process.env.TREASURY;
const NFT = process.env.NFT || '0x5fd0d8FeCF408f61080cEa470249026d3e02fB3D';
const ELEMENT = process.env.ELEMENT || '0xb3e3DfCb2d9f3DdE16d78B9e6EB3538Eb32B5ae1';
const WBNB = '0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c';
const NATIVE = '0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE';
const OPEN_ORDERS = Number(process.env.OPEN_ORDERS || 3);
const POLL = Number(process.env.POLL_SEC || 60) * 1000;
const TTL = Number(process.env.ORDER_TTL_H || 24) * 3600;
const TICK_LOWER = Number(process.env.TICK_LOWER || -887220);
const TICK_UPPER = Number(process.env.TICK_UPPER || 189300);
const ONCE = process.env.ONCE === '1';
const ORDERS_OUT = process.env.ORDERS_OUT || '';   // 写成 JSON 供网站读取

if (!TREASURY || !process.env.KEEPER_PK) {
  console.error('缺 TREASURY 或 KEEPER_PK —— 合约部署前别启动这个服务，否则只会每 20 秒崩一次刷日志');
  process.exit(1);
}

const log = (...a) => console.log(new Date().toISOString(), ...a);
const J = (o) => JSON.stringify(o, (_, v) => (typeof v === 'bigint' ? v.toString() : v));

const T_ABI = [
  'function bidPrice() view returns (uint256)',
  'function askPrice() view returns (uint256)',
  'function minSellNet() view returns (uint256)',
  'function nftFund() view returns (uint256)',
  'function bidCost() view returns (uint256)',
  'function royaltyBps() view returns (uint16)',
  'function nextOrderNonce() view returns (uint256)',
  'function inventory() view returns (uint256[])',
  'function pendingPrincipal() view returns (uint256)',
  'function dividendVault() view returns (address)',
  'function placeBuyOrders(uint256 count, uint256 price, uint256 expiry)',
  'function approveListing((address,address,uint256,uint256,address,uint256,(address,uint256,bytes)[],address,uint256) o)',
  'function syncInventory(uint256[] tokenIds)',
  'function processSaleProceeds()',
  'function collectFees(int24 lo, int24 hi)',
  'function unwrapIdle()',
  'function committedWbnb() view returns (uint256)',
  'function cancelBuyOrders(uint256[] nonces)',
  'function setBidPrice(uint256 p)',
  'function maxBidPrice() view returns (uint256)',
  'function bidStepBps() view returns (uint16)',
  'function approvedListings(bytes32) view returns (bool)',
];
const EX_ABI = ['function getERC721SellOrderHash((address,address,uint256,uint256,address,uint256,(address,uint256,bytes)[],address,uint256) o) view returns (bytes32)'];

const provider = new ethers.JsonRpcProvider(RPC, 56, { staticNetwork: ethers.Network.from(56) });
const signer = new ethers.NonceManager(new ethers.Wallet(process.env.KEEPER_PK, provider));
const T = new ethers.Contract(TREASURY, T_ABI, signer);
const EX = new ethers.Contract(ELEMENT, EX_ABI, provider);
const nft = new ethers.Contract(NFT, ['function ownerOf(uint256) view returns (address)'], provider);

// Element 成交不经过 sellToTreasury，收单价得由 keeper 手动阶梯上调
async function bumpBid(n) {
  const [cur, stepBps, maxBid] = await Promise.all([T.bidPrice(), T.bidStepBps(), T.maxBidPrice()]);
  let next = cur;
  for (let i = 0; i < n; i++) next = next + (next * BigInt(stepBps)) / 10000n;
  if (maxBid > 0n && next > maxBid) next = maxBid;
  if (next === cur) return;
  await (await T.setBidPrice(next)).wait();
  log(`收单价 ${ethers.formatEther(cur)} → ${ethers.formatEther(next)}（收了 ${n} 枚）`);
}

// 记录我们挂过的卖单，避免重复挂
const listed = new Set();
// 对外公示的订单簿（网站从这里读，买卖双方才能发现）
const book = { updatedAt: 0, treasury: TREASURY, element: ELEMENT, nft: NFT, buy: [], sell: [] };
function publish() {
  if (!ORDERS_OUT) return;
  book.updatedAt = Math.floor(Date.now() / 1000);
  fs.writeFileSync(ORDERS_OUT, J(book));
}

async function tick() {
  signer.reset();   // 与链上 nonce 对齐

  // ① 提取 LP 手续费并分账
  try { await (await T.collectFees(TICK_LOWER, TICK_UPPER)).wait(); log('collectFees ✔'); }
  catch (e) { /* 没有手续费可提时会静默失败，正常 */ }

  // ② 对账：把 Element 成交造成的库存变化同步进合约（双向）
  const inv = (await T.inventory()).map(Number);
  const invSet = new Set(inv);
  const ownedNow = new Set();
  for (let i = 1; i <= 999; i += 200) {
    const ids = Array.from({ length: Math.min(200, 1000 - i) }, (_, k) => i + k);
    const owners = await Promise.all(ids.map(id => nft.ownerOf(id).catch(() => null)));
    owners.forEach((o, k) => { if (o && o.toLowerCase() === TREASURY.toLowerCase()) ownedNow.add(ids[k]); });
  }
  const toAdd = [...ownedNow].filter(id => !invSet.has(id));      // 收到了但合约不知道
  const toRemove = inv.filter(id => !ownedNow.has(id));           // 卖掉了但合约还记着
  const toSync = [...toAdd, ...toRemove];
  if (toSync.length) {
    await (await T.syncInventory(toSync)).wait();
    log(`syncInventory：入库 ${toAdd.length}，出库 ${toRemove.length}`);
    toRemove.forEach(id => { listed.delete(id); book.sell = book.sell.filter(x => x.tokenId !== id); });
    // 走 Element 买单成交的，合约里 sellToTreasury 根本没被调用 —— 收单价不会自动 +2%。
    // 「只涨不跌，每收一枚上调」是对外承诺的机制，这里补上。
    if (toAdd.length) await bumpBid(toAdd.length);
  }

  // ③ 卖货所得：先回本金，只烧利润
  const bal = await provider.getBalance(TREASURY);
  const fundNow = await T.nftFund();
  if (bal > fundNow) {
    await (await T.processSaleProceeds()).wait();
    log(`processSaleProceeds ${ethers.formatEther(bal - fundNow)} BNB`);
  }

  // ④ 维持 N 张 Element 买单
  const [bid, fund, cost] = await Promise.all([T.bidPrice(), T.nftFund(), T.bidCost()]);
  if (bid > 0n && cost > 0n) {
    const affordable = Number(fund / cost);
    const n = Math.min(OPEN_ORDERS, affordable);
    if (n > 0) {
      const expiry = Math.floor(Date.now() / 1000) + TTL;
      const firstNonce = Number(await T.nextOrderNonce());
      const roy = (bid * BigInt(await T.royaltyBps())) / 10000n;
      const vault0 = await T.dividendVault();
      await (await T.placeBuyOrders(n, bid, expiry)).wait();
      book.buy = [];   // 旧买单已被新一批取代
      log(`挂 ${n} 张买单 @${ethers.formatEther(bid)} BNB（基金 ${ethers.formatEther(fund)}）`);
      // 买单必须公布出去，卖家才能调 Element 的 sellERC721 吃单
      for (let k = 0; k < n; k++) {
        const order = [TREASURY, ethers.ZeroAddress, expiry, firstNonce + k, WBNB, bid,
                       [[vault0, roy, '0x']], NFT, 0, [[ethers.ZeroAddress, '0x']]];
        book.buy.push({ nonce: firstNonce + k, price: bid.toString(), expiry, order });
        console.log('  BUY_ORDER', J({ nonce: firstNonce + k, price: bid, order }));
      }
    } else if (OPEN_ORDERS > 0) log(`收购基金不足（${ethers.formatEther(fund)} < 单枚成本 ${ethers.formatEther(cost)}），暂不挂买单`);
  }

  // ⑤ 库存挂卖单
  const inv2 = (await T.inventory()).map(Number);
  const [ask, net, royBps] = await Promise.all([T.askPrice(), T.minSellNet(), T.royaltyBps()]);
  const vault = await T.dividendVault();
  for (const id of inv2) {
    if (listed.has(id)) continue;
    const order = [
      TREASURY, ethers.ZeroAddress, Math.floor(Date.now() / 1000) + TTL,
      Number(await T.nextOrderNonce()) + 900000 + id,
      NATIVE, net, [[vault, (ask * BigInt(royBps)) / 10000n, '0x']], NFT, id,
    ];
    try {
      await (await T.approveListing(order)).wait();
      const h = await EX.getERC721SellOrderHash(order);
      listed.add(id);
      log(`挂卖单 #${id} 净收 ${ethers.formatEther(net)} BNB  hash ${h.slice(0, 12)}…`);
      // 订单数据需要发布出去（网站/事件）才能被买家发现
      book.sell.push({ tokenId: id, hash: h, price: (net + (ask * BigInt(royBps)) / 10000n).toString(), net: net.toString(), order });
      console.log('  SELL_ORDER', J({ tokenId: id, hash: h, order }));
    } catch (e) { log(`挂卖单 #${id} 失败: ${(e.shortMessage || e.message).slice(0, 80)}`); }
  }

  publish();

  // ⑥ 把**超出挂单占用**的 WBNB 换回 BNB（合约里有 committedWbnb 保护，不会挖空未成交的买单）
  try { await (await T.unwrapIdle()).wait(); } catch {}
}

log(`keeper 启动 → treasury ${TREASURY}`);
do {
  try { await tick(); } catch (e) { log('错误:', e.shortMessage || e.message); }
  if (!ONCE) await new Promise(r => setTimeout(r, POLL));
} while (!ONCE);
