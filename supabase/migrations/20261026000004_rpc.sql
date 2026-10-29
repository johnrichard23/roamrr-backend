-- Roamrr backend, v0.1 (draft). RPC functions the app calls.
--
-- Error convention: our own validation errors use SQLSTATE 'RM001' (message is safe to
-- show the user). Permission failures use '42501'. Anything else is reported to the
-- client as 'internal error'.

-- Trips and membership ----------------------------------------------------------

create function public.create_trip(
  p_id uuid, p_name text, p_start date, p_end date, p_currency char
) returns uuid
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare
  v_uid uuid := (select auth.uid());
  v_name text;
begin
  if v_uid is null then
    raise exception 'not authenticated' using errcode = '28000';
  end if;
  if exists (select 1 from public.trips t where t.id = p_id) then
    if exists (select 1 from public.trips t where t.id = p_id and t.owner_id = v_uid) then
      return p_id; -- retry of a request that already succeeded
    end if;
    raise exception 'that trip id is already used' using errcode = 'RM001';
  end if;
  select p.display_name into v_name from public.profiles p where p.id = v_uid;
  insert into public.trips (id, name, start_date, end_date, home_currency, owner_id)
  values (p_id, btrim(p_name), p_start, p_end, upper(p_currency), v_uid);
  insert into public.trip_members (trip_id, user_id, display_name, role)
  values (p_id, v_uid, coalesce(v_name, 'Traveler'), 'owner');
  return p_id;
end;
$$;

create function public.update_trip(
  p_trip uuid, p_name text, p_start date, p_end date, p_status text,
  p_home_currency char default null
) returns void
language plpgsql security definer
set search_path = public, pg_temp
as $$
begin
  if not public.is_trip_owner(p_trip) then
    raise exception 'only the trip owner can change the trip' using errcode = '42501';
  end if;
  update public.trips t set
    name = btrim(p_name),
    start_date = p_start,
    end_date = p_end,
    status = p_status,
    home_currency = coalesce(upper(p_home_currency), t.home_currency)
  where t.id = p_trip and t.deleted_at is null;
end;
$$;

-- Invite codes use an alphabet without look-alike characters (no I, O, 0, 1).
-- Randomness comes from gen_random_uuid(), which is cryptographically random.
create function public.create_invite(p_trip uuid, p_claim_member uuid default null)
returns text
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare
  v_uid uuid := (select auth.uid());
  v_alphabet constant text := 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
  v_bytes bytea;
  v_code text;
  i integer;
begin
  if not public.is_trip_owner(p_trip) then
    raise exception 'only the trip owner can create invites' using errcode = '42501';
  end if;
  if p_claim_member is not null and not exists (
    select 1 from public.trip_members m
    where m.id = p_claim_member and m.trip_id = p_trip and m.user_id is null
  ) then
    raise exception 'that member is not an unclaimed placeholder' using errcode = 'RM001';
  end if;
  loop
    v_bytes := uuid_send(gen_random_uuid());
    v_code := '';
    for i in 0..7 loop
      v_code := v_code || substr(v_alphabet, 1 + (get_byte(v_bytes, i) % 32), 1);
    end loop;
    begin
      insert into public.trip_invites (trip_id, code, created_by, claim_member_id)
      values (p_trip, v_code, v_uid, p_claim_member);
      return v_code;
    exception when unique_violation then
      null; -- extremely unlikely collision; try a new code
    end;
  end loop;
end;
$$;

create function public.join_trip_by_invite(p_code text) returns uuid
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare
  v_uid uuid := (select auth.uid());
  v_inv public.trip_invites;
  v_member public.trip_members;
  v_name text;
  -- Maximum active members per trip.
  c_max_members constant integer := 20;
