// Optional offline test adapter (PGlite 0.3.2). SQL and transaction control
// go to PostgreSQL itself. No listeners, network, credentials or external DSN.
import { readdir, readFile } from 'node:fs/promises';
import { pathToFileURL } from 'node:url';
const pkg = pathToFileURL(process.env.PGLITE + '/dist/');
const { PGlite } = await import(new URL('index.js', pkg));
const { btree_gist } = await import(new URL('contrib/btree_gist.js', pkg));
const db = new PGlite({extensions: {btree_gist}});
const dir = new URL('../../../migrations/', import.meta.url);
for (const name of (await readdir(dir)).filter(n => n.endsWith('.up.sql')).sort()) {
  await db.exec(await readFile(new URL(name, dir), 'utf8'));
}
let pending = Buffer.alloc(0), started = false;
for await (const chunk of process.stdin) {
  pending = Buffer.concat([pending, chunk]);
  while (pending.length >= 5) {
    const size = started ? 1 + pending.readUInt32BE(1) : pending.readUInt32BE(0);
    if (pending.length < size) break;
    const frame = pending.subarray(0, size); pending = pending.subarray(size);
    if (!started) { // local stdio startup: AuthenticationOk + ReadyForQuery
      started = true; process.stdout.write(Buffer.from('5200000008000000005a0000000549', 'hex')); continue;
    }
    if (frame[0] === 88) { await db.close(); process.exit(0); }
    process.stdout.write(await db.execProtocolRaw(frame));
  }
}
