// Runs inside the n8n container: node - <rawDir> <cleanDir>
// Keeps only what is needed to rebuild a workflow. Drops data that is personal
// or runtime-only: owner name/e-mail ("shared"), pinned test data with real
// messages ("pinData"), static data, version history, activation state.
const fs = require('fs');
const path = require('path');

const [src, dst] = process.argv.slice(2);
const KEEP = ['id', 'name', 'nodes', 'connections', 'settings'];

for (const file of fs.readdirSync(src).filter((f) => f.endsWith('.json'))) {
  const wf = JSON.parse(fs.readFileSync(path.join(src, file), 'utf8'));
  if (wf.isArchived) continue;

  const clean = {};
  for (const key of KEEP) if (wf[key] !== undefined) clean[key] = wf[key];

  const slug = String(wf.name || '').toLowerCase().replace(/[^a-z0-9]+/g, '-').replace(/^-+|-+$/g, '');
  let name = (slug || wf.id) + '.json';
  if (fs.existsSync(path.join(dst, name))) name = `${slug}-${wf.id}.json`;

  fs.writeFileSync(path.join(dst, name), JSON.stringify(clean, null, 2) + '\n');
  console.log(name);
}
