#!/usr/bin/env node
// 牛来 NFT 金库 keeper：每小时买入 $牛来 并把分发批次跑完。
//   npm i ethers dotenv
//   node keeper/harvest.mjs            # 常驻：每 60s 检查一次
//   node keeper/harvest.mjs --once     # 跑一轮就退出（配 cron: 5 * * * *）
// .env（keeper/.env）：RPC_URL, KEEPER_PK, VAULT, [QUOTER], [SLIPPAGE_BPS=150], [BATCH=250], [POLL_SEC=60], [GAS_GWEI]
import 'dotenv/config';
import { ethers } from 'ethers';

const RPC_URL = process.env.RPC_URL || 'https://bsc-dataseed.binance.org';
const KEEPER_PK = process.env.KEEPER_PK;
const VAULT = process.env.VAULT;
const QUOTER = process.env.QUOTER || '0xB048Bbc1Ee6b733FFfCFb9e9CeF7375518e25997'; // PancakeSwap V3 QuoterV2 (BSC)
const SLIPPAGE_BPS = Number(process.env.SLIPPAGE_BPS || 150);
const BATCH = Number(process.env.BATCH || 250);
const POLL_SEC = Number(process.env.POLL_SEC || 60);
const ONCE = process.argv.includes('--once');
// 其他币种版税（如 USDT）：逗号分隔地址；金库需已 setTokenSwapPath
const EXTRA_TOKENS = (process.env.EXTRA_TOKENS || '0x55d398326f99059fF775485246999027B3197955').split(',').map(s => s.trim()).filter(Boolean);
const EXTRA_MIN = ethers.parseEther(process.env.EXTRA_MIN || '5'); // 少于这个数（按 18 位）不动
if (!KEEPER_PK || !VAULT) { console.error('缺少 KEEPER_PK / VAULT'); process.exit(1); }

const VAULT_ABI = [
  'function canHarvest() view returns (bool ready, uint256 available, uint256 nextTime)',
  'function harvest(uint256 minOut) returns (uint256)',
  'function harvestToken(address token, uint256 minOut) returns (uint256)',
  'function tokenSwapPath(address) view returns (bytes)',
  'function distribute(uint256 count)',
  'function roundActive() view returns (bool)',
  'function remainingInRound() view returns (uint256)',
  'function swapPath() view returns (bytes)',
  'function callerRewardBps() view returns (uint16)',
  'function wbnb() view returns (address)',
  'event Harvested(uint256 indexed roundId, address indexed caller, uint256 bnbIn, uint256 tokenOut, uint256 callerReward)',
  'event RoundFinished(uint256 indexed roundId, uint256 distributed)',
];
const ERC20_ABI = ['function balanceOf(address) view returns (uint256)', 'function symbol() view returns (string)'];
const QUOTER_ABI = ['function quoteExactInput(bytes path, uint256 amountIn) returns (uint256 amountOut, uint160[] sqrtPriceX96AfterList, uint32[] initializedTicksCrossedList, uint256 gasEstimate)'];

const provider = new ethers.JsonRpcProvider(RPC_URL, 56);
const wallet = new ethers.Wallet(KEEPER_PK, provider);
const signer = new ethers.NonceManager(wallet);   // 连续多笔交易时自动递增 nonce
const vault = new ethers.Contract(VAULT, VAULT_ABI, signer);
const quoter = new ethers.Contract(QUOTER, QUOTER_ABI, provider);
const log = (...a) => console.log(new Date().toISOString(), ...a);

function overrides() {
  const o = {};
  if (process.env.GAS_GWEI) o.gasPrice = ethers.parseUnits(process.env.GAS_GWEI, 'gwei');
  return o;
}

async function distributeAll() {
  while (await vault.roundActive()) {
    const remaining = await vault.remainingInRound();
    const n = remaining < BigInt(BATCH) ? remaining : BigInt(BATCH);
    const tx = await vault.distribute(n, overrides());
    log(`distribute(${n}) tx ${tx.hash}`);
    const rc = await tx.wait();
    log(`  ✔ block ${rc.blockNumber} gas ${rc.gasUsed}`);
  }
}

async function harvestExtraTokens() {
  for (const t of EXTRA_TOKENS) {
    try {
      const erc = new ethers.Contract(t, ERC20_ABI, provider);
      const bal = await erc.balanceOf(VAULT);
      if (bal < EXTRA_MIN) continue;
      const path = await vault.tokenSwapPath(t);
      if (!path || path === '0x') { log(`金库有 ${ethers.formatEther(bal)} 的 ${t}，但未配置 tokenSwapPath，跳过`); continue; }
      const q = await quoter.quoteExactInput.staticCall(path, bal);
      const minOut = (q[0] * BigInt(10000 - SLIPPAGE_BPS)) / 10000n;
      log(`ERC20 版税：${ethers.formatEther(bal)} ${await erc.symbol()} → ≥${ethers.formatEther(minOut)} 牛来`);
      const tx = await vault.harvestToken(t, minOut, overrides());
      log(`harvestToken tx ${tx.hash}`); const rc = await tx.wait(); log(`  ✔ block ${rc.blockNumber} gas ${rc.gasUsed}`);
      await distributeAll();
    } catch (e) { log(`harvestToken(${t}) 失败：`, e.shortMessage || e.message); }
  }
}

async function tick() {
  signer.reset();   // 每轮开始与链上 nonce 对齐（钱包可能在别处发过交易）
  // 上一轮没发完先补发（比如上次进程中途挂了）
  if (await vault.roundActive()) { log('上一轮未发完，继续分发…'); await distributeAll(); }
  await harvestExtraTokens();

  const [ready, available, nextTime] = await vault.canHarvest();
  if (!ready) {
    log(`未就绪：可用 ${ethers.formatEther(available)} BNB，下次 ${new Date(Number(nextTime) * 1000).toISOString()}`);
    return;
  }
  const bps = await vault.callerRewardBps();
  const amountIn = available - (available * BigInt(bps)) / 10000n;
  const path = await vault.swapPath();
  let minOut = 0n;
  try {
    const q = await quoter.quoteExactInput.staticCall(path, amountIn);
    minOut = (q[0] * BigInt(10000 - SLIPPAGE_BPS)) / 10000n;
    log(`报价：${ethers.formatEther(amountIn)} BNB → ${ethers.formatEther(q[0])} 牛来，minOut(${SLIPPAGE_BPS}bps)=${ethers.formatEther(minOut)}`);
  } catch (e) {
    log('报价失败，跳过本轮：', e.shortMessage || e.message); return;
  }
  const tx = await vault.harvest(minOut, overrides());
  log(`harvest tx ${tx.hash}`);
  const rc = await tx.wait();
  log(`  ✔ block ${rc.blockNumber} gas ${rc.gasUsed}`);
  await distributeAll();
  log('本轮完成 ✅');
}

async function main() {
  log(`keeper ${wallet.address} → vault ${VAULT}`);
  do {
    try { await tick(); } catch (e) {
      const msg = e.shortMessage || e.message || '';
      log('错误：', msg);
      // 同一钱包在别处发过交易会让缓存的 nonce 过期 → 重置后立刻重试一次
      if (/nonce|replacement|already known|underpriced/i.test(msg)) { signer.reset(); log('nonce 已重置，立即重试'); try { await tick(); } catch (e2) { log('重试仍失败：', e2.shortMessage || e2.message); } }
    }
    if (!ONCE) await new Promise(r => setTimeout(r, POLL_SEC * 1000));
  } while (!ONCE);
}
main();
