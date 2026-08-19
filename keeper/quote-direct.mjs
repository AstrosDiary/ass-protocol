// SDK-free quote module: enumerates candidate Pancake V3 routes from QQQB
// (direct, via-USDT, via-WBNB, and 3-hop via WBNB+USDT — all fee tiers),
// quotes each on QuoterV2, picks the best, and emits SmartRouter
// multicall(exactInput) calldata with recipient=EXEC.
import { createPublicClient, http, parseAbi, encodePacked, encodeFunctionData, formatEther } from 'viem'
import { bsc } from 'viem/chains'

const env = (k) => { const v = process.env[k]; if (!v) { console.error(`env ${k} missing — run: set -a; source ../.env; set +a`); process.exit(1) } return v }
const RPC = env('BSC_RPC_URL'), ENGINE = env('ENGINE'), EXEC = env('EXEC'), WBNB = env('WBNB')
const QQQB = process.env.QQQB ?? '0x205812CdBed920aFf76C6580abD681a46D11efc7' // quote token (swap input)

const QUOTER = '0xB048Bbc1Ee6b733FFfCFb9e9CeF7375518e25997'
const USDT   = '0x55d398326f99059fF775485246999027B3197955' // BSC-USD
const FEES   = [100, 500, 2500, 10000]
const SLIPPAGE_BPS = 100n // 1%

const STOCKS = {
  BABAB: '0x4eF9d3062c7F6ebA4AAE4990c5036598C6eff4ec',
  TSMB:  '0xAB78b89B5bb00236Be0B4B20704cBfa04EfC711c',
  SKHYB: '0xCA750eF65f295BBECd685Abf54e82CAf297BDB61',
}

const args = process.argv.slice(2).filter(a => !a.startsWith('--'))
const [sym, spendArg] = args

if (!STOCKS[sym]) { console.error('usage: node quote-direct.mjs <BABAB|TSMB|SKHYB> [spendWei]'); process.exit(1) }
const TOKEN = STOCKS[sym]

const client = createPublicClient({ chain: bsc, transport: http(RPC) })
const quoterAbi = parseAbi([
  'function factory() view returns (address)',
  'function quoteExactInput(bytes path, uint256 amountIn) returns (uint256 amountOut, uint160[] sqrtPriceX96AfterList, uint32[] initializedTicksCrossedList, uint256 gasEstimate)',
])
const factoryAbi = parseAbi(['function getPool(address,address,uint24) view returns (address)'])
const engineAbi = parseAbi(['function budget(address) view returns (uint256)'])

const FACTORY = await client.readContract({ address: QUOTER, abi: quoterAbi, functionName: 'factory' })
const budget = await client.readContract({ address: ENGINE, abi: engineAbi, functionName: 'budget', args: [TOKEN] })
const spend = spendArg ? BigInt(spendArg) : budget
if (spend === 0n || spend > budget) { console.error(`bad spend: spend=${spend} budget=${budget}`); process.exit(1) }
console.error(`[${sym}] budget=${formatEther(budget)} QQQB, quoting spend=${formatEther(spend)}`)

// prefetch fee-tier existence per pair (24 getPool calls instead of ~100 inline)
const tiers = async (a, b) => {
  const out = []
  for (const f of FEES) {
    const p = await client.readContract({ address: FACTORY, abi: factoryAbi, functionName: 'getPool', args: [a, b, f] })
    if (p !== '0x0000000000000000000000000000000000000000') out.push(f)
  }
  return out
}
const [qT, qU, uT, qW, wT, wU] = await Promise.all([
  tiers(QQQB, TOKEN), tiers(QQQB, USDT), tiers(USDT, TOKEN),
  tiers(QQQB, WBNB), tiers(WBNB, TOKEN), tiers(WBNB, USDT),
])

