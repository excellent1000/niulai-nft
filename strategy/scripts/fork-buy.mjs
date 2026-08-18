// 分叉演练用：走 Universal Router 真买一笔，验证池子确实活着、手续费确实进金库。
//   RPC=http://127.0.0.1:8546 PK=0x.. NLSTR=0x.. HOOK=0x.. TREASURY=0x.. BNB=1 node scripts/fork-buy.mjs
import { ethers } from 'ethers';
const RPC = process.env.RPC || 'http://127.0.0.1:8546';
const { PK, NLSTR, HOOK, TREASURY } = process.env;
const AMT = ethers.parseEther(process.env.BNB || '1');
const UR = '0x1906c1d672b88cD1B9aC7593301cA990F94Eae07';
const QUOTER = '0x9F75dD27D6664c475B90e105573E550ff69437B0';
const A = ethers.AbiCoder.defaultAbiCoder();
const KEY = ['address', 'address', 'uint24', 'int24', 'address'];
const key = () => [ethers.ZeroAddress, NLSTR, 0x800000, 60, HOOK];

const p = new ethers.JsonRpcProvider(RPC);
const w = new ethers.Wallet(PK, p);
const q = new ethers.Contract(QUOTER, ['function quoteExactInputSingle(((address,address,uint24,int24,address),bool,uint128,bytes)) returns (uint256,uint256)'], p);
const [out] = await q.quoteExactInputSingle.staticCall([key(), true, AMT, '0x']);
console.log(`报价：${ethers.formatEther(AMT)} BNB → ${(+ethers.formatEther(out)).toLocaleString()} NLSTR`);

const before = { t: await p.getBalance(TREASURY), n: await new ethers.Contract(NLSTR, ['function balanceOf(address) view returns (uint256)'], p).balanceOf(w.address) };
const actions = '0x' + ['06', '0c', '0f'].join('');   // SWAP_EXACT_IN_SINGLE, SETTLE_ALL, TAKE_ALL
const params = [
  A.encode([`((${KEY.join(',')}),bool,uint128,uint128,uint256,bytes)`], [[key(), true, AMT, (out * 95n) / 100n, 0n, '0x']]),
  A.encode(['address', 'uint256'], [ethers.ZeroAddress, AMT]),
  A.encode(['address', 'uint256'], [NLSTR, 0n]),
];
const ur = new ethers.Contract(UR, ['function execute(bytes,bytes[],uint256) payable'], w);
const blk = await p.getBlock('latest');
const tx = await ur.execute('0x10', [A.encode(['bytes', 'bytes[]'], [actions, params])], blk.timestamp + 600, { value: AMT });
const r = await tx.wait();
const after = { t: await p.getBalance(TREASURY), n: await new ethers.Contract(NLSTR, ['function balanceOf(address) view returns (uint256)'], p).balanceOf(w.address) };
console.log(`成交 ✔ gas ${r.gasUsed}`);
console.log(`  买家收到   ${(+ethers.formatEther(after.n - before.n)).toLocaleString()} NLSTR`);
console.log(`  金库收到   ${ethers.formatEther(after.t - before.t)} BNB（应 ≈ ${ethers.formatEther(AMT)} × 当前税率）`);
