// Act 3 driver: builds the holder set from FlapDividendShareChanged events,
// reconciles vs totalShares(), then runs startCycle -> submitHolders (sorted,
// chunked) -> finalizeSnapshot -> pushPayouts loop until Idle.
import { createPublicClient, http, parseAbi, parseAbiItem } from 'viem'
import { bsc } from 'viem/chains'
import { execFileSync } from 'node:child_process'
import { readFileSync, writeFileSync, existsSync } from 'node:fs'
const STATE_FILE = new URL('./state.json', import.meta.url).pathname

const env = (k) => { const v = process.env[k]; if (!v) { console.error(`env ${k} missing`); process.exit(1) } return v }
const RPC = env('BSC_RPC_URL'), DIST = env('DIST'), DIV = env('DIV'), TOKEN = env('TOKEN')
const START_BLOCK = BigInt(process.env.START_BLOCK ?? '115694900') // token launch block
const CHUNK = BigInt(process.env.CHUNK ?? '500')   // dataseed limit is tight; env-tunable
const LOGS_RPC = process.env.LOGS_RPC ?? RPC        // heavier public node for log scans
const SUBMIT_BATCH = 300     // addresses per submitHolders tx
const PUSH_BATCH = 150       // Loxley cadence

const client = createPublicClient({ chain: bsc, transport: http(LOGS_RPC) })
const distAbi = parseAbi([
  'function phase() view returns (uint8)',
  'function totalSnapShares() view returns (uint256)',
])
const divAbi = parseAbi(['function totalShares() view returns (uint256)'])
// ---- 1. holder candidate set: HOLDERS env override (shares read LIVE), or
// raw-log indexing from the Dividend contract ----
const shares = new Map()
if (process.env.HOLDERS) {
  const userAbi = parseAbi(['function userInfo(address) view returns (uint256,uint256,uint256)'])
  for (const a of process.env.HOLDERS.split(',').map(s => s.trim()).filter(Boolean)) {
    const [share] = await client.readContract({ address: DIV, abi: userAbi, functionName: 'userInfo', args: [a] })
    console.error(`override holder ${a}: live share=${share}`)
    shares.set(a.toLowerCase(), share)
  }
} else {
  let cursor = START_BLOCK
  if (existsSync(STATE_FILE)) {
    const st = JSON.parse(readFileSync(STATE_FILE, 'utf8'))
    cursor = BigInt(st.lastBlock) + 1n
    for (const [a, s] of Object.entries(st.shares)) shares.set(a, BigInt(s))
    console.error(`resuming from cursor ${cursor} with ${shares.size} known holders`)
  }
  const latest = await client.getBlockNumber()
  let shapeReported = false
  console.error(`indexing raw logs ${cursor} -> ${latest} ...`)
  for (let from = cursor; from <= latest; from += CHUNK) {
    const to = from + CHUNK - 1n > latest ? latest : from + CHUNK - 1n
    for (let attempt = 0; ; attempt++) {
      try {
        const logs = await client.getLogs({ address: DIV, fromBlock: from, toBlock: to })
        for (const l of logs) {
          const words = (l.data.length - 2) / 64
          if (!shapeReported && l.topics.length >= 2) {
            console.error(`first log shape: topics=${l.topics.length} dataWords=${words} sig=${l.topics[0]}`)
            shapeReported = true
          }
          if (l.topics.length === 3 && words === 2) {
            shares.set(('0x' + l.topics[2].slice(26)).toLowerCase(), BigInt('0x' + l.data.slice(2, 66)))
          } else if (l.topics.length === 2 && words >= 2) {
            shares.set(('0x' + l.topics[1].slice(26)).toLowerCase(), BigInt('0x' + l.data.slice(2, 66)))
          }
        }
        break
      } catch (e) {
        if (attempt >= 4) { console.error(`getLogs failed hard at ${from}: ${e.shortMessage ?? e}`); process.exit(1) }
        await new Promise(r => setTimeout(r, 500 * (attempt + 1)))
      }
    }
  }
  writeFileSync(STATE_FILE, JSON.stringify({
    lastBlock: latest.toString(),
    shares: Object.fromEntries([...shares].map(([a, s]) => [a, s.toString()])),
  }))
}
const active = [...shares.entries()].filter(([, s]) => s > 0n)
active.sort((a, b) => (BigInt(a[0]) < BigInt(b[0]) ? -1 : 1)) // ascending, contract requirement
const sum = active.reduce((a, [, s]) => a + s, 0n)
const trackerTotal = await client.readContract({ address: DIV, abi: divAbi, functionName: 'totalShares' })
console.error(`active holders: ${active.length}, indexed sum=${sum}, tracker totalShares=${trackerTotal}`)
if (sum !== trackerTotal) console.error(`NOTE: sum != totalShares (in-flight churn or missed events). Coverage check on-chain decides.`)
if (active.length === 0) { console.error('no eligible holders'); process.exit(1) }

// ---- 2. drive the cycle via cast ----
const pwArgs = existsSync(process.env.HOME + '/.ass_pw')
  ? ['--password-file', process.env.HOME + '/.ass_pw'] : []
const send = (sig, ...args) => {
  console.error(`>> cast send ${sig} ${args.join(' ')}`)
  const out = execFileSync('cast', ['send', DIST, sig, ...args, '--gas-limit', '8000000',
    '--rpc-url', RPC, '--account', 'ass-deployer', ...pwArgs], { stdio: ['inherit', 'pipe', 'inherit'] }).toString()
  if (!/status\s+1|success/i.test(out)) { console.error(out); console.error('tx did not succeed — aborting driver'); process.exit(1) }
}
const phase = () => client.readContract({ address: DIST, abi: distAbi, functionName: 'phase' })

if (!process.argv.includes('--execute')) {
  console.log(`dry run only. would submit ${active.length} holders in ${Math.ceil(active.length / SUBMIT_BATCH)} batch(es). re-run with --execute`)
  process.exit(0)
}

if (await phase() !== 0) { console.error(`distributor not Idle (phase=${await phase()}) — resolve first (abortCycle?)`); process.exit(1) }
send('startCycle()')
for (let i = 0; i < active.length; i += SUBMIT_BATCH) {
  const batch = active.slice(i, i + SUBMIT_BATCH).map(([a]) => a)
  send('submitHolders(address[])', `[${batch.join(',')}]`)
}
send('finalizeSnapshot()')
while (await phase() === 2) send('pushPayouts(uint256)', String(PUSH_BATCH))
console.error(`cycle complete — phase=${await phase()} (0=Idle). snapshot shares=${await client.readContract({ address: DIST, abi: distAbi, functionName: 'totalSnapShares' })}`)