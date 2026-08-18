// 冻结持有者快照：在某个确定区块上读取全部 999 枚的 ownerOf，写成名单文件。
//   node scripts/snapshot.mjs                 # 用最新区块
//   node scripts/snapshot.mjs --block 1234567 # 指定区块
import fs from 'node:fs';
import { ethers } from 'ethers';

const RPC = process.env.RPC_URL || 'https://lb.drpc.live/bsc/AsVs23QoLEOwisC7Py3FTOo-9Orrf6UR8a6vijtBrJVX';
const NFT = process.env.NFT || '0x5fd0d8FeCF408f61080cEa470249026d3e02fB3D';
const SUPPLY_NFT = 999;
const EXCLUDE = new Set([
  '0x000000000000000000000000000000000000dead',
  ...(process.env.EXCLUDE || '').toLowerCase().split(',').filter(Boolean),
]);

const argBlock = (() => { const i = process.argv.indexOf('--block'); return i > 0 ? Number(process.argv[i + 1]) : null; })();

const provider = new ethers.JsonRpcProvider(RPC, 56, { staticNetwork: ethers.Network.from(56) });
const nft = new ethers.Contract(NFT, ['function ownerOf(uint256) view returns (address)'], provider);

const block = argBlock ?? await provider.getBlockNumber();
console.log(`在区块 ${block} 上快照 ${NFT}`);

// 记录每个持有者具体持有哪些 tokenId —— 稀有度加权需要
const owners = {};
for (let s = 1; s <= SUPPLY_NFT; s += 50) {
  const ids = Array.from({ length: Math.min(50, SUPPLY_NFT - s + 1) }, (_, k) => s + k);
  const res = await Promise.all(ids.map(id => nft.ownerOf(id, { blockTag: block })));
  res.forEach((a, k) => { const key = a.toLowerCase(); (owners[key] ||= []).push(ids[k]); });
  process.stdout.write(`\r  ${Math.min(s + 49, SUPPLY_NFT)}/${SUPPLY_NFT}`);
}
console.log();

for (const e of EXCLUDE) if (owners[e]) { console.log(`  排除 ${e}（${owners[e].length} 枚）`); delete owners[e]; }

const entries = Object.entries(owners).sort((a, b) => b[1].length - a[1].length);
const totalNfts = entries.reduce((s, [, v]) => s + v.length, 0);
const out = {
  chainId: 56, nft: NFT, block,
  takenAt: new Date().toISOString(),
  holders: entries.length, totalNfts,
  tokens: Object.fromEntries(entries),
};
const path = `airdrop/snapshot-${block}.json`;
fs.writeFileSync(path, JSON.stringify(out, null, 1));
console.log(`✔ ${entries.length} 个持有者，共 ${totalNfts} 枚 → ${path}`);
console.log(`  前 5 大：${entries.slice(0, 5).map(([a, v]) => `${a.slice(0, 8)}…(${v.length})`).join(' ')}`);
console.log(`  只持 1 枚的：${entries.filter(([, v]) => v.length === 1).length} 人`);
