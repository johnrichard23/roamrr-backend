import { PGlite } from '@electric-sql/pglite';
import fs from 'node:fs';

const SQL_DIR = new URL('../../migrations', import.meta.url).pathname;
const db = new PGlite();
let pass = 0;
let fail = 0;
const ok = (name, cond, extra = '') => {
  if (cond) { pass++; console.log('PASS', name); }
  else { fail++; console.log('FAIL', name, extra); }
};
const q = async (sql, params) => (await db.query(sql, params)).rows;
const su = async () => { await db.exec('reset role'); };
const as = async (u) => {
  await db.exec(`reset role; set role authenticated; select set_config('request.jwt.claim.sub','${u}', false)`);
};
const throws = async (name, fn, match) => {
  try { await fn(); ok(name, false, 'did not throw'); }
  catch (e) { ok(name, !match || String(e.message).includes(match), e.message); }
};

const A = 'aaaaaaaa-0000-4000-8000-000000000001';
const B = 'aaaaaaaa-0000-4000-8000-000000000002';
const C = 'aaaaaaaa-0000-4000-8000-000000000003';
const D = 'aaaaaaaa-0000-4000-8000-000000000004';
const T = '11111111-1111-4111-8111-111111111111';
let n = 0;
const uuid = () => `00000000-0000-4000-8000-${String(++n).padStart(12, '0')}`;

// Stubs for the Supabase pieces that do not exist in plain Postgres.
await db.exec(`
  create role anon nologin; create role authenticated nologin; create role service_role nologin;
  create schema auth;
  create table auth.users (id uuid primary key, raw_user_meta_data jsonb);
  create function auth.uid() returns uuid language sql stable as
    $$ select nullif(current_setting('request.jwt.claim.sub', true), '')::uuid $$;
  grant usage on schema auth to anon, authenticated;
  grant execute on function auth.uid() to anon, authenticated;
  grant usage on schema public to anon, authenticated;
`);

for (const f of fs.readdirSync(SQL_DIR).filter((f) => f.endsWith('.sql')).sort()) {
  try {
    await db.exec(fs.readFileSync(`${SQL_DIR}/${f}`, 'utf8'));
    ok(`load ${f}`, true);
  } catch (e) {
    ok(`load ${f}`, false, e.message);
    console.log(`\n${pass} passed, ${fail} failed`);
    process.exit(1);
  }
}

// People ------------------------------------------------------------------
for (const [id, name] of [[A, 'Ana'], [B, 'Ben'], [C, 'Cai'], [D, 'Dee']]) {
  await db.query('insert into auth.users (id, raw_user_meta_data) values ($1, $2)', [id, JSON.stringify({ full_name: name })]);
}
ok('profile created by trigger', (await q('select count(*)::int c from public.profiles'))[0].c === 4);
await db.query("insert into auth.users (id) values ('aaaaaaaa-0000-4000-8000-000000000009')");
ok('profile defaults to Traveler',
  (await q("select display_name from public.profiles where id='aaaaaaaa-0000-4000-8000-000000000009'"))[0].display_name === 'Traveler');

// Money functions -----------------------------------------------------------
const hs = async (x) => (await q('select public.round_half_even($1::numeric)::text r', [x]))[0].r;
ok('round_half_even 2.5 -> 2', (await hs('2.5')) === '2');
ok('round_half_even 3.5 -> 4', (await hs('3.5')) === '4');
ok('round_half_even -0.5 -> 0', (await hs('-0.5')) === '0');
ok('round_half_even -1.5 -> -2', (await hs('-1.5')) === '-2');
ok('round_half_even 2.4999 -> 2', (await hs('2.4999')) === '2');
ok('convert JPY->PHP', (await q("select public.convert_minor(10000,'JPY','PHP',0.4)::text r"))[0].r === '400000');
ok('convert USD->PHP', (await q("select public.convert_minor(1000,'USD','PHP',56.5)::text r"))[0].r === '56500');
ok('convert PHP->KWD (3 digits)', (await q("select public.convert_minor(100000,'PHP','KWD',0.0055)::text r"))[0].r === '5500');
await throws('unsupported currency', () => q("select public.convert_minor(1,'XXX','PHP',1)"), 'unsupported currency');

