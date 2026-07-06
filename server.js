#!/usr/bin/env node
'use strict';

/*
 * Pulse — a local, zero-dependency Claude Code usage dashboard.
 *
 * Reads the newline-delimited JSON session logs Claude Code writes under
 * ~/.claude/projects, aggregates them, and serves a self-refreshing
 * dashboard on http://localhost:4747.
 *
 * HARD RULE: this tool only ever READS from ~/.claude. It never writes,
 * moves, or deletes anything under that tree.
 *
 * Node >= 18 built-ins only. No dependencies, no network calls, no telemetry.
 */

const fs = require('fs');
const http = require('http');
const path = require('path');
const os = require('os');
const url = require('url');

// ---------------------------------------------------------------------------
// §5  COST MODEL  — the first of two areas that must be exactly right.
//
// Prices are Anthropic API list prices in US dollars per MILLION tokens.
// On a Pro/Max subscription these are NOT a bill — they express relative
// usage. This is stated in the UI.
//
// Verified against Anthropic list pricing (docs.claude.com) — 2026-07.
// This object is the single source of truth: updating a price is a one-line
// edit here.
// ---------------------------------------------------------------------------
const PRICING = {
  // model string : { input, output }  in $/MTok
  //
  // Current generation
  'claude-fable-5':    { input: 10, output: 50 },
  'claude-opus-4-8':   { input: 5,  output: 25 },
  'claude-opus-4-7':   { input: 5,  output: 25 },
  'claude-opus-4-6':   { input: 5,  output: 25 },
  'claude-opus-4-5':   { input: 5,  output: 25 },
  // Sonnet 5 carries an introductory price valid through 2026-08-31; after
  // that it reverts to standard. This is applied per-entry, keyed on the
  // entry's OWN date (see priceFor), never on "now".
  'claude-sonnet-5':   { input: 3,  output: 15, introInput: 2, introOutput: 10, introUntil: '2026-08-31' },
  'claude-sonnet-4-6': { input: 3,  output: 15 },
  'claude-sonnet-4-5': { input: 3,  output: 15 },
  'claude-haiku-4-5':  { input: 1,  output: 5 },

  // Older strings that still appear in real history
  'claude-opus-4-1':   { input: 15, output: 75 },
  'claude-opus-4-0':   { input: 15, output: 75 },
  'claude-sonnet-4-0': { input: 3,  output: 15 },
  'claude-3-7-sonnet': { input: 3,  output: 15 },
  'claude-3-5-sonnet': { input: 3,  output: 15 },
  'claude-3-5-haiku':  { input: 0.8, output: 4 },
  'claude-3-opus':     { input: 15, output: 75 },
  'claude-3-haiku':    { input: 0.25, output: 1.25 },

  // Fallback for unknown / new model strings. The string is logged once so it
  // can be added to this map.
  '__default__':       { input: 3, output: 15 },
};

// Cache-token multipliers, applied against the model's INPUT price.
const CACHE_WRITE_5M_MULT = 1.25; // 5-minute TTL cache write
const CACHE_WRITE_1H_MULT = 2.00; // 1-hour TTL cache write
const CACHE_READ_MULT     = 0.10; // cache read

const WEB_SEARCH_PER_1K = 10; // $ per 1000 web_search requests

const HOUR_MS  = 3600 * 1000;
const BLOCK_MS = 5 * HOUR_MS; // rolling 5-hour usage window
const MINUTE_MS = 60 * 1000;

const _unknownModels = new Set();
function logUnknownModel(model) {
  if (model && !_unknownModels.has(model)) {
    _unknownModels.add(model);
    console.warn(`[pulse] unknown model "${model}" — using __default__ pricing. Add it to PRICING.`);
  }
}

// Local-time YYYY-MM-DD for an epoch-ms timestamp (used for the Sonnet-5
// intro-price date check and for day bucketing).
function localDateStr(ts) {
  const d = new Date(ts);
  const y = d.getFullYear();
  const m = String(d.getMonth() + 1).padStart(2, '0');
  const day = String(d.getDate()).padStart(2, '0');
  return `${y}-${m}-${day}`;
}

// Resolve the {input, output} price for a model at a given entry timestamp,
// honouring any time-limited introductory price.
function priceFor(model, ts) {
  let p = PRICING[model];
  if (!p) {
    logUnknownModel(model);
    p = PRICING.__default__;
  }
  if (p.introUntil && localDateStr(ts) <= p.introUntil) {
    return { input: p.introInput, output: p.introOutput };
  }
  return { input: p.input, output: p.output };
}