begin
  if v_uid is null then
    raise exception 'not authenticated' using errcode = '28000';
  end if;

  select * into v_inv from public.trip_invites i
  where i.code = upper(btrim(p_code)) for update;
  if not found or v_inv.revoked_at is not null or v_inv.expires_at <= now() then
    raise exception 'this invite is not valid' using errcode = 'RM001';
  end if;
  if not exists (
    select 1 from public.trips t
    where t.id = v_inv.trip_id and t.deleted_at is null and t.status <> 'archived'
  ) then
    raise exception 'this trip is no longer available' using errcode = 'RM001';
  end if;

  select * into v_member from public.trip_members m
  where m.trip_id = v_inv.trip_id and m.user_id = v_uid;

  if found then
    if v_member.status = 'active' then
      return v_inv.trip_id; -- already in; nothing to do
    elsif v_member.status = 'removed' then
      raise exception 'you cannot rejoin this trip' using errcode = 'RM001';
    end if;
    update public.trip_members set status = 'active' where id = v_member.id;
  else
    if v_inv.use_count >= v_inv.max_uses then
      raise exception 'this invite has been used up' using errcode = 'RM001';
    end if;
    if (select count(*) from public.trip_members m
        where m.trip_id = v_inv.trip_id and m.status = 'active') >= c_max_members then
      raise exception 'this trip is full' using errcode = 'RM001';
    end if;
    if v_inv.claim_member_id is not null then
      update public.trip_members
      set user_id = v_uid
      where id = v_inv.claim_member_id
        and trip_id = v_inv.trip_id
        and user_id is null
        and status = 'active';
      if not found then
        raise exception 'that spot on the trip was already claimed' using errcode = 'RM001';
      end if;
    else
      select p.display_name into v_name from public.profiles p where p.id = v_uid;
      insert into public.trip_members (trip_id, user_id, display_name)
      values (v_inv.trip_id, v_uid, coalesce(v_name, 'Traveler'));
    end if;
    update public.trip_invites set use_count = use_count + 1 where id = v_inv.id;
  end if;

  return v_inv.trip_id;
end;
$$;

create function public.add_placeholder_member(p_id uuid, p_trip uuid, p_name text)
returns uuid
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare
  c_max_members constant integer := 20;
begin
  if not public.is_trip_member(p_trip) then
    raise exception 'not a member of this trip' using errcode = '42501';
  end if;
  if exists (select 1 from public.trip_members m where m.id = p_id) then
    return p_id; -- retry
  end if;
  if (select count(*) from public.trip_members m
      where m.trip_id = p_trip and m.status = 'active') >= c_max_members then
    raise exception 'this trip is full' using errcode = 'RM001';
  end if;
  insert into public.trip_members (id, trip_id, display_name)
  values (p_id, p_trip, btrim(p_name));
  return p_id;
end;
$$;

create function public.leave_trip(p_trip uuid) returns void
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare
  v_uid uuid := (select auth.uid());
begin
  update public.trip_members
  set status = 'left'
  where trip_id = p_trip and user_id = v_uid and status = 'active' and role <> 'owner';
  if not found then
    raise exception 'you cannot leave this trip (you may own it)' using errcode = 'RM001';
  end if;
  update public.location_shares
  set enabled = false, expires_at = null, last_lat = null, last_lng = null,
      last_accuracy_m = null, last_seen_at = null, updated_at = now()
  where trip_id = p_trip and user_id = v_uid;
end;
$$;

create function public.remove_member(p_trip uuid, p_member uuid) returns void
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare
  v_user uuid;
begin
  if not public.is_trip_owner(p_trip) then
    raise exception 'only the trip owner can remove members' using errcode = '42501';
  end if;
  select m.user_id into v_user from public.trip_members m
  where m.id = p_member and m.trip_id = p_trip and m.role <> 'owner' and m.status = 'active';
  if not found then
    raise exception 'that member cannot be removed' using errcode = 'RM001';
  end if;
  update public.trip_members set status = 'removed' where id = p_member;
  if v_user is not null then
    update public.location_shares
    set enabled = false, expires_at = null, last_lat = null, last_lng = null,
        last_accuracy_m = null, last_seen_at = null, updated_at = now()
    where trip_id = p_trip and user_id = v_user;
  end if;
end;
$$;

-- Location ---------------------------------------------------------------------

create function public.set_location_sharing(
  p_trip uuid, p_enabled boolean, p_hours integer default 12
) returns void
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare
  v_uid uuid := (select auth.uid());