const m1 = 'bbbbbbbb-0000-4000-8000-000000000001';
const m2 = 'bbbbbbbb-0000-4000-8000-000000000002';
const m3 = 'bbbbbbbb-0000-4000-8000-000000000003';
const sh = async (total, w) => (await q(
  'select member_id::text, share_minor::int s from public.compute_shares($1, $2::uuid[], $3::numeric[]) order by member_id',
  [total, `{${[m1, m2, m3].slice(0, w.length).join(',')}}`, `{${w.join(',')}}`])).map(r => r.s);
ok('equal split 1000/3 = 334,333,333', JSON.stringify(await sh(1000, [1, 1, 1])) === '[334,333,333]');
ok('weights 1,2,3 of 100 = 17,33,50', JSON.stringify(await sh(100, [1, 2, 3])) === '[17,33,50]');
ok('percent 50/30/20 of 10000', JSON.stringify(await sh(10000, [50, 30, 20])) === '[5000,3000,2000]');
for (const [t, w] of [[1, [1, 1, 1]], [2, [1, 1, 1]], [99999, [7, 11, 13]], [100, [33.333333, 33.333333, 33.333334]]]) {
  const s = await sh(t, w);
  ok(`sum check total=${t}`, s.reduce((a, b) => a + b, 0) === t, JSON.stringify(s));
}
await throws('zero weight rejected', () => sh(100, [1, 0, 1]), 'weights must be positive');

// Trip lifecycle ------------------------------------------------------------
await as(A);
await q('select public.create_trip($1,$2,$3,$4,$5)', [T, 'Siargao', '2026-12-01', '2026-12-07', 'PHP']);
ok('create_trip is idempotent for the owner', (await q('select public.create_trip($1,$2,$3,$4,$5) r', [T, 'Siargao', null, null, 'PHP']))[0].r === T);
await as(B);
await throws('another user cannot reuse a trip id', () => q('select public.create_trip($1,$2,$3,$4,$5)', [T, 'x', null, null, 'PHP']), 'already used');
await as(D);
await throws('non-member cannot create invite', () => q('select public.create_invite($1,null)', [T]), 'only the trip owner');
await as(A);
const code = (await q('select public.create_invite($1,null) r', [T]))[0].r;
ok('invite code is 8 safe chars', /^[A-HJ-NP-Z2-9]{8}$/.test(code), code);
await as(B); await q('select public.join_trip_by_invite($1)', [code]);
await as(C); await q('select public.join_trip_by_invite($1)', [code]);
await as(C);
ok('joining twice is harmless', (await q('select public.join_trip_by_invite($1) r', [code.toLowerCase()]))[0].r === T);
await su();
ok('use_count counts only first joins', (await q('select use_count from public.trip_invites where code=$1', [code]))[0].use_count === 2);
const members = await q("select id::text, user_id::text from public.trip_members where trip_id=$1 order by id", [T]);
const mid = Object.fromEntries(members.map(r => [r.user_id, r.id]));
ok('three members', members.length === 3);
await as(D);
await throws('bad invite rejected', () => q("select public.join_trip_by_invite('ZZZZZZZZ')"), 'not valid');
await su();
await db.query("update public.trip_invites set expires_at = now() - interval '1 minute' where code=$1", [code]);
await as(D);
await throws('expired invite rejected', () => q('select public.join_trip_by_invite($1)', [code]), 'not valid');

// RLS ------------------------------------------------------------------------
await as(D);
ok('outsider sees no trips', (await q('select count(*)::int c from public.trips'))[0].c === 0);
ok('outsider sees no members', (await q('select count(*)::int c from public.trip_members'))[0].c === 0);
await as(B);
ok('member sees the trip', (await q('select count(*)::int c from public.trips'))[0].c === 1);
ok('member sees profiles of co-travelers', (await q('select count(*)::int c from public.profiles'))[0].c === 3);
await throws('direct insert on expenses denied', () => q(
  `insert into public.expenses (id,trip_id,payer_member_id,description,spent_on,amount_minor,currency,amount_trip_minor,split_type,created_by)
   values ($1,$2,$3,'x','2026-12-01',100,'PHP',100,'equal',$4)`, [uuid(), T, mid[B], B]), 'permission denied');