// §5 per-entry cost. Cache-creation tokens without a TTL breakdown are treated
// as 5-minute writes (×1.25) — documented assumption, handled at normalize().
function costForEntry(e) {
  const price = priceFor(e.model, e.ts);
  return (
    (e.inputTokens  / 1e6) * price.input +
    (e.outputTokens / 1e6) * price.output +
    (e.cacheWrite5m / 1e6) * price.input * CACHE_WRITE_5M_MULT +
    (e.cacheWrite1h / 1e6) * price.input * CACHE_WRITE_1H_MULT +
    (e.cacheRead    / 1e6) * price.input * CACHE_READ_MULT +
    (e.webSearches  / 1000) * WEB_SEARCH_PER_1K
  );
}

// ---------------------------------------------------------------------------
// PATHS & FILE DISCOVERY
// ---------------------------------------------------------------------------

// Resolve ~/.claude, honouring the CLAUDE_DIR override for non-standard installs.
function claudeDir() {
  return process.env.CLAUDE_DIR || path.join(os.homedir(), '.claude');
}

// Hand-rolled recursive walker for *.jsonl files. We deliberately avoid
// fs.readdir(..., {recursive:true}) because its availability varies across the
// Node 18.x line. READ-ONLY: only readdirSync + statSync, never a write op.
function walkJsonl(dir, out) {
  let entries;
  try {
    entries = fs.readdirSync(dir, { withFileTypes: true });
  } catch (_) {
    return out; // missing / unreadable dir — skip silently
  }
  for (const ent of entries) {
    const full = path.join(dir, ent.name);
    let isDir = ent.isDirectory();
    let isFile = ent.isFile();
    // Resolve symlinks defensively (still read-only).
    if (ent.isSymbolicLink()) {
      try {
        const st = fs.statSync(full);
        isDir = st.isDirectory();
        isFile = st.isFile();
      } catch (_) { continue; }
    }
    if (isDir) {
      walkJsonl(full, out);
    } else if (isFile && ent.name.endsWith('.jsonl')) {
      out.push(full);
    }
  }
  return out;
}

function projectsRoot() {
  return path.join(claudeDir(), 'projects');
}

// ---------------------------------------------------------------------------
// §3  RECORD ACCESSORS — read field names via small helpers with fallbacks.
// Field names have drifted across Claude Code versions; never assume a key
// exists. (Phase 0 confirmed the shapes on the target machine.)
// ---------------------------------------------------------------------------

function num(v) { return typeof v === 'number' && isFinite(v) ? v : 0; }

// Stable dedup key identifying a unique assistant message.
//
// The brief describes a composite `message.id + ":" + requestId`. In practice
// message.id is a globally-unique per-message id that is CONSISTENT across the
// duplicate lines the log writes as a message streams — so we key on it alone
// when present. Folding requestId into the key would SPLIT a message whose
// requestId is present on some copies but absent on others (a real log quirk),
// double-counting its usage; message.id alone dedups those copies correctly.
// We fall back to requestId, then uuid, then a timestamp+model+token-count
// composite so two genuinely-distinct messages at the same instant are not
// collapsed while true duplicate writes (identical counts) still dedup.
function dedupKey(rec) {
  const msg = rec.message || {};
  if (msg.id) return 'm:' + msg.id;
  if (rec.requestId) return 'r:' + rec.requestId;
  if (rec.uuid) return 'u:' + rec.uuid;
  const u = msg.usage || {};
  return 't:' + (rec.timestamp || '') + ':' + (msg.model || '') + ':' +
    num(u.input_tokens) + ':' + num(u.output_tokens);
}

// Extract the plain-text of a user record's content (string, or an array of
// blocks with {type:'text', text}). Used only for the title fallback.
function userText(rec) {
  const c = rec.message && rec.message.content;
  if (typeof c === 'string') return c;
  if (Array.isArray(c)) {
    for (const block of c) {
      if (block && block.type === 'text' && typeof block.text === 'string') return block.text;
      if (typeof block === 'string') return block;
    }
  }
  return '';
}

