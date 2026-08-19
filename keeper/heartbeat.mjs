// One keeper heartbeat: dispatch -> release -> process -> buys -> cycle.
// Every step independently guarded; a failed step logs and the pass continues.
// All revenue amounts denominated in QQQB (quote token) raw units.
import { createPublicClient, http, parseAbi } from 'viem'
import { bsc } from 'viem/chains'
import { execFileSync } from 'node:child_process'
import { existsSync } from 'node:fs'

const env = (k) => { const v = process.env[k]; if (!v) throw new Error(`env ${k} missing`) ; return v }
const RPC = env('BSC_RPC_URL'), VAULT = env('VAULT'), ENGINE = env('ENGINE'), DIST = env('DIST')
const TAXPROC = process.env.TAXPROC ?? '0x34a643c09d086DA1382d8C39b2Aea0EA0EcA9D6F'
const RELEASE_MIN = BigInt(process.env.RELEASE_MIN ?? '20000000000000000') // 0.02 QQQB (~$11)
const BUY_MIN = BigInt(process.env.BUY_MIN ?? '5000000000000000')          // 0.005 QQQB (~$3)
const POT_MIN = BigInt(process.env.POT_MIN ?? '1000000000000')             // 1e12 raw — ignore rounding dust
const STOCKS = { BABAB: '0x4eF9d3062c7F6ebA4AAE4990c5036598C6eff4ec',
                 TSMB:  '0xAB78b89B5bb00236Be0B4B20704cBfa04EfC711c',
                 SKHYB: '0xCA750eF65f295BBECd685Abf54e82CAf297BDB61' }

const client = createPublicClient({ chain: bsc, transport: http(RPC) })
const abi = parseAbi([
  'function pendingQuote() view returns (uint256)',
  'function unallocatedQuote() view returns (uint256)',
  'function minProcessAmount() view returns (uint256)',
  'function budget(address) view returns (uint256)',
  'function reservedForAccrued(address) view returns (uint256)',
  'function balanceOf(address) view returns (uint256)',
  'function phase() view returns (uint8)',
])
const pwArgs = existsSync(process.env.HOME + '/.ass_pw') ? ['--password-file', process.env.HOME + '/.ass_pw'] : []
const log = (m) => console.log(`[${new Date().toISOString()}] ${m}`)
const send = (to, gas, sig, ...a) => execFileSync('cast',
  ['send', to, sig, ...a, '--gas-limit', gas, '--rpc-url', RPC, '--account', 'ass-deployer', ...pwArgs],
  { stdio: ['inherit', 'pipe', 'pipe'] })
const step = (name, fn) => { try { return fn() } catch (e) { log(`${name} FAILED: ${e.message?.split('\n')[0]}`); return null } }

// 1. flush Flap's tax processor (permissionless; reverts harmlessly when empty)
step('dispatch', () => { send(TAXPROC, '800000', 'dispatch()'); log('dispatch ok') })

// 2. release vault revenue when above floor (QQQB units)
const pending = await client.readContract({ address: VAULT, abi, functionName: 'pendingQuote' })
log(`vault pending ${pending} QQQB-wei`)
if (pending >= RELEASE_MIN) step('release', () => { send(VAULT, '300000', 'release()'); log('released') })

// 3. split when engine holds enough unearmarked quote (no wrap step anymore)
const unalloc = await client.readContract({ address: ENGINE, abi, functionName: 'unallocatedQuote' })
const minProc = await client.readContract({ address: ENGINE, abi, functionName: 'minProcessAmount' })
log(`engine unallocated ${unalloc} (floor ${minProc})`)
if (unalloc >= minProc) step('process', () => { send(ENGINE, '600000', 'processRevenue()'); log('processed') })

// 4. buys: any budget above dust threshold gets a quote+execute (child handles carry-forward)
for (const [sym, addr] of Object.entries(STOCKS)) {
  const b = await client.readContract({ address: ENGINE, abi, functionName: 'budget', args: [addr] })
  if (b >= BUY_MIN) step(`buy ${sym}`, () => {
    execFileSync('node', [new URL('./quote-direct.mjs', import.meta.url).pathname, sym, '--execute'],
      { stdio: 'inherit' })
  })
  else log(`budget ${sym} ${b} < ${BUY_MIN}, skip`)
}

// 5. cycle when the distributor holds unreserved stock and is Idle
let potWaiting = false
for (const addr of Object.values(STOCKS)) {
  const bal = await client.readContract({ address: addr, abi, functionName: 'balanceOf', args: [DIST] })
  const res = await client.readContract({ address: DIST, abi, functionName: 'reservedForAccrued', args: [addr] })
  if (bal > res + POT_MIN) { potWaiting = true; break }
}
const phase = await client.readContract({ address: DIST, abi, functionName: 'phase' })
if (potWaiting && phase === 0) step('cycle', () => {
  execFileSync('node', [new URL('./cycle.mjs', import.meta.url).pathname, '--execute'], { stdio: 'inherit' })
})
else log(`cycle skip (potWaiting=${potWaiting}, phase=${phase})`)
log('heartbeat done')