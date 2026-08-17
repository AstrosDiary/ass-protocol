// $ASS indexer: holders / execution feed / history / per-holder accruals.
// Polls chain via LOGS_RPC (paid), serves HTTP on :8788 with CORS.
import { createPublicClient, http, parseAbiItem } from 'viem'
import { bsc } from 'viem/chains'
import { createServer } from 'node:http'
import { readFileSync, writeFileSync, existsSync } from 'node:fs'

const env = (k) => { const v = process.env[k]; if (!v) { console.error(`env ${k} missing`); process.exit(1) } return v }
const RPC = process.env.LOGS_RPC ?? env('BSC_RPC_URL')
const DIV = env('DIV'), ENGINE = env('ENGINE'), DIST = env('DIST'), TOKEN = env('TOKEN')
const START_BLOCK = BigInt(process.env.INDEXER_START ?? '115694880')
const CHUNK = BigInt(process.env.CHUNK ?? '2000')
const PORT = Number(process.env.INDEXER_PORT ?? 8788)
const STATE = new URL('./indexer-state.json', import.meta.url).pathname
const SHARE_TOPIC = '0x2a9333f5f64b9c9d299faa0d6699b5db8d59d08388fea8ae78ca2303836a10f8'

const client = createPublicClient({ chain: bsc, transport: http(RPC) })
const evBought = parseAbiItem('event Bought(address indexed asset, address indexed router, uint256 wbnbSpent, uint256 received)')
const evProcessed = parseAbiItem('event RevenueProcessed(uint256 bnbWrapped, uint256 allocated, uint256 unallocatedCarry)')
const evPaid = parseAbiItem('event Paid(uint64 indexed id, address indexed asset, address indexed holder, uint256 amount)')

// ---- state (JSON-serialisable: bigints as strings) ----
let S = {
  lastBlock: (START_BLOCK - 1n).toString(),
  shares: {},              // holder -> share (string)
  feed: [],                // [{ts, block, tx, action, asset, wbnbSpent, received}] newest first, cap 500
  history: {},             // dayKey -> cumulative bnb processed (string wei) at end of day
  cumProcessed: '0',
  paid: {},                // holder -> [{ts, block, tx, asset, amount}] newest first, cap 200 each
}
if (existsSync(STATE)) { S = JSON.parse(readFileSync(STATE, 'utf8')); console.log(`resume from ${S.lastBlock}`) }
const save = () => writeFileSync(STATE, JSON.stringify(S))

const blockTs = new Map() // block -> unix ts cache
async function tsOf(bn) {
  if (!blockTs.has(bn)) {
    const b = await client.getBlock({ blockNumber: bn })
    blockTs.set(bn, Number(b.timestamp))
  }
  return blockTs.get(bn)
}
const dayKey = (ts) => new Date(ts * 1000).toISOString().slice(0, 10)

async function getLogsRetry(params) {
  for (let a = 0; ; a++) {
    try { return await client.getLogs(params) }
    catch (e) { if (a >= 4) throw e; await new Promise(r => setTimeout(r, 500 * (a + 1))) }
  }
}

async function ingest() {
  const latest = await client.getBlockNumber()
  let from = BigInt(S.lastBlock) + 1n
  if (from > latest) return
  for (; from <= latest; from += CHUNK) {
    const to = from + CHUNK - 1n > latest ? latest : from + CHUNK - 1n
    // tracker shares (raw logs, positional decode — pinned shape)
    const shareLogs = await getLogsRetry({ address: DIV, fromBlock: from, toBlock: to })
    for (const l of shareLogs) {
      if (l.topics[0] !== SHARE_TOPIC || l.topics.length !== 3) continue
      const user = ('0x' + l.topics[2].slice(26)).toLowerCase()
      S.shares[user] = BigInt('0x' + l.data.slice(2, 66)).toString()
    }
    // engine: buys + revenue
    const bought = await getLogsRetry({ address: ENGINE, event: evBought, fromBlock: from, toBlock: to })
    for (const l of bought) {
      S.feed.unshift({
        ts: await tsOf(l.blockNumber), block: Number(l.blockNumber), tx: l.transactionHash,
        action: 'BUY', asset: l.args.asset.toLowerCase(),
        wbnbSpent: l.args.wbnbSpent.toString(), received: l.args.received.toString(),
      })
    }
    const proc = await getLogsRetry({ address: ENGINE, event: evProcessed, fromBlock: from, toBlock: to })
    for (const l of proc) {
      const cum = BigInt(S.cumProcessed) + l.args.bnbWrapped
      S.cumProcessed = cum.toString()
      S.history[dayKey(await tsOf(l.blockNumber))] = cum.toString()
    }
    // distributor: per-holder accruals
    const paid = await getLogsRetry({ address: DIST, event: evPaid, fromBlock: from, toBlock: to })
    for (const l of paid) {
      const h = l.args.holder.toLowerCase()
      S.paid[h] ??= []
      S.paid[h].unshift({
        ts: await tsOf(l.blockNumber), block: Number(l.blockNumber), tx: l.transactionHash,
        asset: l.args.asset.toLowerCase(), amount: l.args.amount.toString(),
      })
      if (S.paid[h].length > 200) S.paid[h].length = 200
    }
    S.feed.length = Math.min(S.feed.length, 500)
    S.lastBlock = to.toString()
    save()
  }
  S.feed.sort((a, b) => b.block - a.block)
  save()
}

// ---- HTTP (listen FIRST — Loxley lesson: API must be up during backfill) ----
let cache = { t: 0, body: null }
const server = createServer((req, res) => {
  const cors = { 'Access-Control-Allow-Origin': '*', 'Content-Type': 'application/json' }
  const url = new URL(req.url, 'http://x')
  if (url.pathname === '/health') {
    res.writeHead(200, cors); return res.end(JSON.stringify({ ok: true, lastBlock: S.lastBlock }))
  }
  if (url.pathname === '/protocol') {
    if (Date.now() - cache.t > 15_000) {
      const holders = Object.values(S.shares).filter((s) => BigInt(s) > 0n).length
      cache = { t: Date.now(), body: JSON.stringify({
        holders, lastBlock: S.lastBlock, cumProcessed: S.cumProcessed,
        history: Object.entries(S.history).map(([day, cum]) => ({ day, cum })).sort((a, b) => a.day < b.day ? -1 : 1),
      }) }
    }
    res.writeHead(200, cors); return res.end(cache.body)
  }
  if (url.pathname === '/feed') {
    res.writeHead(200, cors); return res.end(JSON.stringify(S.feed.slice(0, 50)))
  }
  const m = url.pathname.match(/^\/holder\/(0x[0-9a-fA-F]{40})$/)
  if (m) {
    const h = m[1].toLowerCase()
    res.writeHead(200, cors)
    return res.end(JSON.stringify({ share: S.shares[h] ?? '0', paid: S.paid[h] ?? [] }))
  }
  res.writeHead(404, cors); res.end('{}')
})
server.listen(PORT, () => console.log(`indexer on :${PORT}`))

// ---- poll loop ----
const tick = () => ingest().catch((e) => console.error('ingest error:', e.shortMessage ?? e.message))
tick()
setInterval(tick, 60_000)