begin
  if not public.is_trip_member(p_trip) then
    raise exception 'not a member of this trip' using errcode = '42501';
  end if;
  if p_enabled and (p_hours is null or p_hours < 1 or p_hours > 72) then
    raise exception 'sharing can last between 1 and 72 hours' using errcode = 'RM001';
  end if;
  insert into public.location_shares (trip_id, user_id, enabled, expires_at, updated_at)
  values (
    p_trip, v_uid, p_enabled,
    case when p_enabled then now() + make_interval(hours => p_hours) end,
    now()
  )
  on conflict (trip_id, user_id) do update set
    enabled = excluded.enabled,
    expires_at = excluded.expires_at,
    last_lat = case when excluded.enabled then public.location_shares.last_lat end,
    last_lng = case when excluded.enabled then public.location_shares.last_lng end,
    last_accuracy_m = case when excluded.enabled then public.location_shares.last_accuracy_m end,
    last_seen_at = case when excluded.enabled then public.location_shares.last_seen_at end,
    updated_at = now();
end;
$$;

-- Returns true when the position was stored. Returns false (not an error) when sharing
-- is off or expired, or when the last update was less than 10 seconds ago.
create function public.upsert_last_location(
  p_trip uuid, p_lat double precision, p_lng double precision,
  p_accuracy_m real default null
) returns boolean
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare
  v_uid uuid := (select auth.uid());
  v_rows integer;
begin
  if not public.is_trip_member(p_trip) then
    raise exception 'not a member of this trip' using errcode = '42501';
  end if;
  if p_lat not between -90 and 90 or p_lng not between -180 and 180 then
    raise exception 'invalid coordinates' using errcode = 'RM001';
  end if;
  update public.location_shares s
  set last_lat = p_lat, last_lng = p_lng, last_accuracy_m = p_accuracy_m,
      last_seen_at = now(), updated_at = now()
  where s.trip_id = p_trip and s.user_id = v_uid
    and s.enabled and s.expires_at > now()
    and (s.last_seen_at is null or s.last_seen_at <= now() - interval '10 seconds');
  get diagnostics v_rows = row_count;
  return v_rows > 0;
end;
$$;

-- Called on a schedule (see 0006). Not granted to app users.
create function public.expire_location_shares() returns integer
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare
  v_rows integer;
begin
  update public.location_shares
  set enabled = false, expires_at = null, last_lat = null, last_lng = null,
      last_accuracy_m = null, last_seen_at = null, updated_at = now()
  where enabled and expires_at <= now();
  get diagnostics v_rows = row_count;
  return v_rows;
end;
$$;

create function public.prune_mutation_log() returns integer
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare
  v_rows integer;
begin
  delete from public.mutation_log where applied_at < now() - interval '30 days';
  get diagnostics v_rows = row_count;
  return v_rows;
end;
$$;

-- Mutation handlers (internal; only apply_mutations calls them) ------------------

create function public._assert_trip_writable(p_trip uuid) returns void
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare
  v_status text;
begin
  if not public.is_trip_member(p_trip) then
    raise exception 'not a member of this trip' using errcode = '42501';
  end if;
  select t.status into v_status from public.trips t
  where t.id = p_trip and t.deleted_at is null;
  if v_status is null then
    raise exception 'trip not found' using errcode = 'RM001';
  end if;
  if v_status = 'archived' then
    raise exception 'this trip is archived' using errcode = 'RM001';
  end if;
end;
$$;

create function public._snapshot_expense(p_id uuid, p_by uuid) returns void
language sql security definer
set search_path = public, pg_temp
as $$
  insert into public.expense_revisions (expense_id, version, snapshot, changed_by)
  select e.id, e.version,
    to_jsonb(e) || jsonb_build_object('shares', coalesce(
      (select jsonb_agg(to_jsonb(s)) from public.expense_shares s where s.expense_id = e.id),
      '[]'::jsonb)),
    p_by
  from public.expenses e where e.id = p_id;
$$;

create function public._apply_expense_upsert(p jsonb) returns void
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare
  v_uid uuid := (select auth.uid());
  v_id uuid := (p ->> 'id')::uuid;
  v_trip uuid := (p ->> 'trip_id')::uuid;
  v_payer uuid := (p ->> 'payer_member_id')::uuid;
  v_amount bigint := (p ->> 'amount_minor')::bigint;
  v_cur char(3) := upper(p ->> 'currency');
  v_split text := p ->> 'split_type';
  v_home char(3);
  v_rate numeric;
  v_source text;
  v_trip_amt bigint;
  v_ids uuid[];
  v_vals numeric[];
  v_weights numeric[];
  v_n integer;
  v_existing public.expenses;