await throws('direct update on trips denied', () => q("update public.trips set name='hack'"), 'permission denied');
await throws('cannot read mutation_log', () => q('select * from public.mutation_log'), 'permission denied');
await throws('anon-only helper hidden', () => q('select public._apply_expense_delete($1::jsonb)', ['{}']), 'permission denied');

// Expenses ---------------------------------------------------------------------
const apply = async (u, muts) => {
  await as(u);
  return (await q('select public.apply_mutations($1::jsonb) r', [JSON.stringify(muts)]))[0].r;
};
const E1 = uuid();
const exp = (id, over = {}) => ({
  mutation_id: uuid(), entity: 'expense', op: 'upsert',
  payload: {
    id, trip_id: T, payer_member_id: mid[A], description: 'Dinner', spent_on: '2026-12-02',
    amount_minor: 100000, currency: 'PHP', split_type: 'equal',
    splits: [A, B, C].map(u => ({ member_id: mid[u], value: 1 })), ...over,
  },
});
const mu1 = exp(E1);
let r = await apply(A, [mu1]);
ok('expense applied', r[0].status === 'applied', JSON.stringify(r));
r = await apply(A, [mu1]);
ok('retry is a duplicate, not a second write', r[0].duplicate === true && r[0].status === 'applied', JSON.stringify(r));
await su();
ok('only one expense exists', (await q('select count(*)::int c from public.expenses'))[0].c === 1);
const shares = await q('select member_id::text, share_minor::int s from public.expense_shares where expense_id=$1 order by member_id', [E1]);
const firstId = [mid[A], mid[B], mid[C]].sort()[0];
ok('shares sum to total', shares.reduce((a, b) => a + b.s, 0) === 100000);
ok('leftover cent goes to smallest member id', shares.find(x => x.member_id === firstId).s === 33334, JSON.stringify(shares));

await as(B);
let bal = await q('select member_id::text, net_minor::int n from public.trip_balances($1)', [T]);
ok('balances sum to zero', bal.reduce((a, b) => a + b.n, 0) === 0, JSON.stringify(bal));
ok('payer is owed the others shares', bal.find(x => x.member_id === mid[A]).n === 100000 - shares.find(x => x.member_id === mid[A]).s);
let plan = await q('select from_member::text f, to_member::text t, amount_minor::int a from public.simplified_settlements($1)', [T]);
ok('two payments to the payer', plan.length === 2 && plan.every(p => p.t === mid[A]), JSON.stringify(plan));

r = await apply(B, [{ mutation_id: uuid(), entity: 'settlement', op: 'upsert', payload: { id: uuid(), trip_id: T, from_member_id: mid[B], to_member_id: mid[A], amount_minor: plan.find(p => p.f === mid[B]).a, method: 'gcash', settled_on: '2026-12-03' } }]);
ok('settlement applied', r[0].status === 'applied', JSON.stringify(r));
plan = await q('select from_member::text f from public.simplified_settlements($1)', [T]);
ok('settling B leaves one payment (C)', plan.length === 1 && plan[0].f === mid[C], JSON.stringify(plan));

// Foreign currency and exact split
const E2 = uuid();
r = await apply(B, [exp(E2, {
  payer_member_id: mid[B], amount_minor: 1000, currency: 'USD', fx_rate: 56.5, fx_source: 'manual',
  split_type: 'exact', splits: [{ member_id: mid[A], value: 600 }, { member_id: mid[C], value: 400 }],
})]);
ok('USD expense with exact split applied', r[0].status === 'applied', JSON.stringify(r));
await su();
const e2 = (await q('select amount_trip_minor::int t from public.expenses where id=$1', [E2]))[0];
ok('converted to 56500 PHP minor', e2.t === 56500);
const e2s = await q('select member_id::text, share_minor::int s from public.expense_shares where expense_id=$1', [E2]);
ok('exact split 600/400 -> 33900/22600', e2s.find(x => x.member_id === mid[A]).s === 33900 && e2s.find(x => x.member_id === mid[C]).s === 22600, JSON.stringify(e2s));