// build candidate paths (packed: token(20) fee(3) token(20) [fee(3) token(20) ...])
const candidates = []
for (const f of qT) candidates.push({
  label: `QQQB -${f}-> ${sym}`,
  path: encodePacked(['address', 'uint24', 'address'], [QQQB, f, TOKEN]),
})
for (const f1 of qU) for (const f2 of uT) candidates.push({
  label: `QQQB -${f1}-> USDT -${f2}-> ${sym}`,
  path: encodePacked(['address', 'uint24', 'address', 'uint24', 'address'], [QQQB, f1, USDT, f2, TOKEN]),
})
for (const f1 of qW) for (const f2 of wT) candidates.push({
  label: `QQQB -${f1}-> WBNB -${f2}-> ${sym}`,
  path: encodePacked(['address', 'uint24', 'address', 'uint24', 'address'], [QQQB, f1, WBNB, f2, TOKEN]),
})
for (const f1 of qW) for (const f2 of wU) for (const f3 of uT) candidates.push({
  label: `QQQB -${f1}-> WBNB -${f2}-> USDT -${f3}-> ${sym}`,
  path: encodePacked(['address', 'uint24', 'address', 'uint24', 'address', 'uint24', 'address'],
    [QQQB, f1, WBNB, f2, USDT, f3, TOKEN]),
})
if (candidates.length === 0) { console.error(`[${sym}] NO POOLS FOUND — carry forward`); process.exit(2) }
console.error(`[${sym}] ${candidates.length} candidate route(s)`)

// quote each (QuoterV2 quote fns are nonpayable-by-design; simulate = eth_call)
let best = null
for (const c of candidates) {
  try {
    const { result } = await client.simulateContract({
      address: QUOTER, abi: quoterAbi, functionName: 'quoteExactInput', args: [c.path, spend],
    })
    const out = result[0]
    console.error(`  ${c.label}: out=${out}`)
    if (!best || out > best.out) best = { ...c, out }
  } catch { console.error(`  ${c.label}: no quote (empty/one-sided pool)`) }
}
if (!best || best.out === 0n) { console.error(`[${sym}] NO EXECUTABLE ROUTE — carry forward`); process.exit(2) }

const minOut = (best.out * (10000n - SLIPPAGE_BPS)) / 10000n
const deadline = BigInt(Math.floor(Date.now() / 1000) + 300)

// SmartRouter (SwapRouter02-style): exactInput has no deadline param; wrap in multicall(deadline, [...])
const routerAbi = parseAbi([
  'function exactInput((bytes path, address recipient, uint256 amountIn, uint256 amountOutMinimum)) payable returns (uint256)',
  'function multicall(uint256 deadline, bytes[] data) payable returns (bytes[])',
])
const inner = encodeFunctionData({ abi: routerAbi, functionName: 'exactInput',
  args: [{ path: best.path, recipient: EXEC, amountIn: spend, amountOutMinimum: minOut }] })
const calldata = encodeFunctionData({ abi: routerAbi, functionName: 'multicall', args: [deadline, [inner]] })

console.error(`[${sym}] BEST: ${best.label} | out=${best.out} minOut=${minOut}`)
console.log(`\n# executeBuy params ready (deadline ${deadline}, ~5 min)`)

if (process.argv.includes('--execute')) {
  const { execFileSync } = await import('node:child_process')
  const { existsSync } = await import('node:fs')
  const pwArgs = existsSync(process.env.HOME + '/.ass_pw')
    ? ['--password-file', process.env.HOME + '/.ass_pw'] : []
  console.error(`[${sym}] EXECUTING via cast (prompts only if no pw file)...`)
  const out2 = execFileSync('cast', [
    'send', ENGINE,
    'executeBuy(address,address,bytes,uint256,uint256,uint256)',
    TOKEN, process.env.SMART_ROUTER, calldata,
    spend.toString(), minOut.toString(), deadline.toString(),
    '--gas-limit', '1500000',
    '--rpc-url', RPC, '--account', 'ass-deployer', ...pwArgs,
  ], { stdio: ['inherit', 'pipe', 'inherit'] }).toString()
  console.log(out2)
  const m = out2.match(/status\s+1|status\s+"?success/i)
  console.error(m ? `[${sym}] tx mined OK — check BuyFailed vs Bought in logs` : `[${sym}] WARNING: could not confirm status — inspect output above`)
} else {
  console.log(`cast send $ENGINE "executeBuy(address,address,bytes,uint256,uint256,uint256)" \\`)
  console.log(`  ${TOKEN} $SMART_ROUTER \\`)
  console.log(`  ${calldata} \\`)
  console.log(`  ${spend} ${minOut} ${deadline} \\`)
  console.log(`  --gas-limit 1500000 \\`)
  console.log(`  --rpc-url $BSC_RPC_URL --account ass-deployer`)
}