import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
function walk(directory) {
  return fs.readdirSync(directory, { withFileTypes: true }).flatMap(entry => {
    if (entry.name.startsWith('.')) return [];
    const file = path.join(directory, entry.name);
    return entry.isDirectory() ? walk(file) : [file];
  });
}
const files = walk(path.join(root, 'macos'));
for (const file of files) {
  if (/\.pyc?$/.test(file)) throw new Error(`Native helper tree contains Python: ${file}`);
  if (!/\.(swift|sh)$/.test(file)) continue;
  const source = fs.readFileSync(file, 'utf8');
  // Reject executable Python references; legacy migration fixtures may name an old interpreter as data.
  if (/ProcessRunner\.run\([^\n]*python|executableURL\s*=.*python|^\s*(?:exec\s+)?(?:\/[^\s]+\/)?python(?:3)?\s/m.test(source)) {
    throw new Error(`Python invocation in native runtime or helper: ${file}`);
  }
}
console.log('Native source/test helpers contain no Python files or interpreter invocations.');