// Turn one assistant-with-usage record into a normalized Entry, or null if the
// record carries no usage.
function normalize(rec) {
  const msg = rec.message;
  if (!msg || !msg.usage) return null; // skip non-usage records for cost
  const u = msg.usage;

  const ts = Date.parse(rec.timestamp);
  if (!isFinite(ts)) return null;

  // Cache-creation TTL breakdown (§5). If the breakdown object is present, use
  // it and DO NOT also add the lump `cache_creation_input_tokens` (it is the
  // sum of the two). If absent, treat the whole lump as a 5-minute write.
  let cacheWrite5m, cacheWrite1h;
  const cc = u.cache_creation;
  if (cc && (typeof cc.ephemeral_5m_input_tokens === 'number' ||
             typeof cc.ephemeral_1h_input_tokens === 'number')) {
    cacheWrite5m = num(cc.ephemeral_5m_input_tokens);
    cacheWrite1h = num(cc.ephemeral_1h_input_tokens);
  } else {
    cacheWrite5m = num(u.cache_creation_input_tokens);
    cacheWrite1h = 0;
  }

  const stu = u.server_tool_use || {};

  const e = {
    ts,
    model: msg.model || 'unknown',
    source: rec.entrypoint || 'cli', // §3.4 — default cli when absent
    inputTokens: num(u.input_tokens),
    outputTokens: num(u.output_tokens),
    cacheWrite5m,
    cacheWrite1h,
    cacheRead: num(u.cache_read_input_tokens),
    webSearches: num(stu.web_search_requests),
    sessionId: rec.sessionId || '',
    project: rec.cwd || '',
    messageId: (msg.id) || '',
    requestId: rec.requestId || '',
    key: dedupKey(rec),
  };
  e.cost = costForEntry(e);
  return e;
}

// ---------------------------------------------------------------------------
// PARSE + mtime CACHE
//
// In-memory cache keyed by filepath: { mtimeMs, entries, sessionMeta }.
// Parsing is the expensive part and is skipped entirely for files whose mtime
// is unchanged; the arithmetic rollup is cheap and redone every request.
// ---------------------------------------------------------------------------

const fileCache = new Map();

// Parse a single .jsonl file into normalized entries + per-session metadata,
// with per-file dedup applied. Malformed lines (incl. a partial trailing write
// on a live session) are caught and skipped — this is normal, not an error.
function parseFile(filePath) {
  let raw;
  try {
    raw = fs.readFileSync(filePath, 'utf8');
  } catch (_) {
    return { entries: [], sessionMeta: {} };
  }
  const lines = raw.split('\n');
  const entries = [];
  const seen = new Set();       // per-file dedup
  const sessionMeta = {};       // sessionId -> { firstUserText, project }

  for (const line of lines) {
    if (!line) continue;
    let rec;
    try {
      rec = JSON.parse(line);
    } catch (_) {
      continue; // partial/truncated line — skip
    }
    if (!rec || typeof rec !== 'object') continue;

    // Capture first user prompt per session for the title fallback.
    if (rec.type === 'user') {
      const sid = rec.sessionId || '';
      if (sid && !sessionMeta[sid]) {
        sessionMeta[sid] = {
          firstUserText: userText(rec).trim(),
          project: rec.cwd || '',
        };
      }
      continue;
    }

    if (rec.type !== 'assistant') continue;
    const e = normalize(rec);
    if (!e) continue;
    if (seen.has(e.key)) continue; // per-file dedup
    seen.add(e.key);
    entries.push(e);

    // Record project path for sessions even if no user record was seen.
    if (e.sessionId && !sessionMeta[e.sessionId]) {
      sessionMeta[e.sessionId] = { firstUserText: '', project: e.project };
    } else if (e.sessionId && sessionMeta[e.sessionId] && !sessionMeta[e.sessionId].project) {
      sessionMeta[e.sessionId].project = e.project;
    }
  }
  return { entries, sessionMeta };
}