begin
  perform public._assert_trip_writable(v_trip);
  select t.home_currency into v_home from public.trips t where t.id = v_trip;

  if v_id is null or v_amount is null or v_amount <= 0 then
    raise exception 'an expense needs an id and a positive amount' using errcode = 'RM001';
  end if;
  if not exists (
    select 1 from public.trip_members m where m.id = v_payer and m.trip_id = v_trip
  ) then
    raise exception 'the payer is not on this trip' using errcode = 'RM001';
  end if;
  if v_split is null or v_split not in ('equal', 'exact', 'percent', 'shares') then
    raise exception 'unknown split type' using errcode = 'RM001';
  end if;

  if v_cur = v_home then
    v_rate := 1;
    v_source := 'none';
  else
    v_rate := (p ->> 'fx_rate')::numeric;
    v_source := coalesce(p ->> 'fx_source', 'manual');
    if v_rate is null or v_rate <= 0 then
      raise exception 'an exchange rate is required for this currency' using errcode = 'RM001';
    end if;
    if v_source not in ('auto', 'manual') then
      raise exception 'unknown exchange rate source' using errcode = 'RM001';
    end if;
  end if;
  v_trip_amt := public.convert_minor(v_amount, v_cur, v_home, v_rate);
  if v_trip_amt <= 0 then
    raise exception 'that amount rounds to zero in the trip currency' using errcode = 'RM001';
  end if;

  select array_agg((s.val ->> 'member_id')::uuid order by (s.val ->> 'member_id')::uuid),
         array_agg((s.val ->> 'value')::numeric order by (s.val ->> 'member_id')::uuid)
    into v_ids, v_vals
  from jsonb_array_elements(coalesce(p -> 'splits', '[]'::jsonb)) as s(val);
  v_n := coalesce(array_length(v_ids, 1), 0);
  if v_n = 0 then
    raise exception 'choose at least one person to split with' using errcode = 'RM001';
  end if;
  if exists (select 1 from unnest(v_ids) x where x is null)
     or (select count(distinct x) from unnest(v_ids) x) <> v_n then
    raise exception 'each person can appear only once' using errcode = 'RM001';
  end if;
  if exists (
    select 1 from unnest(v_ids) x
    where not exists (
      select 1 from public.trip_members m where m.id = x and m.trip_id = v_trip
    )
  ) then
    raise exception 'someone in the split is not on this trip' using errcode = 'RM001';
  end if;

  if v_split = 'equal' then
    v_weights := array_fill(1::numeric, array[v_n]);
  else
    if exists (select 1 from unnest(v_vals) x where x is null or x <= 0) then
      raise exception 'split values must be greater than zero' using errcode = 'RM001';
    end if;
    v_weights := v_vals;
    if v_split = 'percent' and (select sum(x) from unnest(v_vals) x) <> 100 then
      raise exception 'percentages must add up to 100' using errcode = 'RM001';
    end if;
    if v_split = 'exact' and (select sum(x) from unnest(v_vals) x) <> v_amount then
      raise exception 'amounts must add up to the total' using errcode = 'RM001';
    end if;
  end if;

  select * into v_existing from public.expenses e where e.id = v_id for update;
  if found then
    if v_existing.trip_id <> v_trip then
      raise exception 'that expense belongs to another trip' using errcode = 'RM001';
    end if;
    if v_existing.deleted_at is not null then
      raise exception 'this expense was deleted' using errcode = 'RM001'; -- delete wins
    end if;
    if v_existing.created_by <> v_uid and not public.is_trip_owner(v_trip) then
      raise exception 'only the creator or the trip owner can edit this expense'
        using errcode = '42501';
    end if;
    perform public._snapshot_expense(v_id, v_uid);
    update public.expenses set
      payer_member_id = v_payer,
      description = btrim(p ->> 'description'),
      category = p ->> 'category',
      notes = p ->> 'notes',
      spent_on = (p ->> 'spent_on')::date,
      amount_minor = v_amount,
      currency = v_cur,
      fx_rate = v_rate,
      fx_source = v_source,
      amount_trip_minor = v_trip_amt,
      split_type = v_split,
      version = v_existing.version + 1
    where id = v_id;
    delete from public.expense_shares where expense_id = v_id;
  else
    insert into public.expenses (
      id, trip_id, payer_member_id, description, category, notes, spent_on,
      amount_minor, currency, fx_rate, fx_source, amount_trip_minor, split_type, created_by
    ) values (
      v_id, v_trip, v_payer, btrim(p ->> 'description'), p ->> 'category', p ->> 'notes',
      (p ->> 'spent_on')::date, v_amount, v_cur, v_rate, v_source, v_trip_amt, v_split, v_uid
    );
  end if;

  insert into public.expense_shares (expense_id, member_id, split_value, share_minor)
  select v_id, cs.member_id,
         case when v_split = 'equal' then 1 else v.val end,
         cs.share_minor
  from public.compute_shares(v_trip_amt, v_ids, v_weights) cs
  join unnest(v_ids, v_vals) as v(mid, val) on v.mid = cs.member_id;

  perform public._assert_expense_balanced(v_id);
