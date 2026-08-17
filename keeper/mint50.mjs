// 批量钱包铸造脚本（BSC 主网）
//   node mint50.mjs status                      # 看 50 个钱包的 BNB / 牛来 / 已持有 NFT
//   node mint50.mjs reserve                     # 方式 A：owner 用 reserveMint 免费铸 1 枚到每个钱包（不用给钱包打钱）
//   node mint50.mjs fund                        # 方式 B 第一步：FUNDER_PK 给每个钱包打 BNB gas + 1 牛来（你自己跑）
//   node mint50.mjs mint                        # 方式 B 第二步：每个钱包 approve + mint(1)
//   TO=0x目标地址 node mint50.mjs sweep          # 归集：每个钱包的 NFT + 牛来 + 剩余 BNB（扣 gas）全部转到 TO，出错自动重试并复查；SWEEP_NFT=0 不动 NFT，SWEEP_BNB=0 不动 BNB
// 环境变量：WALLETS=../wallets/wallets-50.json  RPC_URL  OWNER_PK（reserve 用）  FUNDER_PK（fund 用）
//          FUND_BNB=0.0002  NFT / TOKEN 默认牛来合约
import fs from 'node:fs';
import { fileURLToPath } from 'node:url';
import { ethers } from 'ethers';

// 读同目录 .env（不覆盖已有环境变量），可放 RPC_URL / OWNER_PK / FUNDER_PK
try { for (const l of fs.readFileSync(fileURLToPath(new URL('./.env', import.meta.url)), 'utf8').split('\n')) { const m = l.match(/^\s*([A-Z_]+)\s*=\s*(.*)\s*$/); if (m && !(m[1] in process.env)) process.env[m[1]] = m[2]; } } catch {}
const RPC = process.env.RPC_URL || 'https://bsc-dataseed.bnbchain.org';
const NFT = process.env.NFT || '0x5fd0d8FeCF408f61080cEa470249026d3e02fB3D';
const TOKEN = process.env.TOKEN || '0xBEEA1D618e533a387D941F58a7d4c9b7bD377777';
const WALLETS = process.env.WALLETS;
const FUND_BNB = process.env.FUND_BNB || '0.0002';

const NFT_ABI = ['function price() view returns (uint256)', 'function balanceOf(address) view returns (uint256)', 'function totalSupply() view returns (uint256)',
  'function reserveRemaining() view returns (uint32)', 'function setReserve(uint32)', 'function reserveMint(address,uint32)', 'function mint(uint32)',
  'function maxPerWallet() view returns (uint32)', 'function minted(address) view returns (uint32)', 'function publicSaleActive() view returns (bool)'];
const ERC20_ABI = ['function balanceOf(address) view returns (uint256)', 'function allowance(address,address) view returns (uint256)', 'function approve(address,uint256) returns (bool)', 'function transfer(address,uint256) returns (bool)'];

const provider = new ethers.JsonRpcProvider(RPC, 56, { staticNetwork: ethers.Network.from(56) });
// 未指定 WALLETS 时，合并读取 wallets/ 下所有 wallets-*.json（50 + 20 + …），标签形如 50#3 / 20#7
const wallets = process.env.WALLETS ? JSON.parse(fs.readFileSync(WALLETS, 'utf8')).map(w => ({ ...w, tag: String(w.i) })) : (() => {
  const dir = fileURLToPath(new URL('../wallets/', import.meta.url));
  return fs.readdirSync(dir).filter(n => /^wallets-\d+\.json$/.test(n)).sort((a, b) => parseInt(b.match(/\d+/)[0]) - parseInt(a.match(/\d+/)[0]))
    .flatMap(n => JSON.parse(fs.readFileSync(dir + n, 'utf8')).map(w => ({ ...w, tag: `${n.match(/\d+/)[0]}#${w.i}` })));
})();
console.log(`钱包 ${wallets.length} 个`);
const nftR = new ethers.Contract(NFT, NFT_ABI, provider);
const tokR = new ethers.Contract(TOKEN, ERC20_ABI, provider);

