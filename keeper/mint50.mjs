// 批量钱包铸造脚本（BSC 主网）
//   node mint50.mjs status                      # 看 50 个钱包的 BNB / 牛来 / 已持有 NFT
//   node mint50.mjs reserve                     # 方式 A：owner 用 reserveMint 免费铸 1 枚到每个钱包（不用给钱包打钱）
//   node mint50.mjs fund                        # 方式 B 第一步：FUNDER_PK 给每个钱包打 BNB gas + 1 牛来（你自己跑）
//   node mint50.mjs mint                        # 方式 B 第二步：每个钱包 approve + mint(1)
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
const WALLETS = process.env.WALLETS || fileURLToPath(new URL('../wallets/wallets-50.json', import.meta.url));
const FUND_BNB = process.env.FUND_BNB || '0.0002';

const NFT_ABI = ['function price() view returns (uint256)', 'function balanceOf(address) view returns (uint256)', 'function totalSupply() view returns (uint256)',
  'function reserveRemaining() view returns (uint32)', 'function setReserve(uint32)', 'function reserveMint(address,uint32)', 'function mint(uint32)',
  'function maxPerWallet() view returns (uint32)', 'function minted(address) view returns (uint32)', 'function publicSaleActive() view returns (bool)'];
const ERC20_ABI = ['function balanceOf(address) view returns (uint256)', 'function allowance(address,address) view returns (uint256)', 'function approve(address,uint256) returns (bool)', 'function transfer(address,uint256) returns (bool)'];

const provider = new ethers.JsonRpcProvider(RPC, 56, { staticNetwork: ethers.Network.from(56) });
const wallets = JSON.parse(fs.readFileSync(WALLETS, 'utf8'));
const nftR = new ethers.Contract(NFT, NFT_ABI, provider);
const tokR = new ethers.Contract(TOKEN, ERC20_ABI, provider);
const cmd = process.argv[2] || 'status';
const f = (v, d = 18) => ethers.formatUnits(v, d);

async function status() {
  const price = await nftR.price();
  console.log(`price ${f(price)} 牛来 · supply ${await nftR.totalSupply()}/999 · reserveRemaining ${await nftR.reserveRemaining()}`);
  let needBnb = 0n, needTok = 0n;
  for (const w of wallets) {
    const [bnb, tok, nft, allow] = await Promise.all([provider.getBalance(w.address), tokR.balanceOf(w.address), nftR.balanceOf(w.address), tokR.allowance(w.address, NFT)]);
    console.log(`#${String(w.i).padStart(2)} ${w.address}  BNB ${f(bnb)}  牛来 ${f(tok)}  NFT ${nft}  allow ${allow >= price ? 'ok' : 'no'}`);
    if (nft === 0n) { if (bnb < ethers.parseEther(FUND_BNB)) needBnb += ethers.parseEther(FUND_BNB) - bnb; if (tok < price) needTok += price - tok; }
  }
  console.log(`还需补充：BNB ${f(needBnb)} · 牛来 ${f(needTok)}`);
}

async function reserve() {
  const owner = new ethers.NonceManager(new ethers.Wallet(process.env.OWNER_PK, provider));
  const nft = nftR.connect(owner);
  const todo = [];
  for (const w of wallets) if ((await nftR.balanceOf(w.address)) === 0n) todo.push(w);
  console.log(`待铸 ${todo.length} 个钱包`);
  const rem = Number(await nftR.reserveRemaining());
  if (rem < todo.length) { console.log(`reserveRemaining ${rem} < ${todo.length}，先 setReserve(${todo.length})`); await (await nft.setReserve(todo.length)).wait(); }
  const txs = [];
  for (const w of todo) txs.push(nft.reserveMint(w.address, 1).then(tx => tx.wait().then(r => { console.log(`#${w.i} ${w.address} ✔ ${r.hash}`); return r; })));
  const rs = await Promise.allSettled(txs);
  console.log(`成功 ${rs.filter(r => r.status === 'fulfilled').length} / ${rs.length}`);
  rs.filter(r => r.status === 'rejected').forEach(r => console.log('✘', String(r.reason).slice(0, 200)));
}

async function fund() {
  const funder = new ethers.NonceManager(new ethers.Wallet(process.env.FUNDER_PK, provider));
  const tok = tokR.connect(funder);
  const price = await nftR.price();
  for (const w of wallets) {
    if ((await nftR.balanceOf(w.address)) > 0n) continue;
    const [bnb, t] = await Promise.all([provider.getBalance(w.address), tokR.balanceOf(w.address)]);
    const ops = [];
    if (bnb < ethers.parseEther(FUND_BNB)) ops.push(funder.sendTransaction({ to: w.address, value: ethers.parseEther(FUND_BNB) - bnb }));
    if (t < price) ops.push(tok.transfer(w.address, price - t));
    const rs = await Promise.all(ops); await Promise.all(rs.map(r => r.wait()));
    console.log(`#${w.i} ${w.address} 已补 ${ops.length} 笔`);
  }
}

async function mint() {
  const price = await nftR.price();
  if (!(await nftR.publicSaleActive())) throw new Error('公售未开启');
  const jobs = wallets.map(async w => {
    const s = new ethers.NonceManager(new ethers.Wallet(w.privateKey, provider));
    const nft = nftR.connect(s), tok = tokR.connect(s);
    if ((await nftR.balanceOf(w.address)) > 0n) return `#${w.i} 已持有，跳过`;
    if ((await provider.getBalance(w.address)) === 0n) return `#${w.i} 没有 BNB gas，跳过`;
    if ((await tokR.balanceOf(w.address)) < price) return `#${w.i} 牛来 不足，跳过`;
    if ((await tokR.allowance(w.address, NFT)) < price) await (await tok.approve(NFT, price)).wait();
    const r = await (await nft.mint(1)).wait();
    return `#${w.i} ${w.address} ✔ mint ${r.hash}`;
  });
  for (const r of await Promise.allSettled(jobs)) console.log(r.status === 'fulfilled' ? r.value : '✘ ' + String(r.reason).slice(0, 200));
}

({ status, reserve, fund, mint })[cmd]().catch(e => { console.error(e); process.exit(1); });
