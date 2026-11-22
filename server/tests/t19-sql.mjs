// Optional offline SQL check with a locally installed @electric-sql/pglite.
// Run from repo root. No networking, credentials, Dev DB, or .env.
import fs from 'node:fs';
import path from 'node:path';
import {pathToFileURL} from 'node:url';
const dist = process.env.PGLITE_DIR;
if (!dist) throw Error('Set PGLITE_DIR to the installed package directory (tested: 0.3.2)');
const mod = file => pathToFileURL(path.resolve(dist, 'dist', file)).href;
const {PGlite} = await import(mod('index.js'));
const {btree_gist} = await import(mod('contrib/btree_gist.js'));
const db = new PGlite({extensions:{btree_gist}});
const read = file => fs.readFileSync(file, 'utf8');
const dir = 'server/migrations';
try {
  await db.waitReady;
  const migrations = fs.readdirSync(dir).filter(f => f.endsWith('.up.sql')).sort();
  for (const file of migrations) await db.exec(read(path.join(dir, file)));
  let count = 0;
  for (const area of ['training', 'membership', 'service']) {
    const root = `server/internal/${area}`;
    for (const f of fs.readdirSync(root).filter(f => f.endsWith('.go'))) {
      if (area === 'membership' && !['counter.go','settlement.go'].includes(f)) continue;
      if (area === 'service' && !f.startsWith('training')) continue;
      for (const [,sql] of read(path.join(root,f)).matchAll(/`((?:select|update|insert into) [^`]+)`/ig)) {
        if (!sql.includes('%s')) await db.exec(`PREPARE t19_${++count} AS ${sql}`);
      }
    }
  }
  const entry = path.join(dir,migrations.find(f => f.endsWith('_practice_work.up.sql')));
  await db.exec(read(entry.replace('.up.sql','.down.sql')));
  await db.exec(read(entry));
  const {rows} = await db.query(`select template from prompt_versions where id='19000000-1000-4000-8000-000000000001'`);
  if (rows.length!==1 || rows[0].template!==read('server/internal/training/role.txt')) throw Error('immutable draft mismatch');
  console.log(`OK: ${migrations.length} up migrations, ${count} prepared SQL statements, T19 down/up and draft identity (WASM only)`);
} finally { await db.close(); }
