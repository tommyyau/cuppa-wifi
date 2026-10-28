import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import { fileURLToPath } from 'node:url';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const directory = path.join(root, 'docs/parity');
// Frozen migration evidence from the v1 reference implementation (archived privately).
// Normal checks also work in a shallow clone, offline, without the retired sources.
const inventorySHA256 = '8ccde70f3d11f2e9dca51fdbe3e0021d075bae191d894cd3c6a370c5701b4016';
for (const argument of process.argv.slice(2)) {
  if (argument !== '--report') throw new Error(`Unknown option: ${argument}; the v1 inventory is immutable`);
}
const snapshotPath = path.join(directory, 'legacy-inventory.json');
const snapshot = fs.readFileSync(snapshotPath);
if (crypto.createHash('sha256').update(snapshot).digest('hex') !== inventorySHA256) {
  throw new Error('Frozen v1 inventory changed; restore the archived baseline instead of rewriting migration history');
}
const inventory = JSON.parse(snapshot);
if (inventory.length !== 401) throw new Error(`Expected 401 baseline cases, found ${inventory.length}`);
const entries = ['networking', 'portals', 'engine', 'core'].flatMap(name => JSON.parse(fs.readFileSync(path.join(directory, `${name}.json`), 'utf8')));
const ids = new Set(inventory.map(x => x.legacy_id));
const seen = new Set();
const counts = { covered: 0, retired: 0, intentional_change: 0 };
for (const entry of entries) {
  if (!ids.has(entry.legacy_id)) throw new Error(`Unknown legacy case: ${entry.legacy_id}`);
  if (seen.has(entry.legacy_id)) throw new Error(`Duplicate legacy case: ${entry.legacy_id}`);
  seen.add(entry.legacy_id);
  if (!(entry.status in counts)) throw new Error(`Unresolved status for ${entry.legacy_id}`);
  if (typeof entry.rationale !== 'string' || entry.rationale.trim().length < 30) throw new Error(`Missing rationale: ${entry.legacy_id}`);
  if (!Array.isArray(entry.native_tests) || (entry.status !== 'retired' && !entry.native_tests.length)) throw new Error(`Missing replacement evidence: ${entry.legacy_id}`);
  for (const ref of entry.native_tests) {
    const [file, symbol, extra] = ref.split('::');
    if (!file?.startsWith('macos/') || !symbol || extra || file.includes('..')) throw new Error(`Invalid test reference: ${ref}`);
    const source = fs.readFileSync(path.join(root, file), 'utf8');
    const escaped = symbol.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
    if (!new RegExp(`\\bfunc\\s+${escaped}\\s*\\(`).test(source)) throw new Error(`Missing native test symbol: ${ref}`);
  }
  counts[entry.status]++;
}
const missing = [...ids].filter(id => !seen.has(id));
if (missing.length) throw new Error(`Unaccounted legacy cases (${missing.length}):\n${missing.join('\n')}`);
console.log(`401/401 legacy cases accounted for: ${Object.entries(counts).map(([k,v]) => `${v} ${k}`).join(', ')}.`);
console.log('This gate checks complete accounting and real test references; semantic equivalence also requires review and executing the suites.');
if (process.argv.includes('--report')) {
  const byID = new Map(entries.map(entry => [entry.legacy_id, entry]));
  const lines = [
    '# Legacy case audit', '',
    `All 401 declared v1 methods are frozen by source hash in \`legacy-inventory.json\`, with the complete inventory SHA-256 pinned in \`scripts/verify-parity.mjs\`. The v1 reference implementation is archived privately and is not part of the maintained checkout.`, '',
    'Each row records a reviewed replacement or explicit behavior change. Multiple original cases may share a native test that asserts each case; counts alone are not evidence of parity.', '',
    '`make parity-audit` rejects missing/duplicate rows, changes to the frozen inventory and nonexistent native test references. It needs no archived checkout, Python interpreter or network connection. `make app` runs that gate, the native/JavaScript/Swift suites, real WebKit fixtures and release packaging. Apple model availability and live venue checks are recorded separately in [verification](../VERIFICATION.md). Regenerate this table with `node scripts/verify-parity.mjs --report` after updating native test references.', '',
    `Accounting: ${Object.entries(counts).map(([key, value]) => `${value} ${key}`).join(', ')}.`, '',
    '| Legacy case | Disposition | Native assertions | Review rationale |',
    '|---|---|---|---|',
  ];
  for (const original of inventory) {
    const entry = byID.get(original.legacy_id);
    const tests = entry.native_tests.map(ref => {
      const [file, symbol] = ref.split('::');
      return `[${symbol}](../../${file})`;
    }).join('<br>') || 'Removed architecture path';
    lines.push(`| \`${entry.legacy_id}\` | ${entry.status} | ${tests} | ${entry.rationale.replaceAll('|', '\\|').replaceAll('\n', ' ')} |`);
  }
  fs.writeFileSync(path.join(directory, 'README.md'), lines.join('\n') + '\n');
}