// Walk all files; reuse cached parse when mtime is unchanged. Returns the merged
// (globally deduped) entry list plus a merged sessionId->meta map. Logs a
// one-line "parsed X, skipped Y (cached)" so the mtime cache is observable.
function parseAll() {
  const files = walkJsonl(projectsRoot(), []);
  const liveFiles = new Set(files);

  let parsed = 0, skipped = 0;
  for (const f of files) {
    let st;
    try { st = fs.statSync(f); } catch (_) { continue; }
    const cached = fileCache.get(f);
    if (cached && cached.mtimeMs === st.mtimeMs) {
      skipped++;
      continue;
    }
    const { entries, sessionMeta } = parseFile(f);
    fileCache.set(f, { mtimeMs: st.mtimeMs, entries, sessionMeta });
    parsed++;
  }
  // Drop cache entries for files that have disappeared.
  for (const key of fileCache.keys()) {
    if (!liveFiles.has(key)) fileCache.delete(key);
  }

  // Merge all cached files → global dedup.
  const merged = [];
  const globalSeen = new Set();
  const sessionMeta = {};
  for (const { entries, sessionMeta: sm } of fileCache.values()) {
    for (const e of entries) {
      if (globalSeen.has(e.key)) continue;
      globalSeen.add(e.key);
      merged.push(e);
    }
    for (const sid of Object.keys(sm)) {
      const cur = sessionMeta[sid];
      const inc = sm[sid];
      if (!cur) {
        sessionMeta[sid] = { firstUserText: inc.firstUserText || '', project: inc.project || '' };
      } else {
        if (!cur.firstUserText && inc.firstUserText) cur.firstUserText = inc.firstUserText;
        if (!cur.project && inc.project) cur.project = inc.project;
      }
    }
  }

  console.log(`[pulse] parsed ${parsed} file(s), skipped ${skipped} (cached); ${merged.length} unique usage records`);
  return { entries: merged, sessionMeta };
}

// ---------------------------------------------------------------------------
// §4.1  5-HOUR BLOCKS — the second area that must be exactly right.
// Implemented precisely as the usage monitor does.
// ---------------------------------------------------------------------------

function floorToHour(ts) {
  const d = new Date(ts);
  d.setMinutes(0, 0, 0); // start of the local hour
  return d.getTime();
}

function computeBlocks(entriesAsc) {
  const blocks = [];
  let current = null;
  let lastTs = null;

  for (const e of entriesAsc) {
    if (current === null) {
      const start = floorToHour(e.ts);
      current = { start, end: start + BLOCK_MS, entries: [e] };
    } else {
      const newBlock = (e.ts - lastTs >= BLOCK_MS) || (e.ts >= current.end);
      if (newBlock) {
        blocks.push(current);
        const start = floorToHour(e.ts);
        current = { start, end: start + BLOCK_MS, entries: [e] };
      } else {
        current.entries.push(e);
      }
    }
    lastTs = e.ts;
  }
  if (current) blocks.push(current);
  return blocks;
}

function summarizeBlock(b) {
  let cost = 0, tokens = 0;
  for (const e of b.entries) {
    cost += e.cost;
    tokens += tokensOf(e);
  }
  return {
    start: b.start,
    end: b.end,
    cost,
    tokens,
    messages: b.entries.length,
  };
}

// Total billable tokens for an entry (input + output + all cache tokens).
function tokensOf(e) {
  return e.inputTokens + e.outputTokens + e.cacheWrite5m + e.cacheWrite1h + e.cacheRead;
}

// ---------------------------------------------------------------------------
// §4  AGGREGATIONS
// ---------------------------------------------------------------------------

function startOfLocalDay(ts) {
  const d = new Date(ts);
  d.setHours(0, 0, 0, 0);
  return d.getTime();
}

