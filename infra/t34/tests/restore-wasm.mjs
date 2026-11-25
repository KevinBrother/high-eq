// Supplementary physical snapshot/FK test. No daemon, sockets, production identity, or substitute signoff.
import fs from 'node:fs';
import {pathToFileURL} from 'node:url';
import {randomUUID as id} from 'node:crypto';
import assert from 'node:assert/strict';
const [pkg, server, privateDir] = process.argv.slice(2);
const {PGlite} = await import(pathToFileURL(`${pkg}/dist/index.js`));
const {btree_gist} = await import(pathToFileURL(`${pkg}/dist/contrib/btree_gist.js`));
const opts={extensions:{btree_gist}};
const a=id(), b=id(), review=id(), source=id(), accountKey=id(), windowKey=id(), model=id();
const ops=fs.readFileSync(`${server}/internal/privacy/coordinator.go`,'utf8');
const scopeSQL=scope=>ops.match(new RegExp(`"${scope}":\\s*\x60(delete from [^\x60]+)\x60`))[1];
const counts=`select (select count(*) from users), (select count(*) from activities) as sources,
 (select count(*) from growth_scores) as copies, (select count(*) from scores) as scores,
 (select count(*) from ai_calls) as calls, (select count(*) from signal_windows) as windows`;
async function inspect(db, expected) {
  const {rows:[row]}=await db.query(counts);
  assert.deepEqual(Object.values(row),expected);
}
async function redelete(db, journal) {
  await db.transaction(async tx=>{
    const {rows}=await tx.query(`select user_id,scope,root_id from erasure_roots`);
    for(const row of rows) if(journal.includes(row.root_id))
      await tx.query(scopeSQL(row.scope),[row.user_id,row.root_id]);
  });
}
let db=new PGlite(opts);
const before=[2,1,1,1,1,2], after=[1,0,0,0,0,1];
try {
  for(const file of fs.readdirSync(`${server}/migrations`).filter(x=>x.endsWith('.up.sql')).sort())
    await db.exec(fs.readFileSync(`${server}/migrations/${file}`,'utf8'));
  await db.query(`insert into users(id,purge_id,age_confirmed_at) values($1,$2,now()),($3,$4,now())`,[a,id(),b,accountKey]);
  await db.query(`insert into activities(id,user_id,source_id,kind,state) values($1,$2,$3,'review','complete')`,[review,a,source]);
  await db.query(`insert into scores(id,activity_id,activity_kind,detail_enc) values($1,$2,'review','x')`,[source,review]);
  await db.query(`insert into growth_scores values($1,'review','x','x')`,[source]);
  await db.query(`insert into model_configs(id,name,endpoint,api_key_enc) values($1,'synthetic','https://unused.invalid','x')`,[model]);
  await db.query(`insert into ai_calls(activity_id,user_id,score_id,model_id,task,outcome) values($1,$2,$3,$4,'review_analysis','ok')`,[review,a,source,model]);
  await db.query(`insert into signal_windows(user_id,starts_at,channel,stats_enc,purge_id) values($1,date_trunc('minute',now()),'health','x',$2),($1,date_trunc('minute',now())-interval '1 minute','health','x',$3)`,[a,windowKey,id()]);
  await inspect(db,before);
  const snapshot=await db.dumpDataDir();
  const journal=[source,accountKey,windowKey].sort();
  const receipt=`${privateDir}/ack.json`;
  fs.writeFileSync(receipt,JSON.stringify(journal),{flag:'wx',mode:0o600});
  try {
    await redelete(db,journal);await inspect(db,after);await db.close();
    db=new PGlite({...opts,loadDataDir:snapshot});await inspect(db,before);
    const expected=JSON.parse(fs.readFileSync(receipt));
    const approve=actual=>assert.deepEqual(actual,expected);
    assert.throws(()=>approve(journal.slice(1)));await inspect(db,before);
    approve(journal);await redelete(db,journal);await inspect(db,after);
    await redelete(db,journal);await inspect(db,after);
    console.log('PASS WASM pre-delete PG snapshot -> separate receipt -> scoped redelete twice; kept neighbor. NOT Compose signoff.');
  } finally {fs.rmSync(receipt);}
} finally {await db.close();}