// Validation
r = await apply(A, [exp(uuid(), { currency: 'USD' })]);
ok('foreign currency without rate rejected', r[0].status === 'rejected' && /exchange rate/.test(r[0].error), JSON.stringify(r));
r = await apply(A, [exp(uuid(), { split_type: 'percent', splits: [{ member_id: mid[A], value: 60 }, { member_id: mid[B], value: 30 }] })]);
ok('percent not summing to 100 rejected', r[0].status === 'rejected' && /100/.test(r[0].error), JSON.stringify(r));
r = await apply(A, [exp(uuid(), { splits: [{ member_id: mid[A], value: 1 }, { member_id: mid[A], value: 1 }] })]);
ok('duplicate participant rejected', r[0].status === 'rejected', JSON.stringify(r));
r = await apply(A, [exp(uuid(), { amount_minor: 0 })]);
ok('zero amount rejected', r[0].status === 'rejected', JSON.stringify(r));
r = await apply(D, [exp(uuid())]);
ok('outsider write rejected with 42501', r[0].status === 'rejected' && r[0].code === '42501', JSON.stringify(r));
r = await apply(A, [exp(uuid(), { amount_minor: 5 }), exp(uuid(), { description: 'Taxi' })]);
ok('one bad mutation does not block the next', r[0].status === 'applied' && r[1].status === 'applied', JSON.stringify(r));

// Edit and delete rules
r = await apply(B, [exp(E1, { description: 'Dinner (edited by Ben)' })]);
ok('non-creator non-owner cannot edit', r[0].status === 'rejected' && r[0].code === '42501', JSON.stringify(r));
r = await apply(A, [exp(E2, { payer_member_id: mid[B], description: 'USD lunch (owner edit)', amount_minor: 1000, currency: 'USD', fx_rate: 56.5, fx_source: 'manual', split_type: 'equal', splits: [A, B].map(u => ({ member_id: mid[u], value: 1 })) })]);
ok('trip owner can edit anyone’s expense', r[0].status === 'applied', JSON.stringify(r));
await su();
ok('edit bumped version and kept a revision',
  (await q('select version from public.expenses where id=$1', [E2]))[0].version === 2
  && (await q('select count(*)::int c from public.expense_revisions where expense_id=$1', [E2]))[0].c === 1);
r = await apply(A, [{ mutation_id: uuid(), entity: 'expense', op: 'delete', payload: { id: E1 } }]);
ok('creator deletes expense', r[0].status === 'applied', JSON.stringify(r));
r = await apply(A, [exp(E1, { description: 'late edit' })]);
ok('edit after delete is rejected (delete wins)', r[0].status === 'rejected' && /deleted/.test(r[0].error), JSON.stringify(r));
await as(A);
bal = await q('select net_minor::int n from public.trip_balances($1)', [T]);
ok('balances still sum to zero after delete', bal.reduce((a, b) => a + b.n, 0) === 0, JSON.stringify(bal));

// Pull -------------------------------------------------------------------------
await as(C);
let pull = (await q('select public.pull_changes($1, 0) r', [T]))[0].r;
ok('pull from 0 returns trip, members, expenses', pull.trips.length === 1 && pull.members.length === 3 && pull.expenses.length >= 3, JSON.stringify(Object.fromEntries(Object.entries(pull).map(([k, v]) => [k, Array.isArray(v) ? v.length : v]))));
ok('pull returns tombstone for deleted expense', pull.expenses.some(e => e.id === E1 && e.deleted_at));
ok('pulled expenses embed shares', pull.expenses.every(e => Array.isArray(e.shares) && e.shares.length > 0));
const next = (await q('select public.pull_changes($1, $2::bigint) r', [T, pull.max_seq]))[0].r;
ok('pull after max_seq is empty', next.expenses.length === 0 && next.members.length === 0 && next.has_more === false);
const paged = (await q('select public.pull_changes($1, 0, null, 2) r', [T]))[0].r;
ok('paging sets has_more', paged.has_more === true);
await as(D);
await throws('outsider cannot pull', () => q('select public.pull_changes($1, 0)', [T]), 'not a member');