function aggregate(entries, sessionMeta, desktopTitles, now) {
  const asc = entries.slice().sort((a, b) => a.ts - b.ts);

  // ---- 5-hour blocks + active block ----
  const rawBlocks = computeBlocks(asc);
  const blocks = rawBlocks.map(summarizeBlock);
  let activeBlock = null;
  for (const b of blocks) {
    if (b.start <= now && now < b.end) { activeBlock = b; break; }
  }
  const timeToReset = activeBlock ? (activeBlock.end - now) : null;

  // "vs your heaviest past block" — % of the max over all OTHER (completed)
  // blocks. Guard against a lone/first block (peak 0 → null).
  let currentBlock = null;
  if (activeBlock) {
    let peakCost = 0, peakTokens = 0;
    for (const b of blocks) {
      if (b === activeBlock) continue;
      if (b.cost > peakCost) peakCost = b.cost;
      if (b.tokens > peakTokens) peakTokens = b.tokens;
    }
    currentBlock = {
      start: activeBlock.start,
      end: activeBlock.end,
      cost: activeBlock.cost,
      tokens: activeBlock.tokens,
      messages: activeBlock.messages,
      timeToReset,
      vsPeakCostPct: peakCost > 0 ? (activeBlock.cost / peakCost) * 100 : null,
      vsPeakTokensPct: peakTokens > 0 ? (activeBlock.tokens / peakTokens) * 100 : null,
    };
  }

  // ---- §4.2 burn rate (trailing 60 minutes) ----
  const windowStart = now - 60 * MINUTE_MS;
  let brTokens = 0, brCost = 0, earliest = null;
  for (const e of asc) {
    if (e.ts >= windowStart && e.ts <= now) {
      brTokens += tokensOf(e);
      brCost += e.cost;
      if (earliest === null) earliest = e.ts; // asc → first is earliest
    }
  }
  let burnRate = null;
  if (earliest !== null) {
    const spanMin = (now - earliest) / MINUTE_MS;
    // min(60, span) with a 1-minute floor so early-session data isn't a
    // divide-by-near-zero blowup.
    const elapsedMin = Math.max(1, Math.min(60, spanMin));
    burnRate = {
      tokensPerMin: brTokens / elapsedMin,
      dollarsPerHour: brCost / (elapsedMin / 60),
      windowTokens: brTokens,
      windowCost: brCost,
      elapsedMin,
    };
  }

  // ---- rollups ----
  const midnight = startOfLocalDay(now);
  const sevenDaysAgo = now - 7 * 24 * HOUR_MS;

  const today = { cost: 0, tokens: 0, messages: 0 };
  const week  = { cost: 0, tokens: 0, messages: 0 };
  for (const e of asc) {
    const tk = tokensOf(e);
    if (e.ts >= midnight) { today.cost += e.cost; today.tokens += tk; today.messages++; }
    if (e.ts >= sevenDaysAgo) { week.cost += e.cost; week.tokens += tk; week.messages++; }
  }

  // ---- distinct sources (drives CLI-only / single-source degradation) ----
  const sourceSet = new Set();
  for (const e of asc) sourceSet.add(e.source);
  const sources = Array.from(sourceSet).sort();
  const singleSource = sources.length <= 1;

  // ---- §4.3 daily spend, 30 days, split by source ----
  // Bucket window: the 30 local calendar days ending today. We walk calendar
  // days with setDate (DST-safe) rather than adding 24h in epoch ms, which
  // would collide/gap a day around a DST transition.
  const dayIndex = {}; // dateStr -> bucket
  const daily = [];
  const cursor = new Date(now);
  cursor.setHours(0, 0, 0, 0);
  cursor.setDate(cursor.getDate() - 29); // start 29 days back → 30 days incl. today
  const firstDayStart = cursor.getTime();
  for (let i = 0; i < 30; i++) {
    const ds = localDateStr(cursor.getTime());
    const bucket = { date: ds, total: 0, tokens: 0, bySource: {} };
    for (const s of sources) bucket.bySource[s] = 0;
    dayIndex[ds] = bucket;
    daily.push(bucket);
    cursor.setDate(cursor.getDate() + 1); // advance one calendar day (DST-safe)
  }
  let thirtyDayTotal = 0, thirtyDayTokens = 0;
  for (const e of asc) {
    if (e.ts < firstDayStart) continue;
    const ds = localDateStr(e.ts);
    const bucket = dayIndex[ds];
    if (!bucket) continue; // guard (e.g. future-dated / edge)
    bucket.total += e.cost;
    bucket.tokens += tokensOf(e);
    bucket.bySource[e.source] = (bucket.bySource[e.source] || 0) + e.cost;
    thirtyDayTotal += e.cost;
    thirtyDayTokens += tokensOf(e);
  }

  // ---- by model ----
  const byModel = {};
  for (const e of asc) {
    const m = byModel[e.model] || (byModel[e.model] = { cost: 0, tokens: 0, messages: 0 });
    m.cost += e.cost; m.tokens += tokensOf(e); m.messages++;
  }

  // ---- by source ----
  const bySource = {};
  for (const e of asc) {
    const s = bySource[e.source] || (bySource[e.source] = { cost: 0, tokens: 0, messages: 0 });
    s.cost += e.cost; s.tokens += tokensOf(e); s.messages++;
  }

  // ---- recent sessions (newest first) ----
  const sessMap = {};
  for (const e of asc) {
    const sid = e.sessionId || '(unknown)';
    let s = sessMap[sid];
    if (!s) {
      s = sessMap[sid] = {
        sessionId: sid, cost: 0, tokens: 0, messages: 0,
        models: new Set(), sources: new Set(), lastTs: 0, firstTs: e.ts,
      };
    }
    s.cost += e.cost; s.tokens += tokensOf(e); s.messages++;
    s.models.add(e.model); s.sources.add(e.source);
    if (e.ts > s.lastTs) s.lastTs = e.ts;
  }
  const recentSessions = Object.values(sessMap)
    .sort((a, b) => b.lastTs - a.lastTs)
    .slice(0, 20)
    .map((s) => ({
      sessionId: s.sessionId,
      title: sessionTitle(s.sessionId, sessionMeta, desktopTitles),
      source: s.sources.size === 1 ? Array.from(s.sources)[0] : 'mixed',
      models: Array.from(s.models),
      cost: s.cost,
      tokens: s.tokens,
      messages: s.messages,
      lastTs: s.lastTs,
    }));

  const payload = {
    generatedAt: now,
    totals: {
      cost: entries.reduce((a, e) => a + e.cost, 0),
      tokens: entries.reduce((a, e) => a + tokensOf(e), 0),
      messages: entries.length,
      sessions: Object.keys(sessMap).length,
    },
    currentBlock,
    idle: activeBlock === null,
    burnRate,
    today,
    week,
    daily,
    thirtyDay: { total: thirtyDayTotal, tokens: thirtyDayTokens },
    byModel,
    bySource,
    sources,
    singleSource,
    recentSessions,
    pricing: buildPricingView(now),
    hasData: entries.length > 0,
  };

  payload.selfCheck = selfCheck(payload, asc, rawBlocks);
  return payload;
}

