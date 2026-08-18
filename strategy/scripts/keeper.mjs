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

const TX_TIMEOUT = Number(process.env.TX_TIMEOUT_MS || 90_000);   // 单笔交易等待上限
const TICK_TIMEOUT = Number(process.env.TICK_TIMEOUT_MS || 240_000); // 整轮上限

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
  'function keeper() view returns (address)',
  'function owner() view returns (address)',
  'function approvedListings(bytes32) view returns (bool)',
];
const EX_ABI = ['function getERC721SellOrderHash((address,address,uint256,uint256,address,uint256,(address,uint256,bytes)[],address,uint256) o) view returns (bytes32)'];

const provider = new ethers.JsonRpcProvider(RPC, 56, { staticNetwork: ethers.Network.from(56) });
const signer = new ethers.NonceManager(new ethers.Wallet(process.env.KEEPER_PK, provider));
const T = new ethers.Contract(TREASURY, T_ABI, signer);
// setBidPrice 是 onlyOwner，keeper 钱包调不了。owner 私钥单独放，只用于这一件事，
// 这样日常操作全走 keeper 钱包，两把钥匙几乎不会撞 nonce。
const ownerSigner = process.env.OWNER_PK
  ? new ethers.NonceManager(new ethers.Wallet(process.env.OWNER_PK, provider)) : null;
const T_owner = ownerSigner ? new ethers.Contract(TREASURY, T_ABI, ownerSigner) : null;
const EX = new ethers.Contract(ELEMENT, EX_ABI, provider);
const nft = new ethers.Contract(NFT, ['function ownerOf(uint256) view returns (address)'], provider);

// Element 成交不经过 sellToTreasury，收单价得由 keeper 手动阶梯上调
async function bumpBid(n) {
  const [cur, stepBps, maxBid] = await Promise.all([T.bidPrice(), T.bidStepBps(), T.maxBidPrice()]);
  let next = cur;
  for (let i = 0; i < n; i++) next = next + (next * BigInt(stepBps)) / 10000n;
  if (maxBid > 0n && next > maxBid) next = maxBid;
  if (next === cur) return;
  if (!T_owner) { log(`⚠ 收了 ${n} 枚，收单价该涨到 ${ethers.formatEther(next)}，但没配 OWNER_PK，请手动 setBidPrice`); return; }
  ownerSigner.reset();
  await (await T_owner.setBidPrice(next)).wait(1, TX_TIMEOUT);
  log(`收单价 ${ethers.formatEther(cur)} → ${ethers.formatEther(next)}（收了 ${n} 枚）`);
}

