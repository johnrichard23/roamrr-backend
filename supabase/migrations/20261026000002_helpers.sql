-- Roamrr backend, v0.1 (draft). Triggers and authorization helpers.

-- Sync bookkeeping -------------------------------------------------------------

-- Every synced row gets a new global sequence number on each insert or update.
-- Clients pull "everything after the last server_seq I saw", so a wrong device
-- clock cannot break ordering.
create function public.touch_row() returns trigger
language plpgsql
set search_path = public, pg_temp
as $$
begin
  new.updated_at := now();
  new.server_seq := nextval('public.server_seq_seq');
  return new;
end;
$$;

create trigger profiles_touch before insert or update on public.profiles
  for each row execute function public.touch_row();
create trigger trips_touch before insert or update on public.trips
  for each row execute function public.touch_row();
create trigger trip_members_touch before insert or update on public.trip_members
  for each row execute function public.touch_row();
create trigger expenses_touch before insert or update on public.expenses
  for each row execute function public.touch_row();
create trigger settlements_touch before insert or update on public.settlements
  for each row execute function public.touch_row();
create trigger places_touch before insert or update on public.places
  for each row execute function public.touch_row();
create trigger trip_album_links_touch before insert or update on public.trip_album_links
  for each row execute function public.touch_row();

-- A trip's home currency cannot change once it has expenses or settlements.
create function public.lock_trip_currency() returns trigger
language plpgsql
set search_path = public, pg_temp
as $$
begin
  if new.home_currency <> old.home_currency and (
    exists (select 1 from public.expenses e where e.trip_id = old.id)
    or exists (select 1 from public.settlements s where s.trip_id = old.id)
  ) then
    raise exception 'home currency cannot change after expenses exist' using errcode = 'RM001';
  end if;
  return new;
end;
$$;

create trigger trips_lock_currency before update on public.trips
  for each row execute function public.lock_trip_currency();

-- Authorization helpers --------------------------------------------------------
-- SECURITY DEFINER so policies on trip_members do not recurse into themselves.
-- They only ever answer questions about the calling user.

create function public.is_trip_member(p_trip uuid) returns boolean
language sql stable security definer
set search_path = public, pg_temp
as $$
  select exists (
    select 1 from public.trip_members m
    where m.trip_id = p_trip
      and m.user_id = (select auth.uid())
      and m.status = 'active'
  );
$$;

create function public.is_trip_owner(p_trip uuid) returns boolean
language sql stable security definer
set search_path = public, pg_temp
as $$
  select exists (
    select 1 from public.trip_members m
    where m.trip_id = p_trip
      and m.user_id = (select auth.uid())
      and m.role = 'owner'
      and m.status = 'active'
  );
$$;

create function public.my_member_id(p_trip uuid) returns uuid
language sql stable security definer
set search_path = public, pg_temp
as $$
  select m.id from public.trip_members m
  where m.trip_id = p_trip
    and m.user_id = (select auth.uid())
    and m.status = 'active';
$$;

-- True when the caller and p_user are both active members of at least one trip.
create function public.shares_trip_with(p_user uuid) returns boolean
language sql stable security definer
set search_path = public, pg_temp
as $$
  select exists (
    select 1
    from public.trip_members a
    join public.trip_members b on b.trip_id = a.trip_id
    where a.user_id = (select auth.uid())
      and a.status = 'active'
      and b.user_id = p_user
      and b.status = 'active'
  );
$$;

create function public.is_blocked_between(p_a uuid, p_b uuid) returns boolean
language sql stable security definer
set search_path = public, pg_temp
as $$
  select exists (
    select 1 from public.blocks b
    where (b.blocker_id = p_a and b.blocked_id = p_b)
       or (b.blocker_id = p_b and b.blocked_id = p_a)
  );
$$;

-- Realtime topic names look like 'trip:<uuid>:location'. Returns null when malformed.
create function public.trip_id_from_topic(p_topic text) returns uuid
language sql immutable
set search_path = public, pg_temp
as $$
  select case
    when p_topic ~ '^trip:[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}:[a-z]+$'
    then split_part(p_topic, ':', 2)::uuid
    else null
  end;
$$;

-- New sign-ins -----------------------------------------------------------------

-- Creates a profile for every new auth user. Email is deliberately not copied: it may
-- be missing (phone-only Facebook accounts) and lives in auth.users.
create function public.handle_new_user() returns trigger
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare
  v_name text;
begin
  v_name := left(btrim(coalesce(
    new.raw_user_meta_data ->> 'full_name',
    new.raw_user_meta_data ->> 'name',
    ''
  )), 60);
  if v_name = '' then
    v_name := 'Traveler';
  end if;
  insert into public.profiles (id, display_name) values (new.id, v_name);
  return new;
end;
$$;

create trigger on_auth_user_created after insert on auth.users
  for each row execute function public.handle_new_user();