end;
$$;

create function public._apply_expense_delete(p jsonb) returns void
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare
  v_uid uuid := (select auth.uid());
  v_existing public.expenses;
begin
  select * into v_existing from public.expenses e
  where e.id = (p ->> 'id')::uuid for update;
  if not found then
    raise exception 'expense not found' using errcode = 'RM001';
  end if;
  if not public.is_trip_member(v_existing.trip_id) then
    raise exception 'not a member of this trip' using errcode = '42501';
  end if;
  if v_existing.deleted_at is not null then
    return; -- already deleted
  end if;
  if v_existing.created_by <> v_uid and not public.is_trip_owner(v_existing.trip_id) then
    raise exception 'only the creator or the trip owner can delete this expense'
      using errcode = '42501';
  end if;
  perform public._snapshot_expense(v_existing.id, v_uid);
  update public.expenses
  set deleted_at = now(), version = v_existing.version + 1
  where id = v_existing.id;
end;
$$;

create function public._apply_settlement_upsert(p jsonb) returns void
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare
  v_uid uuid := (select auth.uid());
  v_id uuid := (p ->> 'id')::uuid;
  v_trip uuid := (p ->> 'trip_id')::uuid;
  v_from uuid := (p ->> 'from_member_id')::uuid;
  v_to uuid := (p ->> 'to_member_id')::uuid;
  v_amount bigint := (p ->> 'amount_minor')::bigint;
  v_existing public.settlements;
begin
  perform public._assert_trip_writable(v_trip);
  if v_id is null or v_amount is null or v_amount <= 0 then
    raise exception 'a payment needs an id and a positive amount' using errcode = 'RM001';
  end if;
  if v_from is null or v_to is null or v_from = v_to then
    raise exception 'choose two different people' using errcode = 'RM001';
  end if;
  if (select count(*) from public.trip_members m
      where m.trip_id = v_trip and m.id in (v_from, v_to)) <> 2 then
    raise exception 'both people must be on this trip' using errcode = 'RM001';
  end if;

  select * into v_existing from public.settlements s where s.id = v_id for update;
  if found then
    if v_existing.trip_id <> v_trip then
      raise exception 'that payment belongs to another trip' using errcode = 'RM001';
    end if;
    if v_existing.deleted_at is not null then
      raise exception 'this payment was deleted' using errcode = 'RM001';
    end if;
    if v_existing.created_by <> v_uid and not public.is_trip_owner(v_trip) then
      raise exception 'only the creator or the trip owner can edit this payment'
        using errcode = '42501';
    end if;
    update public.settlements set
      from_member_id = v_from, to_member_id = v_to, amount_minor = v_amount,
      method = p ->> 'method', note = p ->> 'note', settled_on = (p ->> 'settled_on')::date
    where id = v_id;
  else
    insert into public.settlements (
      id, trip_id, from_member_id, to_member_id, amount_minor, method, note, settled_on,
      created_by
    ) values (
      v_id, v_trip, v_from, v_to, v_amount, p ->> 'method', p ->> 'note',
      (p ->> 'settled_on')::date, v_uid
    );
  end if;
