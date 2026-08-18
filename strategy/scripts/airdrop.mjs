// 按 alloc 文件批量发放 NLSTR。断点续传：已发过的地址会跳过。
//   DRY=1 node scripts/airdrop.mjs airdrop/alloc-<block>.json          # 只算不发
//   SENDER_PK=0x.. NLSTR=0x.. BATCH_SENDER=0x.. node scripts/airdrop.mjs airdrop/alloc-<block>.json
import fs from 'node:fs';
import { ethers } from 'ethers';

const file = process.argv[2];
if (!file) { console.error('用法: node scripts/airdrop.mjs <alloc.json>'); process.exit(1); }
const RPC = process.env.RPC_URL || 'https://bsc-dataseed.bnbchain.org';
const BATCH = Number(process.env.BATCH || 100);
const DRY = process.env.DRY === '1';

const data = JSON.parse(fs.readFileSync(file, 'utf8'));
const entries = Object.entries(data.allocation);
const total = entries.reduce((s, [, v]) => s + BigInt(v), 0n);
console.log(`名单 ${entries.length} 个地址，合计 ${ethers.formatUnits(total, 18)} NLSTR（快照区块 ${data.block}）`);

const donePath = file.replace('alloc-', 'sent-');
const done = fs.existsSync(donePath) ? new Set(JSON.parse(fs.readFileSync(donePath, 'utf8'))) : new Set();
const todo = entries.filter(([a]) => !done.has(a));
console.log(`已发 ${done.size}，待发 ${todo.length}`);
if (DRY) {
  console.log('DRY 模式，前 5 条：');
  todo.slice(0, 5).forEach(([a, v]) => console.log(`  ${a}  ${ethers.formatUnits(v, 18)}`));
  process.exit(0);
}

const provider = new ethers.JsonRpcProvider(RPC, 56, { staticNetwork: ethers.Network.from(56) });
const signer = new ethers.NonceManager(new ethers.Wallet(process.env.SENDER_PK, provider));
const nlstr = new ethers.Contract(process.env.NLSTR, [
  'function approve(address,uint256) returns (bool)',
  'function allowance(address,address) view returns (uint256)',
  'function balanceOf(address) view returns (uint256)',
], signer);
const sender = new ethers.Contract(process.env.BATCH_SENDER,
  ['function disperse(address token, address[] to, uint256[] amounts)'], signer);

const me = await signer.getAddress();
const bal = await nlstr.balanceOf(me);
const need = todo.reduce((s, [, v]) => s + BigInt(v), 0n);
console.log(`发放钱包 ${me} 余额 ${ethers.formatUnits(bal, 18)}，本次需要 ${ethers.formatUnits(need, 18)}`);
if (bal < need) { console.error('余额不足'); process.exit(1); }

if ((await nlstr.allowance(me, process.env.BATCH_SENDER)) < need) {
  console.log('approve…');
  await (await nlstr.approve(process.env.BATCH_SENDER, ethers.MaxUint256)).wait();
}

for (let i = 0; i < todo.length; i += BATCH) {
  const chunk = todo.slice(i, i + BATCH);
  const tx = await sender.disperse(process.env.NLSTR, chunk.map(c => c[0]), chunk.map(c => c[1]));
  const r = await tx.wait();
  chunk.forEach(([a]) => done.add(a));
  fs.writeFileSync(donePath, JSON.stringify([...done], null, 0));
  console.log(`  ${done.size}/${entries.length}  tx ${r.hash}  gas ${r.gasUsed}`);
}
console.log('✔ 全部发放完成 →', donePath);