// Trip rules -------------------------------------------------------------------
await as(A);
await throws('home currency locked once expenses exist', () => q("select public.update_trip($1,'Siargao',null,null,'active','USD')", [T]), 'home currency cannot change');
await q("select public.update_trip($1,'Siargao 2026',null,null,'active',null)", [T]);
await as(B);
await throws('member cannot edit trip', () => q("select public.update_trip($1,'x',null,null,'active',null)", [T]), 'only the trip owner');

// Placeholder + claim --------------------------------------------------------
await as(B);
const PH = uuid();
await q('select public.add_placeholder_member($1,$2,$3)', [PH, T, 'Lola']);
ok('placeholder added and idempotent', (await q('select public.add_placeholder_member($1,$2,$3) r', [PH, T, 'Lola']))[0].r === PH);
await as(A);
const code2 = (await q('select public.create_invite($1,$2) r', [T, PH]))[0].r;
await as(D); await q('select public.join_trip_by_invite($1)', [code2]);
await su();
ok('claiming a placeholder links the user and keeps the name',
  (await q('select user_id::text u, display_name n from public.trip_members where id=$1', [PH]))[0].u === D
  && (await q('select display_name n from public.trip_members where id=$1', [PH]))[0].n === 'Lola');
const E3 = uuid();
r = await apply(A, [exp(E3, { amount_minor: 40000, splits: [A, B, C].map(u => ({ member_id: mid[u], value: 1 })).concat([{ member_id: PH, value: 1 }]) })]);
ok('expense can include a claimed placeholder member', r[0].status === 'applied', JSON.stringify(r));
await su();
ok('placeholder share is 10000', (await q('select share_minor::int s from public.expense_shares where expense_id=$1 and member_id=$2', [E3, PH]))[0].s === 10000);

// Album links ------------------------------------------------------------------
const L1 = uuid();
r = await apply(B, [{ mutation_id: uuid(), entity: 'album_link', op: 'upsert', payload: { id: uuid(), trip_id: T, url: 'http://insecure.example/a', label: 'x' } }]);
ok('http link rejected', r[0].status === 'rejected', JSON.stringify(r));
r = await apply(B, [{ mutation_id: uuid(), entity: 'album_link', op: 'upsert', payload: { id: L1, trip_id: T, url: 'https://photos.app.goo.gl/abc123', label: 'Day 1 photos' } }]);
ok('https link accepted', r[0].status === 'applied', JSON.stringify(r));
r = await apply(C, [{ mutation_id: uuid(), entity: 'album_link', op: 'delete', payload: { id: L1 } }]);
ok('other member cannot remove link', r[0].status === 'rejected' && r[0].code === '42501', JSON.stringify(r));
r = await apply(A, [{ mutation_id: uuid(), entity: 'album_link', op: 'delete', payload: { id: L1 } }]);
ok('owner can remove link', r[0].status === 'applied', JSON.stringify(r));

// Places ----------------------------------------------------------------------
r = await apply(C, [{ mutation_id: uuid(), entity: 'place', op: 'upsert', payload: { id: uuid(), trip_id: T, name: 'Cloud 9', latitude: 9.8, longitude: 126.16, category: 'attraction' } }]);
ok('place saved', r[0].status === 'applied', JSON.stringify(r));
r = await apply(C, [{ mutation_id: uuid(), entity: 'place', op: 'upsert', payload: { id: uuid(), trip_id: T, name: 'Nowhere', latitude: 123, longitude: 0 } }]);
ok('out-of-range latitude rejected without leaking details', r[0].status === 'rejected' && r[0].error === 'internal error', JSON.stringify(r));
r = await apply(C, [{ mutation_id: uuid(), entity: 'bogus', op: 'upsert', payload: {} }]);
ok('unknown mutation rejected', r[0].status === 'rejected' && /unknown mutation/.test(r[0].error), JSON.stringify(r));

