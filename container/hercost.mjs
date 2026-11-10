#!/usr/bin/env node
/**
 * hercost —— 大肥鱼本地计费
 *
 * 从 DSH 会话文件（session.v4.jsonl.zstd，多帧 zstd）里抽取每次调用的 usage，
 * 按 DeepSeek 官方单价和峰谷时段算出「她自己」的真实花费。
 * 与账户余额无关 → 工作号怎么花都不会算到她头上。
 *
 * 用法：
 *   node hercost.mjs                # 今天的花费（元），只打印数字
 *   node hercost.mjs --json         # JSON 详情
 *   node hercost.mjs --days 3       # 最近 3 天明细
 *   node hercost.mjs --write        # 写入 /data/adb/budget/her-cost
 */

import fs from 'node:fs';
import path from 'node:path';
import zlib from 'node:zlib';

// HOME 在 proot 里是 '/'，不能靠它；固定 /root，可用 HERCOST_DSH 覆盖
const DSH = process.env.HERCOST_DSH || '/root/.dsh';
const SESSION_DIRS = [
  path.join(DSH, 'sessions', '--root--'),
  path.join(DSH, 'sessions-archive'),
];
const CACHE_FILE = path.join(DSH, 'hercost-cache.json');
const OUT_FILE = '/data/adb/budget/her-cost';

// deepseek-flash 单价（元 / 百万 tokens），见官方 pricing
const PRICE = {
  flash: {
    missPeak: 2.0, missIdle: 1.0,
    hitPeak: 0.04, hitIdle: 0.02,
    outPeak: 8.0, outIdle: 4.0,
  },
};

const MAGIC = Buffer.from([0x28, 0xb5, 0x2f, 0xfd]);

function decompressAll(buf) {
  const idx = [];
  for (let i = 0; i + 3 < buf.length; i++) {
    if (buf[i] === 0x28 && buf[i + 1] === 0xb5 && buf[i + 2] === 0x2f && buf[i + 3] === 0xfd) idx.push(i);
  }
  const parts = [];
  for (let k = 0; k < idx.length; k++) {
    const seg = buf.subarray(idx[k], k + 1 < idx.length ? idx[k + 1] : buf.length);
    try { parts.push(zlib.zstdDecompressSync(seg)); } catch { /* 跳过坏帧 */ }
  }
  return Buffer.concat(parts).toString('utf8');
}

function isPeak(ms) {
  const d = new Date(ms + 8 * 3600 * 1000); // 北京时间
  const dow = d.getUTCDay();               // 0=周日
  if (dow === 0 || dow === 6) return false;
  const h = d.getUTCHours();
  return (h >= 9 && h < 12) || (h >= 14 && h < 18);
}

function bjDay(ms) {
  return new Date(ms + 8 * 3600 * 1000).toISOString().slice(0, 10);
}

function listFiles() {
  const out = [];
  for (const dir of SESSION_DIRS) {
    if (!fs.existsSync(dir)) continue;
    for (const name of fs.readdirSync(dir)) {
      const p = path.join(dir, name, 'session.v4.jsonl.zstd');
      if (fs.existsSync(p)) out.push(p);
      // 归档目录里的文件直接是目录形式
      const p2 = path.join(dir, name);
      if (fs.existsSync(p2) && !fs.statSync(p2).isDirectory()) out.push(p2);
    }
  }
  return [...new Set(out)];
}

// 按文件缓存已解析结果（size+mtime 不变就复用）
let cache = {};
try { cache = JSON.parse(fs.readFileSync(CACHE_FILE, 'utf8')); } catch { cache = {}; }
const nextCache = {};

function parseFile(p) {
  const st = fs.statSync(p);
  const key = p;
  const sig = `${st.size}:${st.mtimeMs}`;
  if (cache[key] && cache[key].sig === sig) { nextCache[key] = cache[key]; return cache[key].rows; }

  const text = decompressAll(fs.readFileSync(p));
  const rows = [];
  for (const line of text.split('\n')) {
    if (!line.includes('"usage"')) continue;
    const mu = line.match(/"usage":\{([^}]*)\}/);
    if (!mu) continue;
    const u = {};
    mu[1].replace(/"(\w+)":(\d+)/g, (_, k, v) => { u[k] = +v; return _; });
    if (!u.inputTokens && !u.outputTokens && !u.cacheReadTokens) continue;
    const mt = line.match(/"time":(\d{13})/);
    const mm = line.match(/"model":"([^"]+)"/);
    rows.push({
      t: mt ? +mt[1] : null,
      model: mm ? mm[1] : 'deepseek-flash',
      miss: u.inputTokens || 0,
      hit: u.cacheReadTokens || 0,
      out: u.outputTokens || 0,
    });
  }
  nextCache[key] = { sig, rows };
  return rows;
}

function costOf(row) {
  const pr = PRICE.flash;
  const peak = row.t ? isPeak(row.t) : false;
  const c = (row.miss * (peak ? pr.missPeak : pr.missIdle)
    + row.hit * (peak ? pr.hitPeak : pr.hitIdle)
    + row.out * (peak ? pr.outPeak : pr.outIdle)) / 1e6;
  return c;
}

// ---- main ----
const args = process.argv.slice(2);
const wantJson = args.includes('--json');
const wantWrite = args.includes('--write');
const daysIdx = args.indexOf('--days');
const daysBack = daysIdx >= 0 ? Number(args[daysIdx + 1] || 1) : 1;

const files = listFiles();
let all = [];
for (const f of files) {
  try { all = all.concat(parseFile(f)); } catch { /* ignore */ }
}
// 剪枝：只保留仍然存在的文件，避免缓存无限增长
for (const k of Object.keys(nextCache)) {
  if (!fs.existsSync(k)) delete nextCache[k];
  else if (nextCache[k].rows && nextCache[k].rows.length > 20000) nextCache[k].rows = nextCache[k].rows.slice(-20000);
}
try { fs.writeFileSync(CACHE_FILE, JSON.stringify(nextCache)); } catch { /* ignore */ }

const byDay = {};
for (const r of all) {
  if (!r.t) continue;
  const d = bjDay(r.t);
  const e = byDay[d] || (byDay[d] = { cost: 0, calls: 0, miss: 0, hit: 0, out: 0 });
  e.cost += costOf(r);
  e.calls += 1;
  e.miss += r.miss; e.hit += r.hit; e.out += r.out;
}

const todayBj = bjDay(Date.now());
const days = Object.keys(byDay).sort().reverse().slice(0, daysBack);
const today = byDay[todayBj] || { cost: 0, calls: 0, miss: 0, hit: 0, out: 0 };

if (wantJson) {
  console.log(JSON.stringify({
    today: todayBj,
    cost: +today.cost.toFixed(4),
    calls: today.calls,
    tokens: { miss: today.miss, hit: today.hit, out: today.out },
    days: days.map(d => ({ date: d, ...byDay[d], cost: +byDay[d].cost.toFixed(4) })),
    files: files.length,
  }, null, 2));
} else {
  console.log(today.cost.toFixed(4));
}

if (wantWrite) {
  try {
    fs.mkdirSync('/data/adb/budget', { recursive: true });
    fs.writeFileSync(OUT_FILE, JSON.stringify({
      date: todayBj,
      cost: +today.cost.toFixed(4),
      calls: today.calls,
      ts: Date.now(),
    }) + '\n');
  } catch (e) { console.error('write failed:', e.message); }
}
