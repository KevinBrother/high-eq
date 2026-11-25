// Optional offline SQL check, NOT a Compose/recovery signoff. Pass local PGlite 0.3.2 package dir.
import fs from 'node:fs';
import {pathToFileURL} from 'node:url';
import assert from 'node:assert/strict';
const [pkg, migrations] = process.argv.slice(2);
const {PGlite} = await import(pathToFileURL(`${pkg}/dist/index.js`));
const {btree_gist} = await import(pathToFileURL(`${pkg}/dist/contrib/btree_gist.js`));
const db = new PGlite({extensions:{btree_gist}});
try {
  for (const f of fs.readdirSync(migrations).filter(x=>x.endsWith('.up.sql')).sort())
    await db.exec(fs.readFileSync(`${migrations}/${f}`, 'utf8'));
  const sql = fs.readFileSync(new URL('../cost.sql', import.meta.url),'utf8');
  const cases = fs.readFileSync(new URL('cost-cases.sql',import.meta.url),'utf8');
  const status = (await db.exec(cases.replaceAll('\\i /ops/cost.sql',sql)))
    .flatMap(result=>result.rows.map(row=>Object.values(row)[0]));
  assert.deepEqual(status,['normal','cost_anomaly','cost_anomaly','unpriced','normal','cost_anomaly','unpriced']);
  console.log('PASS PostgreSQL WASM cost cases:',status.join(', '));
} finally { await db.close(); }
