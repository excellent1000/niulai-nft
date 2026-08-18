// 按稀有度加权计算空投额度。
//   node scripts/allocate.mjs airdrop/snapshot-<block>.json [--weights 10,5,2,1] [--pool 100000000]
import fs from 'node:fs';

const snapPath = process.argv[2];
if (!snapPath) { console.error('用法: node scripts/allocate.mjs <snapshot.json> [--weights 传说,史诗,稀有,普通] [--pool 枚数]'); process.exit(1); }
const arg = (n, d) => { const i = process.argv.indexOf(n); return i > 0 ? process.argv[i + 1] : d; };

const TIERS = ['传说', '史诗', '稀有', '普通'];
const weights = Object.fromEntries(arg('--weights', '10,5,2,1').split(',').map((w, i) => [TIERS[i], Number(w)]));
const POOL = BigInt(arg('--pool', '100000000')) * 10n ** 18n;   // 默认 1 亿枚（总量 10%）

const snap = JSON.parse(fs.readFileSync(snapPath, 'utf8'));
const tiers = JSON.parse(fs.readFileSync('airdrop/tiers.json', 'utf8'));

let totalWeight = 0;
const perHolder = {};
for (const [addr, ids] of Object.entries(snap.tokens)) {
  const w = ids.reduce((s, id) => s + (weights[tiers[String(id)]] ?? 1), 0);
  perHolder[addr] = w; totalWeight += w;
}

const alloc = {};
let assigned = 0n;
const sorted = Object.entries(perHolder).sort((a, b) => b[1] - a[1]);
for (const [addr, w] of sorted) {
  const amt = POOL * BigInt(w) / BigInt(totalWeight);
  alloc[addr] = amt.toString(); assigned += amt;
}
// 余数（向下取整产生的）补给最大持有者
if (assigned < POOL) alloc[sorted[0][0]] = (BigInt(alloc[sorted[0][0]]) + (POOL - assigned)).toString();

const perW = Number(POOL / BigInt(totalWeight)) / 1e18;
console.log(`权重 ${JSON.stringify(weights)}  总权重 ${totalWeight}`);
console.log(`每单位权重 ${perW.toLocaleString(undefined, { maximumFractionDigits: 0 })} 枚 NLSTR`);
console.log('单枚 NFT 能拿到：');
for (const t of TIERS) console.log(`  ${t.padEnd(3)} ×${String(weights[t]).padStart(2)} → ${(perW * weights[t]).toLocaleString(undefined, { maximumFractionDigits: 0 }).padStart(11)} 枚`);
console.log(`\n持有者 ${sorted.length} 个，最大 ${(Number(BigInt(alloc[sorted[0][0]]) / 10n ** 18n)).toLocaleString()} 枚（${sorted[0][0].slice(0, 10)}…）`);
const out = { ...snap, weights, pool: POOL.toString(), totalWeight, allocation: alloc };
const path = snapPath.replace('snapshot-', 'alloc-');
fs.writeFileSync(path, JSON.stringify(out, null, 1));
console.log(`→ ${path}`);