end;
$$;

create function public._apply_settlement_delete(p jsonb) returns void
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare
  v_uid uuid := (select auth.uid());
  v_existing public.settlements;
begin
  select * into v_existing from public.settlements s
  where s.id = (p ->> 'id')::uuid for update;
  if not found then
    raise exception 'payment not found' using errcode = 'RM001';
  end if;
  if not public.is_trip_member(v_existing.trip_id) then
    raise exception 'not a member of this trip' using errcode = '42501';
  end if;
  if v_existing.deleted_at is not null then
    return;
  end if;
  if v_existing.created_by <> v_uid and not public.is_trip_owner(v_existing.trip_id) then
    raise exception 'only the creator or the trip owner can delete this payment'
      using errcode = '42501';
  end if;
  update public.settlements set deleted_at = now() where id = v_existing.id;
end;
$$;

create function public._apply_place_upsert(p jsonb) returns void
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare
  v_uid uuid := (select auth.uid());
  v_id uuid := (p ->> 'id')::uuid;
  v_trip uuid := (p ->> 'trip_id')::uuid;
  v_existing public.places;
begin
  perform public._assert_trip_writable(v_trip);
  if v_id is null then
    raise exception 'a place needs an id' using errcode = 'RM001';
  end if;
  select * into v_existing from public.places x where x.id = v_id for update;
  if found then
    if v_existing.trip_id <> v_trip then
      raise exception 'that place belongs to another trip' using errcode = 'RM001';
    end if;
    if v_existing.deleted_at is not null then
      raise exception 'this place was removed' using errcode = 'RM001';
    end if;
    update public.places set
      name = btrim(p ->> 'name'),
      latitude = (p ->> 'latitude')::double precision,
      longitude = (p ->> 'longitude')::double precision,
      address = p ->> 'address', category = p ->> 'category', notes = p ->> 'notes'
    where id = v_id;
  else
    insert into public.places (
      id, trip_id, name, latitude, longitude, address, category, notes, source, added_by
    ) values (
      v_id, v_trip, btrim(p ->> 'name'),
      (p ->> 'latitude')::double precision, (p ->> 'longitude')::double precision,
      p ->> 'address', p ->> 'category', p ->> 'notes',
      coalesce(p ->> 'source', 'mapkit'), v_uid
    );
  end if;
end;
$$;

create function public._apply_place_delete(p jsonb) returns void
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare
  v_existing public.places;
begin
  select * into v_existing from public.places x
  where x.id = (p ->> 'id')::uuid for update;
  if not found then
    raise exception 'place not found' using errcode = 'RM001';
  end if;
  if not public.is_trip_member(v_existing.trip_id) then
    raise exception 'not a member of this trip' using errcode = '42501';
  end if;
  update public.places set deleted_at = coalesce(deleted_at, now()) where id = v_existing.id;
end;
$$;

create function public._apply_album_link_upsert(p jsonb) returns void
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare
  v_uid uuid := (select auth.uid());
  v_id uuid := (p ->> 'id')::uuid;
  v_trip uuid := (p ->> 'trip_id')::uuid;
  v_url text := btrim(p ->> 'url');
  v_existing public.trip_album_links;
begin
  perform public._assert_trip_writable(v_trip);
  if v_id is null then
    raise exception 'a link needs an id' using errcode = 'RM001';
  end if;
  if v_url is null or v_url !~ '^https://[^[:space:]]+$' or char_length(v_url) > 2048 then
    raise exception 'enter a valid https link' using errcode = 'RM001';
  end if;
  select * into v_existing from public.trip_album_links l where l.id = v_id for update;
  if found then
    if v_existing.trip_id <> v_trip then
      raise exception 'that link belongs to another trip' using errcode = 'RM001';
    end if;
    if v_existing.deleted_at is not null then
      raise exception 'this link was removed' using errcode = 'RM001';
    end if;
    if v_existing.added_by <> v_uid and not public.is_trip_owner(v_trip) then
      raise exception 'only the person who added a link or the trip owner can edit it'
        using errcode = '42501';
    end if;
    update public.trip_album_links
    set url = v_url, label = btrim(p ->> 'label')
    where id = v_id;
  else
    insert into public.trip_album_links (id, trip_id, url, label, added_by)
    values (v_id, v_trip, v_url, btrim(p ->> 'label'), v_uid);
  end if;