// Location ---------------------------------------------------------------------
await as(B);
await q('select public.set_location_sharing($1, true, 2)', [T]);
ok('first location stored', (await q('select public.upsert_last_location($1, 9.8, 126.1, 12) r', [T]))[0].r === true);
ok('second location within 10s is throttled', (await q('select public.upsert_last_location($1, 9.9, 126.2, 12) r', [T]))[0].r === false);
await as(A);
ok('co-traveler sees the position', (await q('select count(*)::int c from public.location_shares where user_id=$1 and last_lat is not null', [B]))[0].c === 1);
await as(D);
ok('placeholder-claimer D (member) also sees it', (await q('select count(*)::int c from public.location_shares where user_id=$1', [B]))[0].c === 1);
await as(A);
await q('insert into public.blocks (blocker_id, blocked_id) values ($1,$2)', [A, B]);
ok('blocker no longer sees blocked user position', (await q('select count(*)::int c from public.location_shares where user_id=$1', [B]))[0].c === 0);
await q('delete from public.blocks where blocker_id=$1', [A]);
await as(B);
await throws('sharing longer than 72h rejected', () => q('select public.set_location_sharing($1, true, 100)', [T]), 'between 1 and 72');
await su();
await db.query("update public.location_shares set expires_at = now() - interval '1 minute' where user_id=$1", [B]);
await as(A);
ok('expired share is hidden before cleanup runs', (await q('select count(*)::int c from public.location_shares where user_id=$1', [B]))[0].c === 0);
await su();
ok('expire_location_shares clears coordinates', (await q('select public.expire_location_shares() r'))[0].r === 1
  && (await q('select last_lat from public.location_shares where user_id=$1', [B]))[0].last_lat === null);
await as(B);
await q('select public.set_location_sharing($1, true, 1)', [T]);
await q('select public.set_location_sharing($1, false)', [T]);
await as(A);
ok('turning sharing off hides the position', (await q('select count(*)::int c from public.location_shares where user_id=$1 and enabled', [B]))[0].c === 0);

// Removing and leaving -----------------------------------------------------------
await as(A);
await q('select public.remove_member($1,$2)', [T, mid[C]]);
await as(C);
await throws('removed member can no longer pull', () => q('select public.pull_changes($1, 0)', [T]), 'not a member');
ok('removed member sees no trips', (await q('select count(*)::int c from public.trips'))[0].c === 0);
await as(B);
await q('select public.leave_trip($1)', [T]);
await as(A);
await throws('owner cannot leave', () => q('select public.leave_trip($1)', [T]), 'cannot leave');
await as(A);
const balAfter = await q('select member_id::text, net_minor::int n from public.trip_balances($1)', [T]);
ok('balances still list members who left or were removed', balAfter.length === 4 && balAfter.some(x => x.member_id === mid[B]) && balAfter.some(x => x.member_id === mid[C]), JSON.stringify(balAfter));
ok('balances sum to zero at the end', balAfter.reduce((a, b) => a + b.n, 0) === 0, JSON.stringify(balAfter));

// Safety net: shares must add up ----------------------------------------------------
await su();
await throws('commit fails when an expense has no shares', async () => {
  await db.exec('begin');
  try {
    await db.query(`insert into public.expenses (id,trip_id,payer_member_id,description,spent_on,amount_minor,currency,amount_trip_minor,split_type,created_by)
      values ($1,$2,$3,'orphan','2026-12-01',100,'PHP',100,'equal',$4)`, [uuid(), T, mid[A], A]);
    await db.exec('commit');
  } catch (e) { await db.exec('rollback'); throw e; }
}, 'do not add up');

// Sequence ---------------------------------------------------------------------------
const seqs = await q('select server_seq::text s from public.expenses order by server_seq');
ok('server_seq is strictly increasing and unique', new Set(seqs.map(x => x.s)).size === seqs.length);

console.log(`\n${pass} passed, ${fail} failed`);
process.exit(fail ? 1 : 0);