// A compact view of the active price table, for the UI "estimates" note.
function buildPricingView(now) {
  const out = {};
  for (const model of Object.keys(PRICING)) {
    if (model === '__default__') continue;
    const p = priceFor(model, now);
    out[model] = { input: p.input, output: p.output };
  }
  return out;
}

// Resolve a human-readable session title, degrading gracefully:
//   desktop store title  ->  derived "<project> · <first prompt> · <short id>"
function sessionTitle(sessionId, sessionMeta, desktopTitles) {
  if (desktopTitles && desktopTitles[sessionId]) return desktopTitles[sessionId];
  const meta = sessionMeta[sessionId] || {};
  const proj = meta.project ? path.basename(meta.project) : '';
  let prompt = (meta.firstUserText || '').replace(/\s+/g, ' ').trim();
  if (prompt.length > 60) prompt = prompt.slice(0, 57) + '…';
  const shortId = sessionId ? sessionId.slice(0, 8) : '';
  const parts = [];
  if (proj) parts.push(proj);
  if (prompt) parts.push(prompt);
  if (shortId) parts.push(shortId);
  return parts.length ? parts.join(' · ') : (sessionId || 'session');
}

// §4 internal-consistency invariants. Logs warnings; returns a summary the UI
// can surface. Never throws.
function selfCheck(payload, asc, rawBlocks) {
  const issues = [];
  const EPS = 1e-6;

  // sum of daily buckets == 30-day total
  const dailySum = payload.daily.reduce((a, b) => a + b.total, 0);
  if (Math.abs(dailySum - payload.thirtyDay.total) > 1e-4) {
    issues.push(`daily buckets sum ${dailySum.toFixed(6)} != 30-day total ${payload.thirtyDay.total.toFixed(6)}`);
  }

  // today ⊆ 7-day (cost & messages)
  if (payload.today.cost - payload.week.cost > EPS || payload.today.messages > payload.week.messages) {
    issues.push('today is not a subset of the 7-day window');
  }

  // every block's entries ⊆ all entries (count match)
  const blockEntryCount = rawBlocks.reduce((a, b) => a + b.entries.length, 0);
  if (blockEntryCount !== asc.length) {
    issues.push(`block entries (${blockEntryCount}) != all entries (${asc.length})`);
  }

  // no duplicate dedup keys remain
  const keys = new Set();
  let dups = 0;
  for (const e of asc) { if (keys.has(e.key)) dups++; else keys.add(e.key); }
  if (dups > 0) issues.push(`${dups} duplicate dedup key(s) survived`);

  if (issues.length) {
    for (const i of issues) console.warn('[pulse] self-check: ' + i);
  }
  return { ok: issues.length === 0, issues };
}

// ---------------------------------------------------------------------------
// §3.5  SESSION TITLES from the desktop store (cross-platform, optional).
// Attempt to read sessionId->title. Absent store or unrecognized format => {}.
// Purely additive; never blocks or throws.
// ---------------------------------------------------------------------------