end;
$$;

create function public._apply_album_link_delete(p jsonb) returns void
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare
  v_uid uuid := (select auth.uid());
  v_existing public.trip_album_links;
begin
  select * into v_existing from public.trip_album_links l
  where l.id = (p ->> 'id')::uuid for update;
  if not found then
    raise exception 'link not found' using errcode = 'RM001';
  end if;
  if not public.is_trip_member(v_existing.trip_id) then
    raise exception 'not a member of this trip' using errcode = '42501';
  end if;
  if v_existing.deleted_at is not null then
    return;
  end if;
  if v_existing.added_by <> v_uid and not public.is_trip_owner(v_existing.trip_id) then
    raise exception 'only the person who added a link or the trip owner can remove it'
      using errcode = '42501';
  end if;
  update public.trip_album_links set deleted_at = now() where id = v_existing.id;
end;
$$;

create function public._dispatch_mutation(m jsonb) returns void
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare
  v_key text := (m ->> 'entity') || '.' || (m ->> 'op');
  v_payload jsonb := m -> 'payload';
begin
  case v_key
    when 'expense.upsert' then perform public._apply_expense_upsert(v_payload);
    when 'expense.delete' then perform public._apply_expense_delete(v_payload);
    when 'settlement.upsert' then perform public._apply_settlement_upsert(v_payload);
    when 'settlement.delete' then perform public._apply_settlement_delete(v_payload);
    when 'place.upsert' then perform public._apply_place_upsert(v_payload);
    when 'place.delete' then perform public._apply_place_delete(v_payload);
    when 'album_link.upsert' then perform public._apply_album_link_upsert(v_payload);
    when 'album_link.delete' then perform public._apply_album_link_delete(v_payload);
    else raise exception 'unknown mutation %', coalesce(v_key, 'null') using errcode = 'RM001';
  end case;
end;
$$;

-- The app's write path. Takes an array of
--   { mutation_id, entity, op, payload }
-- and applies each one in its own subtransaction, in order. A mutation that was already
-- applied is answered from mutation_log instead of being applied again, so a retried
-- batch is always safe. Returns one result object per mutation.
create function public.apply_mutations(p_mutations jsonb) returns jsonb
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare
  v_uid uuid := (select auth.uid());
  m jsonb;
  v_id uuid;
  v_logged jsonb;
  v_result jsonb;
  v_results jsonb := '[]'::jsonb;
begin
  if v_uid is null then
    raise exception 'not authenticated' using errcode = '28000';
  end if;
  if jsonb_typeof(p_mutations) is distinct from 'array'
     or jsonb_array_length(p_mutations) > 100 then
    raise exception 'send an array of at most 100 mutations' using errcode = 'RM001';
  end if;

  for m in select value from jsonb_array_elements(p_mutations) loop
    v_id := (m ->> 'mutation_id')::uuid;
    if v_id is null then
      raise exception 'every mutation needs a mutation_id' using errcode = 'RM001';
    end if;

    select l.result into v_logged from public.mutation_log l
    where l.mutation_id = v_id and l.user_id = v_uid;
    if found then
      v_results := v_results || jsonb_build_array(v_logged || jsonb_build_object('duplicate', true));
      continue;
    end if;

    begin
      perform public._dispatch_mutation(m);
      v_result := jsonb_build_object('mutation_id', v_id, 'status', 'applied');
    exception when others then
      if sqlstate in ('40001', '40P01') then
        raise; -- transient; let the client retry the whole batch
      end if;
      v_result := jsonb_build_object(
        'mutation_id', v_id,
        'status', 'rejected',
        'code', sqlstate,
        'error', case when sqlstate in ('RM001', '42501') then sqlerrm else 'internal error' end
      );
    end;

    insert into public.mutation_log (mutation_id, user_id, entity, operation, result)
    values (v_id, v_uid, coalesce(m ->> 'entity', ''), coalesce(m ->> 'op', ''), v_result)
    on conflict (mutation_id) do nothing;

    v_results := v_results || jsonb_build_array(v_result);
  end loop;

  return v_results;
