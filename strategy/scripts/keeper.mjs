// 永动机 keeper：维持 Element 买单、挂卖单、对账、处理卖货所得。
//   node scripts/keeper.mjs           # 常驻
//   ONCE=1 node scripts/keeper.mjs    # 跑一轮
// env: KEEPER_PK RPC_URL TREASURY NLSTR ELEMENT NFT  [OPEN_ORDERS=3 POLL_SEC=60 ORDER_TTL_H=24]
import { ethers } from 'ethers';

const RPC = process.env.RPC_URL || 'https://bsc-dataseed.bnbchain.org';
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

const log = (...a) => console.log(new Date().toISOString(), ...a);

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
  'function approvedListings(bytes32) view returns (bool)',
];
const EX_ABI = ['function getERC721SellOrderHash((address,address,uint256,uint256,address,uint256,(address,uint256,bytes)[],address,uint256) o) view returns (bytes32)'];

const provider = new ethers.JsonRpcProvider(RPC, 56, { staticNetwork: ethers.Network.from(56) });
const signer = new ethers.NonceManager(new ethers.Wallet(process.env.KEEPER_PK, provider));
const T = new ethers.Contract(TREASURY, T_ABI, signer);
const EX = new ethers.Contract(ELEMENT, EX_ABI, provider);
const nft = new ethers.Contract(NFT, ['function ownerOf(uint256) view returns (address)'], provider);

// 记录我们挂过的卖单，避免重复挂
const listed = new Set();

async function tick() {
  signer.reset();   // 与链上 nonce 对齐

  // ① 提取 LP 手续费并分账
  try { await (await T.collectFees(TICK_LOWER, TICK_UPPER)).wait(); log('collectFees ✔'); }
  catch (e) { /* 没有手续费可提时会静默失败，正常 */ }

  // ② 对账：把 Element 成交造成的库存变化同步进合约
  const inv = (await T.inventory()).map(Number);
  const candidates = new Set(inv);
  // 抽查全集合里属于金库的（Element 买单成交后 NFT 会直接到账但合约不知道）
  for (let i = 1; i <= 999; i += 200) {
    const ids = Array.from({ length: Math.min(200, 1000 - i) }, (_, k) => i + k);
    const owners = await Promise.all(ids.map(id => nft.ownerOf(id).catch(() => null)));
    owners.forEach((o, k) => { if (o && o.toLowerCase() === TREASURY.toLowerCase()) candidates.add(ids[k]); });
  }
  const needSync = [...candidates].filter(id => !inv.includes(id) || false);
  const stale = inv.filter(async id => (await nft.ownerOf(id)).toLowerCase() !== TREASURY.toLowerCase());
  const toSync = [...new Set([...needSync, ...stale])];
  if (toSync.length) { await (await T.syncInventory(toSync)).wait(); log(`syncInventory ${toSync.length} 枚`); }

  // ③ 卖货所得：先回本金，只烧利润
  if (await T.pendingPrincipal() > 0n || true) {
    try { await (await T.processSaleProceeds()).wait(); log('processSaleProceeds ✔'); } catch {}
  }

  // ④ 维持 N 张 Element 买单
  const [bid, fund, cost] = await Promise.all([T.bidPrice(), T.nftFund(), T.bidCost()]);
  if (bid > 0n && cost > 0n) {
    const affordable = Number(fund / cost);
    const n = Math.min(OPEN_ORDERS, affordable);
    if (n > 0) {
      const expiry = Math.floor(Date.now() / 1000) + TTL;
      await (await T.placeBuyOrders(n, bid, expiry)).wait();
      log(`挂 ${n} 张买单 @${ethers.formatEther(bid)} BNB（基金 ${ethers.formatEther(fund)}）`);
    } else log(`收购基金不足（${ethers.formatEther(fund)} < ${ethers.formatEther(cost)}），暂不挂买单`);
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
      console.log('  ORDER', JSON.stringify({ tokenId: id, order: order.map(String), hash: h }));
    } catch (e) { log(`挂卖单 #${id} 失败: ${(e.shortMessage || e.message).slice(0, 80)}`); }
  }

  // ⑥ 闲置 WBNB 换回 BNB
  try { await (await T.unwrapIdle()).wait(); } catch {}
}

log(`keeper 启动 → treasury ${TREASURY}`);
do {
  try { await tick(); } catch (e) { log('错误:', e.shortMessage || e.message); }
  if (!ONCE) await new Promise(r => setTimeout(r, POLL));
} while (!ONCE);