function desktopStoreDir() {
  const home = os.homedir();
  if (process.platform === 'win32') {
    const appData = process.env.APPDATA || path.join(home, 'AppData', 'Roaming');
    return path.join(appData, 'Claude', 'claude-code-sessions');
  }
  if (process.platform === 'darwin') {
    return path.join(home, 'Library', 'Application Support', 'Claude', 'claude-code-sessions');
  }
  return path.join(home, '.config', 'Claude', 'claude-code-sessions');
}

// Best-effort extraction of a sessionId->title map from an unknown-format store.
// We look for JSON files and pull common title-ish keys. READ-ONLY.
function readDesktopTitles() {
  const dir = desktopStoreDir();
  const map = {};
  let files;
  try {
    files = fs.readdirSync(dir, { withFileTypes: true });
  } catch (_) {
    return map; // no store (headless server) — expected
  }
  for (const ent of files) {
    if (!ent.isFile()) continue;
    const full = path.join(dir, ent.name);
    let text;
    try { text = fs.readFileSync(full, 'utf8'); } catch (_) { continue; }

    // Try whole-file JSON first, then line-delimited JSON.
    const candidates = [];
    try { candidates.push(JSON.parse(text)); }
    catch (_) {
      for (const line of text.split('\n')) {
        if (!line.trim()) continue;
        try { candidates.push(JSON.parse(line)); } catch (_) {}
      }
    }
    for (const obj of candidates) collectTitles(obj, ent.name, map);
  }
  return map;
}

// Pull {sessionId -> title} out of an arbitrary parsed object. Handles a map
// keyed by session id, an array of records, or a single record.
function collectTitles(obj, fileName, map) {
  if (!obj || typeof obj !== 'object') return;

  const titleOf = (r) => (r && typeof r === 'object')
    ? (r.title || r.name || r.summary || r.displayName || null) : null;
  const idOf = (r, fallbackKey) => (r && typeof r === 'object')
    ? (r.sessionId || r.session_id || r.id || r.uuid || fallbackKey) : fallbackKey;

  if (Array.isArray(obj)) {
    for (const r of obj) {
      const id = idOf(r, null);
      const t = titleOf(r);
      if (id && t) map[id] = String(t);
    }
    return;
  }

  // A single record that looks like a session?
  const directTitle = titleOf(obj);
  const directId = obj.sessionId || obj.session_id || obj.id || obj.uuid ||
    (fileName.endsWith('.json') ? fileName.slice(0, -5) : null);
  if (directTitle && directId) {
    map[directId] = String(directTitle);
  }

  // Or a map keyed by session id -> record/string.
  for (const k of Object.keys(obj)) {
    const v = obj[k];
    if (typeof v === 'string') {
      // heuristically only treat as title if key looks like a session id
      if (/^[0-9a-f-]{8,}$/i.test(k)) map[k] = v;
    } else if (v && typeof v === 'object') {
      const t = titleOf(v);
      if (t) map[k] = String(t);
    }
  }
}

// ---------------------------------------------------------------------------
// HTTP SERVER  (§6)
// ---------------------------------------------------------------------------

function buildSummary() {
  const { entries, sessionMeta } = parseAll();
  const desktopTitles = readDesktopTitles();
  const now = Date.now();
  return aggregate(entries, sessionMeta, desktopTitles, now);
}

function readIndexHtml() {
  return fs.readFileSync(path.join(__dirname, 'index.html'));
}

function startServer(port) {
  const server = http.createServer((req, res) => {
    const parsed = url.parse(req.url);
    const route = parsed.pathname;

    try {
      if (route === '/' || route === '/index.html') {
        res.writeHead(200, { 'Content-Type': 'text/html; charset=utf-8' });
        res.end(readIndexHtml());
        return;
      }
      if (route === '/api/health') {
        res.writeHead(200, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({ ok: true }));
        return;
      }
      if (route === '/api/summary') {
        const t0 = Date.now();
        const payload = buildSummary();
        payload.buildMs = Date.now() - t0;
        res.writeHead(200, { 'Content-Type': 'application/json', 'Cache-Control': 'no-store' });
        res.end(JSON.stringify(payload));
        return;
      }
      res.writeHead(404, { 'Content-Type': 'text/plain' });
      res.end('Not found');
    } catch (err) {
      console.error('[pulse] request error:', err && err.stack ? err.stack : err);
      res.writeHead(500, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify({ error: String(err && err.message || err) }));
    }
  });

  server.on('error', (err) => {
    if (err && err.code === 'EADDRINUSE') {
      console.error(`[pulse] port ${port} is already in use. Try: node server.js --port <other>  (or set PORT=)`);
      process.exit(1);
    }
    throw err;
  });

  // Local-only: bind to loopback (§2).
  server.listen(port, '127.0.0.1', () => {
    console.log(`\n  Pulse — Claude Code usage dashboard`);
    console.log(`  reading (read-only): ${claudeDir()}`);
    console.log(`  open: http://localhost:${port}\n`);
  });
  return server;
}

