// generate-matches-json.mjs
// Fetches upcoming World Cup 2026 fixtures from The Odds API and writes
// matches.json in the project root for use by script/BatchDeploy.s.sol.
//
// Usage:
//   node scripts/generate-matches-json.mjs
//   npm run generate-matches
//
// Requires ODDS_API_KEY in shobu-cup/.env (or in the environment).

import { readFileSync, writeFileSync } from 'fs';
import { fileURLToPath } from 'url';
import { dirname, join, resolve } from 'path';

const __dirname = dirname(fileURLToPath(import.meta.url));
const PROJECT_ROOT = resolve(__dirname, '..');

// ── Load .env from project root ───────────────────────────────────────────────
try {
  const envContent = readFileSync(join(PROJECT_ROOT, '.env'), 'utf8');
  for (const line of envContent.split('\n')) {
    const trimmed = line.trim();
    if (!trimmed || trimmed.startsWith('#')) continue;
    const eqIdx = trimmed.indexOf('=');
    if (eqIdx === -1) continue;
    const k = trimmed.slice(0, eqIdx).trim();
    const v = trimmed.slice(eqIdx + 1).trim().replace(/^["']|["']$/g, '');
    if (k && !process.env[k]) process.env[k] = v;
  }
} catch {
  // .env not found — rely on process.env already being set
}

// ── Tournament phase boundaries (UTC) ────────────────────────────────────────
// Group stage ends June 27; R32+R16+QF through July 11; SF+Final July 12+
const GROUP_END    = new Date('2026-06-28T00:00:00Z'); // < this → SOFT (0)
const KNOCKOUT_END = new Date('2026-07-12T00:00:00Z'); // < this → BALANCED (1), else AGGRESSIVE (2)

function feeProfile(kickoffDate) {
  if (kickoffDate < GROUP_END)    return 0; // SOFT    — group stage
  if (kickoffDate < KNOCKOUT_END) return 1; // BALANCED — R32 / R16 / QF
  return 2;                                  // AGGRESSIVE — SF / Final
}

// ── Main ──────────────────────────────────────────────────────────────────────
async function main() {
  const apiKey = process.env.ODDS_API_KEY;
  if (!apiKey) throw new Error('ODDS_API_KEY not set in .env or environment');

  const sport = 'soccer_fifa_world_cup'; // active key; _2026 variant not yet live on API
  const url =
    `https://api.the-odds-api.com/v4/sports/${sport}/odds/` +
    `?apiKey=${apiKey}&regions=us&markets=h2h&oddsFormat=decimal&dateFormat=iso`;

  console.log(`Fetching: ${sport}`);
  const res = await fetch(url);

  if (!res.ok) {
    const body = await res.text();
    throw new Error(`Odds API ${res.status}: ${body}`);
  }

  const events = await res.json();
  if (!Array.isArray(events)) throw new Error('Unexpected response shape from Odds API');

  console.log(`Total events from API : ${events.length}`);

  const now       = Date.now();
  const windowEnd = now + 7 * 24 * 60 * 60 * 1000;

  let skippedPast   = 0;
  let skippedFuture = 0;
  const matches = [];

  for (const event of events) {
    const kickoffMs   = new Date(event.commence_time).getTime();
    const kickoffDate = new Date(event.commence_time);

    if (kickoffMs <= now) { skippedPast++;   continue; }
    if (kickoffMs >  windowEnd) { skippedFuture++; continue; }

    // JSON keys in alphabetical order so Foundry vm.parseJson struct decode works:
    // feeProfile < kickoff < teamA < teamB
    matches.push({
      feeProfile: feeProfile(kickoffDate),
      kickoff:    Math.floor(kickoffMs / 1000),
      teamA:      event.home_team,
      teamB:      event.away_team,
    });
  }

  console.log(`Skipped (past)     : ${skippedPast}`);
  console.log(`Skipped (>7 days)  : ${skippedFuture}`);
  console.log(`Matches in window  : ${matches.length}`);

  const outPath = join(PROJECT_ROOT, 'matches.json');
  writeFileSync(outPath, JSON.stringify(matches, null, 2));
  console.log(`\nWritten: ${outPath}`);

  if (matches.length > 0) {
    console.log('\nFirst 3 entries:');
    matches.slice(0, 3).forEach((m, i) => {
      const fp  = ['SOFT(0)', 'BALANCED(1)', 'AGGRESSIVE(2)'][m.feeProfile];
      const dt  = new Date(m.kickoff * 1000).toISOString();
      console.log(`  [${i}] ${m.teamA} vs ${m.teamB}`);
      console.log(`       kickoff=${m.kickoff} (${dt})  feeProfile=${fp}`);
    });
  } else {
    console.log('\nNo matches in the 7-day window — matches.json is empty ([]).');
  }
}

main().catch(err => { console.error('Error:', err.message); process.exit(1); });
