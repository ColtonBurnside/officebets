// Uses an isolated in-memory Postgres instance; never connects to production.
const {PGlite}=require('@electric-sql/pglite');
const fs=require('node:fs'),path=require('node:path'),assert=require('node:assert/strict'),{randomUUID}=require('node:crypto');
const root=path.resolve(__dirname,'..');
(async()=>{
 const db=new PGlite();await db.exec(fs.readFileSync(path.join(__dirname,'fixtures/schema-before-design.sql'),'utf8'));
 const migrations=fs.readdirSync(path.join(root,'supabase/migrations'));
 const identity=fs.readFileSync(path.join(root,'supabase/migrations',migrations.find(n=>n.endsWith('_verified_admin_identity.sql'))),'utf8');
 const actions=fs.readFileSync(path.join(root,'supabase/migrations',migrations.find(n=>n.endsWith('_verified_admin_actions.sql'))),'utf8');
 await db.exec(identity);
 const owner=randomUUID(),other=randomUUID(),third=randomUUID(),ownerAuth=randomUUID(),otherAuth=randomUUID(),rogueAuth=randomUUID(),ownerSession=randomUUID(),otherSession=randomUUID(),rogueSession=randomUUID();
 for(const [id,name,admin] of [[owner,'Owner',true],[other,'Other',false],[third,'Third',false]])await db.query('insert into officebets.members(id,name,is_admin) values($1,$2,$3)',[id,name,admin]);
 for(const [id,email] of [[ownerAuth,'owner@example.test'],[otherAuth,'other@example.test'],[rogueAuth,'rogue@example.test']])await db.query('insert into auth.users values($1,$2,now(),null)',[id,email]);
 for(const [id,u] of [[ownerSession,ownerAuth],[otherSession,otherAuth],[rogueSession,rogueAuth]])await db.query('insert into auth.sessions values($1,$2)',[id,u]);
 async function rejected(fn,pattern){let err;try{await fn();}catch(e){err=e;}assert(err,'Expected rejection');if(pattern)assert.match(err.message,pattern);}
 await rejected(()=>db.exec(actions),/Link a confirmed first admin/);await db.exec('rollback');
 await db.query('insert into officebets.admin_identities(member_id,auth_user_id) values($1,$2)',[owner,ownerAuth]);
 await db.exec(actions);
 async function auth(id,session){await db.query("select set_config('request.jwt.claim.sub',$1,false),set_config('request.jwt.claims',$2,false)",[id||'',JSON.stringify(session?{session_id:session}:{})]);}
 async function action(user,action,args={},request=randomUUID()){return (await db.query('select public.ob_action($1,$2,$3,$4::jsonb) value',[request,user,action,JSON.stringify(args)])).rows[0].value;}
 await auth(null,null);
 for(const a of ['admin_user','delete_user','admin_role','edit_market','delete_market','settle','profile'])await rejected(()=>action(owner,a,{user:other}),/Verified admin/);
 await auth(rogueAuth,rogueSession);await rejected(()=>action(owner,'admin_role',{user:other,grant:true,email:'other@example.test',confirmName:'Other'}),/Verified admin/);
 await rejected(()=>action(other,'admin_role',{user:other,grant:true}),/Verified admin/);
 await rejected(()=>action(other,'profile',{name:'Other',avatar:'X',bio:'',isAdmin:true}),/cannot change admin/);
 await action(other,'profile',{name:'Other',avatar:'X',bio:'Ordinary profile'});
 await auth(ownerAuth,ownerSession);
 assert.equal((await db.query('select public.ob_admin_status() status')).rows[0].status.memberId,owner);
 await action(owner,'admin_user',{user:other,name:'Other',avatar:'🦊',bio:'Updated by admin',balance:1500});
 let row=(await db.query('select * from officebets.members where id=$1',[other])).rows[0];assert.equal(row.avatar,'🦊');assert.equal(row.bio,'Updated by admin');assert.equal(Number(row.balance),1500);assert.equal(row.is_admin,false);
 const input={title:'Another creator market',description:'',category:'general',closesAt:new Date(Date.now()+86400000).toISOString(),outcomes:['YES','NO']};
 let snapshot=await action(other,'create_market',input),m=snapshot.markets[0];
 await action(owner,'edit_market',{...input,market:m.id,title:'Admin edited'});
 await action(other,'buy',{market:m.id,outcome:0,amount:'10',minOut:0});
 await rejected(()=>action(owner,'edit_market',{...input,market:m.id}),/Editing is locked/);
 await action(owner,'settle',{market:m.id,outcome:0});assert.equal((await db.query('select winner from officebets.markets where id=$1',[m.id])).rows[0].winner,0);
 await rejected(()=>action(owner,'edit_market',{...input,market:m.id}),/Editing is locked/);
 await action(owner,'delete_market',{market:m.id});assert.equal((await db.query('select * from officebets.markets where id=$1',[m.id])).rows.length,0);
 // Last-admin protection, including trusted maintenance paths.
 await rejected(()=>action(owner,'admin_role',{user:owner,grant:false,confirmName:'Owner'}),/another teammate/);
 await rejected(()=>db.query('update officebets.members set is_admin=false where id=$1',[owner]),/last active verified admin/);
 await rejected(()=>db.query('update officebets.members set active=false where id=$1',[owner]),/last active verified admin/);
 await rejected(()=>db.query('delete from officebets.members where id=$1',[owner]),/last active verified admin/);
 await rejected(()=>action(owner,'admin_role',{user:other,grant:true,email:'missing@example.test',confirmName:'Other'}),/confirm its email/);
 const promotion=randomUUID();await action(owner,'admin_role',{user:other,grant:true,email:'other@example.test',confirmName:'Other'},promotion);await action(owner,'admin_role',{user:other,grant:true,email:'other@example.test',confirmName:'Other'},promotion);
 assert.equal((await db.query("select count(*)::int n from officebets.ledger where kind='ADMIN_ROLE'")).rows[0].n,1);
 await auth(otherAuth,otherSession);await action(other,'admin_user',{user:third,name:'Third',avatar:'T',bio:'Allowed'});
 await auth(ownerAuth,ownerSession);await action(owner,'admin_role',{user:other,grant:false,confirmName:'Other'});
 await auth(otherAuth,otherSession);await rejected(()=>action(other,'admin_user',{user:third,name:'Third'}),/Verified admin/);
 // Revocation is immediate even with an existing JWT and a stored idempotency receipt.
 await rejected(()=>action(other,'admin_role',{user:owner,grant:false,confirmName:'Owner'}),/Verified admin/);
 await auth(ownerAuth,ownerSession);await db.query('delete from auth.sessions where id=$1',[ownerSession]);await rejected(()=>action(owner,'admin_user',{user:third}),/Verified admin/);
 // Direct API-role table writes remain blocked; arbitrary metadata cannot grant a role.
 await db.exec('set role authenticated');await rejected(()=>db.query('update officebets.members set is_admin=true where id=$1',[third]),/permission denied/);await rejected(()=>db.query('insert into officebets.admin_identities values($1,$2,now())',[third,rogueAuth]),/permission denied/);await db.exec('reset role');
 // Ordinary public trading remains available after cutover.
 await auth(null,null);const snap=await action(third,'create_market',{...input,title:'Ordinary trade'});const fresh=snap.markets.find(x=>x.title==='Ordinary trade');await action(other,'buy',{market:fresh.id,outcome:1,amount:'5',minOut:0});
 await db.exec(fs.readFileSync(path.join(__dirname,'account-deletion.sql'),'utf8'));
 await db.close();console.log('PASS: forged admin badges, ordinary profile/role requests, verified profile/market edits, trade locks, early resolution, deletion, grant/revoke, receipts, last-admin safeguards, revoked sessions, RLS/grants and ordinary trading');
})().catch(e=>{console.error(e);process.exit(1)});