// 私钥/助记词解析：支持 0x 开头的 64 位 hex、无 0x 的 hex、12/24 词助记词
function signerFrom(name) {
  let v = (process.env[name] || '').trim().replace(/^['"]|['"]$/g, '');
  if (!v) throw new Error(`缺少 ${name}：命令前加 ${name}=0x私钥（或写进 keeper/.env）`);
  let w;
  if (v.split(/\s+/).length >= 12) w = ethers.Wallet.fromPhrase(v, provider);
  else { if (!v.startsWith('0x')) v = '0x' + v; if (!/^0x[0-9a-fA-F]{64}$/.test(v)) throw new Error(`${name} 不是有效私钥（应为 0x + 64 位十六进制）`); w = new ethers.Wallet(v, provider); }
  console.log(`${name} → ${w.address}`);
  return new ethers.NonceManager(w);
}

const cmd = process.argv[2] || 'status';
const f = (v, d = 18) => ethers.formatUnits(v, d);

async function status() {
  const price = await nftR.price();
  console.log(`price ${f(price)} 牛来 · supply ${await nftR.totalSupply()}/999 · reserveRemaining ${await nftR.reserveRemaining()}`);
  let needBnb = 0n, needTok = 0n;
  for (const w of wallets) {
    const [bnb, tok, nft, allow] = await Promise.all([provider.getBalance(w.address), tokR.balanceOf(w.address), nftR.balanceOf(w.address), tokR.allowance(w.address, NFT)]);
    console.log(`#${w.tag.padStart(5)} ${w.address}  BNB ${f(bnb)}  牛来 ${f(tok)}  NFT ${nft}  allow ${allow >= price ? 'ok' : 'no'}`);
    if (nft === 0n) { if (bnb < ethers.parseEther(FUND_BNB)) needBnb += ethers.parseEther(FUND_BNB) - bnb; if (tok < price) needTok += price - tok; }
  }
  console.log(`还需补充：BNB ${f(needBnb)} · 牛来 ${f(needTok)}`);
}

async function reserve() {
  const owner = signerFrom('OWNER_PK');
  const nft = nftR.connect(owner);
  const todo = [];
  for (const w of wallets) if ((await nftR.balanceOf(w.address)) === 0n) todo.push(w);
  console.log(`待铸 ${todo.length} 个钱包`);
  const rem = Number(await nftR.reserveRemaining());
  if (rem < todo.length) { console.log(`reserveRemaining ${rem} < ${todo.length}，先 setReserve(${todo.length})`); await (await nft.setReserve(todo.length)).wait(); }
  const txs = [];
  for (const w of todo) txs.push(nft.reserveMint(w.address, 1).then(tx => tx.wait().then(r => { console.log(`#${w.tag} ${w.address} ✔ ${r.hash}`); return r; })));
  const rs = await Promise.allSettled(txs);
  console.log(`成功 ${rs.filter(r => r.status === 'fulfilled').length} / ${rs.length}`);
  rs.filter(r => r.status === 'rejected').forEach(r => console.log('✘', String(r.reason).slice(0, 200)));
}

async function fund() {
  const funder = signerFrom('FUNDER_PK');
  const tok = tokR.connect(funder);
  const price = await nftR.price();
  for (const w of wallets) {
    if ((await nftR.balanceOf(w.address)) > 0n) continue;
    const [bnb, t] = await Promise.all([provider.getBalance(w.address), tokR.balanceOf(w.address)]);
    const ops = [];
    if (bnb < ethers.parseEther(FUND_BNB)) ops.push(funder.sendTransaction({ to: w.address, value: ethers.parseEther(FUND_BNB) - bnb }));
    if (t < price) ops.push(tok.transfer(w.address, price - t));
    const rs = await Promise.all(ops); await Promise.all(rs.map(r => r.wait()));
    console.log(`#${w.tag} ${w.address} 已补 ${ops.length} 笔`);
  }
}

async function mint() {
  const price = await nftR.price();
  if (!(await nftR.publicSaleActive())) throw new Error('公售未开启');
  const jobs = wallets.map(async w => {
    const s = new ethers.NonceManager(new ethers.Wallet(w.privateKey, provider));
    const nft = nftR.connect(s), tok = tokR.connect(s);
    if ((await nftR.balanceOf(w.address)) > 0n) return `#${w.tag} 已持有，跳过`;
    if ((await provider.getBalance(w.address)) === 0n) return `#${w.tag} 没有 BNB gas，跳过`;
    if ((await tokR.balanceOf(w.address)) < price) return `#${w.tag} 牛来 不足，跳过`;
    if ((await tokR.allowance(w.address, NFT)) < price) await (await tok.approve(NFT, price)).wait();
    const r = await (await nft.mint(1)).wait();
    return `#${w.tag} ${w.address} ✔ mint ${r.hash}`;
  });
  for (const r of await Promise.allSettled(jobs)) console.log(r.status === 'fulfilled' ? r.value : '✘ ' + String(r.reason).slice(0, 200));
}


async function sweepOnce(to, withNft) {
  const nftT = new ethers.Contract(NFT, ['function ownerOf(uint256) view returns (address)', 'function totalSupply() view returns (uint256)', 'function transferFrom(address,address,uint256)'], provider);
  // 不用 eth_getLogs（节点有区块范围限制）：直接对 1..totalSupply 逐个 ownerOf 建持有表（分批并发）
  const holdings = new Map();
  if (withNft) {
    const n = Number(await nftT.totalSupply()); const ids = Array.from({ length: n }, (_, i) => i + 1);
    for (let i = 0; i < ids.length; i += 100) {
      const chunk = ids.slice(i, i + 100);
      const owners = await Promise.all(chunk.map(id => nftT.ownerOf(id).catch(() => null)));
      chunk.forEach((id, k) => { const o = owners[k] && owners[k].toLowerCase(); if (o) holdings.set(o, [...(holdings.get(o) || []), id]); });
    }
  }
  const fee = await provider.getFeeData(); const gasPrice = fee.gasPrice;
  let sumBnb = 0n, sumTok = 0n, sumNft = 0, left = 0, errs = 0;
  for (const w of wallets) {
    const acts = [];
    try {
      const s = new ethers.NonceManager(new ethers.Wallet(w.privateKey, provider));
      const bnb0 = await provider.getBalance(w.address);
      const tokBal = await tokR.balanceOf(w.address);
      const myNfts = withNft ? (holdings.get(w.address.toLowerCase()) || []) : [];
      if (bnb0 === 0n) { if (tokBal > 0n || myNfts.length) { left++; console.log(`#${w.tag} ${w.address} 没有 BNB gas，无法转出（牛来 ${f(tokBal)}，NFT ${myNfts.length}）`); } continue; }
      if (tokBal > 0n) { await (await tokR.connect(s).transfer(to, tokBal, { gasPrice })).wait(); acts.push(`牛来 ${f(tokBal)}`); sumTok += tokBal; }
      for (const id of myNfts) {
        try { await (await nftT.connect(s).transferFrom(w.address, to, id, { gasPrice })).wait(); acts.push(`NFT #${id}`); sumNft++; }
        catch (e) { errs++; acts.push(`NFT #${id} 失败 ${String(e.shortMessage || e.message).slice(0, 60)}`); }
      }
      const bnb = await provider.getBalance(w.address); const cost = 21000n * gasPrice; const val = bnb - cost;
      if (process.env.SWEEP_BNB !== '0' && val > 0n) { await (await s.sendTransaction({ to, value: val, gasLimit: 21000, gasPrice })).wait(); acts.push(`BNB ${f(val)}`); sumBnb += val; }
      if (acts.length) console.log(`#${w.tag} ${w.address} → ${acts.join(' · ')}`);
    } catch (e) { errs++; console.log(`#${w.tag} ${w.address} 出错：${String(e.shortMessage || e.message).slice(0, 100)}（继续下一个）`); }
  }
  console.log(`本轮归集到 ${to}：BNB ${f(sumBnb)} · 牛来 ${f(sumTok)}${withNft ? ` · NFT ${sumNft} 枚` : ''}；出错 ${errs}，无 gas 卡住 ${left}`);
  return { errs, left };
}

async function sweep() {
  const to = (process.env.TO || '').trim();
  if (!ethers.isAddress(to)) throw new Error('缺少 TO=0x目标地址');
  const withNft = process.env.SWEEP_NFT !== '0';   // 默认连 NFT 一起归集；SWEEP_NFT=0 只归集 牛来/BNB
  for (let pass = 1; pass <= 3; pass++) {
    console.log(`—— 第 ${pass} 遍 ——`);
    const { errs } = await sweepOnce(to, withNft);
    if (!errs) break;
    console.log('有失败项，10 秒后重试…'); await new Promise(r => setTimeout(r, 10000));
  }
  // 复查
  let restB = 0n, restT = 0n, restN = 0;
  const own = new ethers.Contract(NFT, ['function balanceOf(address) view returns (uint256)'], provider);
  for (const w of wallets) { const [b, t, n] = await Promise.all([provider.getBalance(w.address), tokR.balanceOf(w.address), own.balanceOf(w.address)]); restB += b; restT += t; restN += Number(n); }
  console.log(`复查：${wallets.length} 个钱包剩余 BNB ${f(restB)}（其中每个最多留了一笔 gas 的零头）· 牛来 ${f(restT)} · NFT ${restN}`);
}

({ status, reserve, fund, mint, sweep })[cmd]().catch(e => { console.error(e); process.exit(1); });
