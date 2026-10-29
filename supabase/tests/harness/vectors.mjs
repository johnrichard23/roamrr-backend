import { PGlite } from '@electric-sql/pglite';
import fs from 'node:fs';

const MIGRATIONS = new URL('../../migrations', import.meta.url).pathname;
const GOLDEN = new URL('../golden', import.meta.url).pathname;
const db = new PGlite();
await db.exec(`create role anon nologin; create role authenticated nologin; create role service_role nologin;
 create schema auth; create table auth.users (id uuid primary key, raw_user_meta_data jsonb);
 create function auth.uid() returns uuid language sql stable as $$ select nullif(current_setting('request.jwt.claim.sub', true), '')::uuid $$;
 grant usage on schema auth to anon, authenticated; grant usage on schema public to anon, authenticated;`);
for (const f of fs.readdirSync(MIGRATIONS).filter((n) => n.endsWith('.sql')).sort()) {
  await db.exec(fs.readFileSync(`${MIGRATIONS}/${f}`, 'utf8'));
}

// Amounts above 2^53 lose precision in JSON.parse, so read long total_minor values as text.
const cases = (name) => JSON.parse(
  fs.readFileSync(`${GOLDEN}/${name}.json`, 'utf8').replace(/("total_minor": )(-?[0-9]{16,})/g, '$1"$2"')
).cases;
let pass = 0;
let fail = 0;
const ok = (name, cond, extra = '') => {
  if (cond) pass++;
  else { fail++; console.log('FAIL', name, extra); }
};

for (const c of cases('rounding')) {
  const r = (await db.query('select public.round_half_even($1::numeric)::text r', [c.value])).rows[0].r;
  ok(`round ${c.name}`, r === c.expected, r);
}

for (const c of cases('convert')) {
  try {
    const r = (await db.query('select public.convert_minor($1,$2,$3,$4::numeric)::text r', [c.amount_minor, c.from, c.to, c.rate])).rows[0].r;
    ok(`convert ${c.name}`, c.expected_minor !== undefined && r === String(c.expected_minor), r);
  } catch (e) {
    const code = e.message.includes('unsupported currency') ? 'unsupported_currency' : e.message.includes('rate') ? 'invalid_rate' : 'other';
    ok(`convert ${c.name}`, c.expected_error === code, e.message);
  }
}

for (const c of cases('shares')) {
  try {
    const rows = (await db.query(
      'select member_id::text m, share_minor::text s from public.compute_shares($1::bigint,$2::uuid[],$3::numeric[])',
      [String(c.total_minor), `{${c.members.join(',')}}`, `{${c.weights.join(',')}}`]
    )).rows;
    const got = Object.fromEntries(rows.map((r) => [r.m, Number(BigInt(r.s))]));
    ok(`shares ${c.name}`, c.expected && JSON.stringify(Object.entries(got).sort()) === JSON.stringify(Object.entries(c.expected).sort()), JSON.stringify(got));
  } catch (e) {
    ok(`shares ${c.name}`, c.expected_error === 'invalid_input', e.message);
  }
}

// Settlements: stand in for trip_balances (it needs a full trip) so the real
// simplified_settlements runs directly on the vectors.
await db.exec('create table _nets (member_id uuid, net_minor bigint)');
await db.exec('create or replace function public.trip_balances(p_trip uuid) returns table (member_id uuid, net_minor bigint) language sql stable as $$ select member_id, net_minor from _nets $$');
for (const c of cases('settlements')) {
  await db.exec('delete from _nets');
  for (const [m, v] of Object.entries(c.balances)) await db.query('insert into _nets values ($1,$2)', [m, v]);
  const rows = (await db.query('select from_member::text f, to_member::text t, amount_minor::text a from public.simplified_settlements(gen_random_uuid())')).rows;
  const got = rows.map((r) => ({ from: r.f, to: r.t, amount_minor: Number(r.a) }));
  ok(`settle ${c.name}`, JSON.stringify(got) === JSON.stringify(c.expected), JSON.stringify(got));
}

console.log(`${pass} passed, ${fail} failed`);
process.exit(fail ? 1 : 0);
