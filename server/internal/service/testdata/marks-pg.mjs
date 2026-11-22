// Disposable single PostgreSQL backend for sandboxed tests. pgx communicates
// over stdio, not a mock SQL result set. Never open a network listener.
import { readdir, readFile } from 'node:fs/promises';
import { pathToFileURL } from 'node:url';
const pkg = pathToFileURL(`${process.env.PGLITE}/dist/`);
const { PGlite } = await import(new URL('index.js', pkg));
const { btree_gist } = await import(new URL('contrib/btree_gist.js', pkg));
const db = new PGlite({ extensions: { btree_gist } });
const migrations = new URL('../../../migrations/', import.meta.url);
for (const name of (await readdir(migrations)).filter(n => n.endsWith('.up.sql')).sort()) {
  await db.exec(await readFile(new URL(name, migrations), 'utf8'));
}
let buf = Buffer.alloc(0), startup = true;
for await (const chunk of process.stdin) {
  buf = Buffer.concat([buf, chunk]);
  while (buf.length >= 5) {
    const size = startup ? buf.readUInt32BE(0) : 1 + buf.readUInt32BE(1);
    if (buf.length < size) break;
    const frame = buf.subarray(0, size); buf = buf.subarray(size);
    if (startup) {
      // Local process only: AuthenticationOk and ReadyForQuery at PG startup.
      startup = false; process.stdout.write(Buffer.from('5200000008000000005a0000000549', 'hex'));
    } else if (frame[0] === 88) {
      await db.close(); process.exit(0);
    } else { process.stdout.write(await db.execProtocolRaw(frame)); }
  }
}