// ---------------------------------------------------------------------------
// CONFIG + CLI ENTRY
// ---------------------------------------------------------------------------

function parseArgs(argv) {
  const out = { port: null, inspectSchema: false };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a === '--port' || a === '-p') { out.port = parseInt(argv[++i], 10); }
    else if (a.startsWith('--port=')) { out.port = parseInt(a.slice(7), 10); }
    else if (a === '--inspect-schema') { out.inspectSchema = true; }
    else if (a === '--help' || a === '-h') { out.help = true; }
  }
  return out;
}

function resolvePort(args) {
  if (args.port && !isNaN(args.port)) return args.port;
  if (process.env.PORT && !isNaN(parseInt(process.env.PORT, 10))) return parseInt(process.env.PORT, 10);
  return 4747;
}

// Phase 0 helper: print the observed top-level keys and usage keys from a
// handful of real records so accessors can be confirmed against real data.
function inspectSchema() {
  const files = walkJsonl(projectsRoot(), []);
  console.log(`[pulse] --inspect-schema: found ${files.length} .jsonl file(s) under ${projectsRoot()}`);
  const topKeys = {}, msgKeys = {}, usageKeys = {}, entrypoints = {}, models = {};
  let sampled = 0, assistantWithUsage = 0;
  const SAMPLE_FILES = 8, SAMPLE_RECS = 200;

  for (const f of files.slice(0, SAMPLE_FILES)) {
    let raw;
    try { raw = fs.readFileSync(f, 'utf8'); } catch (_) { continue; }
    let n = 0;
    for (const line of raw.split('\n')) {
      if (!line || n >= SAMPLE_RECS) continue;
      n++;
      let rec; try { rec = JSON.parse(line); } catch (_) { continue; }
      sampled++;
      for (const k of Object.keys(rec)) topKeys[k] = (topKeys[k] || 0) + 1;
      if (rec.entrypoint) entrypoints[rec.entrypoint] = (entrypoints[rec.entrypoint] || 0) + 1;
      if (rec.message && typeof rec.message === 'object') {
        for (const k of Object.keys(rec.message)) msgKeys[k] = (msgKeys[k] || 0) + 1;
        if (rec.message.model) models[rec.message.model] = (models[rec.message.model] || 0) + 1;
        if (rec.message.usage) {
          assistantWithUsage++;
          for (const k of Object.keys(rec.message.usage)) usageKeys[k] = (usageKeys[k] || 0) + 1;
        }
      }
    }
  }
  const show = (label, obj) => {
    console.log(`\n${label}:`);
    for (const [k, v] of Object.entries(obj).sort((a, b) => b[1] - a[1])) {
      console.log(`  ${k}  (${v})`);
    }
  };
  console.log(`\nsampled ${sampled} record(s); ${assistantWithUsage} assistant records with usage`);
  show('top-level keys', topKeys);
  show('message.* keys', msgKeys);
  show('message.usage.* keys', usageKeys);
  show('entrypoint values', entrypoints);
  show('models', models);
  console.log('');
}

function main() {
  const args = parseArgs(process.argv.slice(2));
  if (args.help) {
    console.log('Pulse — local Claude Code usage dashboard\n');
    console.log('Usage: node server.js [--port N] [--inspect-schema]');
    console.log('  --port N          listen port (default 4747, or $PORT)');
    console.log('  --inspect-schema  print observed record schema and exit');
    console.log('  env CLAUDE_DIR    override ~/.claude location');
    return;
  }
  if (args.inspectSchema) { inspectSchema(); return; }
  startServer(resolvePort(args));
}

if (require.main === module) main();

// Exported for tests / self-check harnesses.
module.exports = {
  PRICING, priceFor, costForEntry, normalize, dedupKey,
  computeBlocks, floorToHour, aggregate, parseAll, tokensOf, localDateStr,
};
