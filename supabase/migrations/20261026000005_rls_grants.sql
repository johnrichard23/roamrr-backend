-- Roamrr backend, v0.1 (draft). Row Level Security and grants.
--
-- Supabase grants new tables and functions in `public` to the anon and authenticated
-- roles by default, so everything is revoked first and then granted back explicitly.
-- Writes to money and trip data go through the RPC functions in 0004, never directly.

alter default privileges in schema public revoke all on tables from anon, authenticated;
alter default privileges in schema public revoke all on sequences from anon, authenticated;
alter default privileges in schema public revoke execute on functions from public, anon, authenticated;

revoke all on all tables in schema public from anon, authenticated;
revoke all on all sequences in schema public from anon, authenticated;
revoke execute on all functions in schema public from public, anon, authenticated;

alter table public.currencies enable row level security;
alter table public.fx_rates enable row level security;
alter table public.profiles enable row level security;
alter table public.trips enable row level security;
alter table public.trip_members enable row level security;
alter table public.trip_invites enable row level security;
alter table public.expenses enable row level security;
alter table public.expense_shares enable row level security;
alter table public.expense_revisions enable row level security;
alter table public.settlements enable row level security;
alter table public.location_shares enable row level security;
alter table public.places enable row level security;
alter table public.trip_album_links enable row level security;
alter table public.device_tokens enable row level security;
alter table public.notification_prefs enable row level security;
alter table public.entitlements enable row level security;
alter table public.blocks enable row level security;
alter table public.reports enable row level security;
alter table public.mutation_log enable row level security; -- no policies: unreadable by clients

-- Table privileges ------------------------------------------------------------

grant select on
  public.currencies, public.fx_rates, public.profiles, public.trips, public.trip_members,
  public.trip_invites, public.expenses, public.expense_shares, public.expense_revisions,
  public.settlements, public.location_shares, public.places, public.trip_album_links,
  public.entitlements, public.blocks
to authenticated;

grant update (display_name, avatar_color, locale, preferred_currency)
  on public.profiles to authenticated;
grant select, insert, update, delete on public.device_tokens to authenticated;
grant select, insert, update, delete on public.notification_prefs to authenticated;
grant insert, delete on public.blocks to authenticated;
grant insert on public.reports to authenticated;

-- Policies --------------------------------------------------------------------
-- `(select auth.uid())` is wrapped in a select so Postgres evaluates it once per query.

create policy currencies_read on public.currencies
  for select to authenticated using (true);

create policy fx_rates_read on public.fx_rates
  for select to authenticated using (true);

create policy profiles_read on public.profiles
  for select to authenticated
  using (id = (select auth.uid()) or public.shares_trip_with(id));

create policy profiles_update_own on public.profiles
  for update to authenticated
  using (id = (select auth.uid()))
  with check (id = (select auth.uid()));

create policy trips_read on public.trips
  for select to authenticated using (public.is_trip_member(id));

create policy trip_members_read on public.trip_members
  for select to authenticated using (public.is_trip_member(trip_id));

create policy trip_invites_read on public.trip_invites
  for select to authenticated using (public.is_trip_member(trip_id));

create policy expenses_read on public.expenses
  for select to authenticated using (public.is_trip_member(trip_id));

create policy expense_shares_read on public.expense_shares
  for select to authenticated
  using (exists (
    select 1 from public.expenses e
    where e.id = expense_id and public.is_trip_member(e.trip_id)
  ));

create policy expense_revisions_read on public.expense_revisions
  for select to authenticated
  using (exists (
    select 1 from public.expenses e
    where e.id = expense_id and public.is_trip_member(e.trip_id)
  ));

create policy settlements_read on public.settlements
  for select to authenticated using (public.is_trip_member(trip_id));

create policy places_read on public.places
  for select to authenticated using (public.is_trip_member(trip_id));

create policy trip_album_links_read on public.trip_album_links
  for select to authenticated using (public.is_trip_member(trip_id));

-- You can always see your own row. Others see a position only while sharing is on,
-- unexpired, within the same trip, and not blocked in either direction.
create policy location_shares_read on public.location_shares
  for select to authenticated
  using (
    user_id = (select auth.uid())
    or (
      enabled
      and expires_at > now()
      and public.is_trip_member(trip_id)
      and not public.is_blocked_between((select auth.uid()), user_id)
    )
  );

create policy device_tokens_own on public.device_tokens
  for all to authenticated
  using (user_id = (select auth.uid()))
  with check (user_id = (select auth.uid()));

create policy notification_prefs_own on public.notification_prefs
  for all to authenticated
  using (user_id = (select auth.uid()))
  with check (user_id = (select auth.uid()));

create policy entitlements_read_own on public.entitlements
  for select to authenticated using (user_id = (select auth.uid()));

create policy blocks_read_own on public.blocks
  for select to authenticated using (blocker_id = (select auth.uid()));
create policy blocks_insert_own on public.blocks
  for insert to authenticated with check (blocker_id = (select auth.uid()));
create policy blocks_delete_own on public.blocks
  for delete to authenticated using (blocker_id = (select auth.uid()));

create policy reports_insert_own on public.reports
  for insert to authenticated
  with check (
    reporter_id = (select auth.uid())
    and (trip_id is null or public.is_trip_member(trip_id))
  );

-- Function privileges -----------------------------------------------------------
-- Helpers used inside policies must be callable by the signed-in role.

grant execute on function
  public.is_trip_member(uuid),
  public.is_trip_owner(uuid),
  public.my_member_id(uuid),
  public.shares_trip_with(uuid),
  public.is_blocked_between(uuid, uuid),
  public.trip_id_from_topic(text),
  public.round_half_even(numeric),
  public.currency_exponent(char),
  public.convert_minor(bigint, char, char, numeric),
  public.compute_shares(bigint, uuid[], numeric[]),
  public.trip_balances(uuid),
  public.simplified_settlements(uuid),
  public.create_trip(uuid, text, date, date, char),
  public.update_trip(uuid, text, date, date, text, char),
  public.create_invite(uuid, uuid),
  public.join_trip_by_invite(text),
  public.add_placeholder_member(uuid, uuid, text),
  public.leave_trip(uuid),
  public.remove_member(uuid, uuid),
  public.set_location_sharing(uuid, boolean, integer),
  public.upsert_last_location(uuid, double precision, double precision, real),
  public.apply_mutations(jsonb),
  public.pull_changes(uuid, bigint, timestamptz, integer)
to authenticated;

-- Not granted to app users: handle_new_user, touch_row, lock_trip_currency,
-- expire_location_shares, prune_mutation_log, and every function whose name starts
-- with an underscore.