// 记录已挂卖单：tokenId -> 挂单净收价。落盘，否则每次重启都把全部库存重挂一遍
// （今天 7 次重启 = 47 笔交易只为 11 枚货）。存价格而不是只存 id，是因为柜台价会随
// 收单价上涨，只记 id 的话旧的低价卖单永远不会被更新，等于在贱卖。
const LISTED_FILE = process.env.LISTED_FILE || '/opt/niulai/strategy/listed.json';
let listed = new Map();
try { listed = new Map(Object.entries(JSON.parse(fs.readFileSync(LISTED_FILE, 'utf8'))).map(([k, v]) => [Number(k), String(v)])); }
catch {}
const saveListed = () => { try { fs.writeFileSync(LISTED_FILE, JSON.stringify(Object.fromEntries(listed))); } catch {} };
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
  try { await (await T.collectFees(TICK_LOWER, TICK_UPPER)).wait(1, TX_TIMEOUT); log('collectFees ✔'); }
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
    await (await T.syncInventory(toSync)).wait(1, TX_TIMEOUT);
    log(`syncInventory：入库 ${toAdd.length}，出库 ${toRemove.length}`);
    toRemove.forEach(id => { listed.delete(id); book.sell = book.sell.filter(x => x.tokenId !== id); });
    if (toRemove.length) saveListed();
    // 走 Element 买单成交的，合约里 sellToTreasury 根本没被调用 —— 收单价不会自动 +2%。
    // 「只涨不跌，每收一枚上调」是对外承诺的机制，这里补上。
    if (toAdd.length) await bumpBid(toAdd.length);
  }

  // ③ 卖货所得：先回本金，只烧利润
  const bal = await provider.getBalance(TREASURY);
  const fundNow = await T.nftFund();
  if (bal > fundNow) {
    await (await T.processSaleProceeds()).wait(1, TX_TIMEOUT);
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
      // 先撤掉上一批：合约不会自动取消，旧单会一直可成交，
      // 而 committedWbnb 是覆盖不是累加 —— 留着它们只会让一部分单在成交时因 WBNB 不足而失败，
      // 而且旧单价更低，等于给人留了个更便宜的口子。
      const stale = book.buy.map(x => x.nonce);
      if (stale.length) {
        try { await (await T.cancelBuyOrders(stale)).wait(1, TX_TIMEOUT); log(`撤掉旧买单 ${stale.join(',')}`); }
        catch (e) { log('撤旧单失败（不阻塞）：' + (e.shortMessage || e.message)); }
      }
      await (await T.placeBuyOrders(n, bid, expiry)).wait(1, TX_TIMEOUT);
      book.buy = [];
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
    if (listed.get(id) === net.toString()) continue;   // 已按当前价挂过
    const order = [
      TREASURY, ethers.ZeroAddress, Math.floor(Date.now() / 1000) + TTL,
      Number(await T.nextOrderNonce()) + 900000 + id,
      NATIVE, net, [[vault, (ask * BigInt(royBps)) / 10000n, '0x']], NFT, id,
    ];
    try {
      await (await T.approveListing(order)).wait(1, TX_TIMEOUT);
      const h = await EX.getERC721SellOrderHash(order);
      listed.set(id, net.toString()); saveListed();
      log(`挂卖单 #${id} 净收 ${ethers.formatEther(net)} BNB  hash ${h.slice(0, 12)}…`);
      // 订单数据需要发布出去（网站/事件）才能被买家发现
      book.sell.push({ tokenId: id, hash: h, price: (net + (ask * BigInt(royBps)) / 10000n).toString(), net: net.toString(), order });
      console.log('  SELL_ORDER', J({ tokenId: id, hash: h, order }));
    } catch (e) {
      const m = (e.shortMessage || e.message || '');
      log(`挂卖单 #${id} 失败: ${m.slice(0, 80)}`);
      // 超时/nonce 类错误后，缓存的 nonce 已不可信，立刻与链上对齐，
      // 否则本轮后面每一笔都会连锁失败
      if (/timeout|nonce|replacement|underpriced/i.test(m)) signer.reset();
    }
  }

  publish();

  // ⑥ 把**超出挂单占用**的 WBNB 换回 BNB（合约里有 committedWbnb 保护，不会挖空未成交的买单）
  try { await (await T.unwrapIdle()).wait(1, TX_TIMEOUT); } catch {}
}

{
  const me = await signer.getAddress();
  const bal = await provider.getBalance(me);
  log(`keeper 启动 → treasury ${TREASURY}`);
  log(`  执行钱包 ${me}  gas 余额 ${ethers.formatEther(bal)} BNB`);
  if (bal < ethers.parseEther('0.005')) log('  ⚠ gas 快没了，充点 BNB');
  const onchainKeeper = await T.keeper();
  if (onchainKeeper.toLowerCase() !== me.toLowerCase() && (await T.owner()).toLowerCase() !== me.toLowerCase())
    log(`  ⚠ 链上 keeper 是 ${onchainKeeper}，不是本钱包 —— 挂单类操作会被拒，先 setKeeper`);
  if (T_owner) log(`  调价钱包 ${await ownerSigner.getAddress()}（只用于 setBidPrice）`);
}
do {
  // 这个钱包同时被分红 keeper 和人手操作用着，NonceManager 缓存的 nonce 随时会过期。
  // 每轮开头先和链上对齐，出 nonce 类错误就重置后立刻重来一次。
  signer.reset();
  try {
    // 整轮加超时兜底：曾经因为一笔交易卡在内存池、.wait() 永不返回，keeper 静默停摆
    await Promise.race([tick(), new Promise((_, rej) => setTimeout(() => rej(new Error('本轮超时')), TICK_TIMEOUT))]);
  } catch (e) {
    const msg = e.shortMessage || e.message || '';
    log('错误:', msg);
    if (/nonce|replacement|already known|underpriced/i.test(msg)) {
      signer.reset(); log('nonce 已重置，立即重试');
      try { await Promise.race([tick(), new Promise((_, rej) => setTimeout(() => rej(new Error('本轮超时')), TICK_TIMEOUT))]); }
      catch (e2) { log('重试仍失败:', e2.shortMessage || e2.message); }
    }
  }
  if (!ONCE) await new Promise(r => setTimeout(r, POLL));
} while (!ONCE);