end;
$$;

-- Pull ---------------------------------------------------------------------------

-- Everything in a trip that changed after p_since (a server_seq), newest page last.
-- Deleted rows come back with deleted_at set so clients can remove them.
-- p_since_ts adds a time-based overlap: the first page of a sync also returns rows
-- updated after that time, because a sequence number can be assigned to a transaction
-- that commits after a later one. Clients apply rows idempotently by id.
-- Pass p_since_ts only on the first page of a sync.
create function public.pull_changes(
  p_trip uuid, p_since bigint default 0, p_since_ts timestamptz default null,
  p_limit integer default 500
) returns jsonb
language plpgsql stable security definer
set search_path = public, pg_temp
as $$
declare
  v_limit integer := least(greatest(coalesce(p_limit, 500), 1), 1000);
  v_since bigint := coalesce(p_since, 0);
  v_page jsonb;
begin
  if not public.is_trip_member(p_trip) then
    raise exception 'not a member of this trip' using errcode = '42501';
  end if;

  with changed as (
    select 'trip'::text as t, x.id, x.server_seq from public.trips x
      where x.id = p_trip
        and (x.server_seq > v_since or (p_since_ts is not null and x.updated_at > p_since_ts))
    union all
    select 'member', x.id, x.server_seq from public.trip_members x
      where x.trip_id = p_trip
        and (x.server_seq > v_since or (p_since_ts is not null and x.updated_at > p_since_ts))
    union all
    select 'expense', x.id, x.server_seq from public.expenses x
      where x.trip_id = p_trip
        and (x.server_seq > v_since or (p_since_ts is not null and x.updated_at > p_since_ts))
    union all
    select 'settlement', x.id, x.server_seq from public.settlements x
      where x.trip_id = p_trip
        and (x.server_seq > v_since or (p_since_ts is not null and x.updated_at > p_since_ts))
    union all
    select 'place', x.id, x.server_seq from public.places x
      where x.trip_id = p_trip
        and (x.server_seq > v_since or (p_since_ts is not null and x.updated_at > p_since_ts))
    union all
    select 'album_link', x.id, x.server_seq from public.trip_album_links x
      where x.trip_id = p_trip
        and (x.server_seq > v_since or (p_since_ts is not null and x.updated_at > p_since_ts))
  ),
  page as (
    select c.t, c.id, c.server_seq from changed c order by c.server_seq limit v_limit
  )
  select jsonb_build_object(
    'trips', coalesce((select jsonb_agg(to_jsonb(x)) from public.trips x
      join page p on p.t = 'trip' and p.id = x.id), '[]'::jsonb),
    'members', coalesce((select jsonb_agg(to_jsonb(x)) from public.trip_members x
      join page p on p.t = 'member' and p.id = x.id), '[]'::jsonb),
    'expenses', coalesce((select jsonb_agg(
        to_jsonb(x) || jsonb_build_object('shares', coalesce(
          (select jsonb_agg(to_jsonb(s)) from public.expense_shares s where s.expense_id = x.id),
          '[]'::jsonb)))
      from public.expenses x join page p on p.t = 'expense' and p.id = x.id), '[]'::jsonb),
    'settlements', coalesce((select jsonb_agg(to_jsonb(x)) from public.settlements x
      join page p on p.t = 'settlement' and p.id = x.id), '[]'::jsonb),
    'places', coalesce((select jsonb_agg(to_jsonb(x)) from public.places x
      join page p on p.t = 'place' and p.id = x.id), '[]'::jsonb),
    'album_links', coalesce((select jsonb_agg(to_jsonb(x)) from public.trip_album_links x
      join page p on p.t = 'album_link' and p.id = x.id), '[]'::jsonb),
    'max_seq', coalesce((select max(p.server_seq) from page p), v_since),
    'has_more', (select count(*) from changed) > v_limit,
    'server_time', now()
  ) into v_page;

  return v_page;
end;
$$;
