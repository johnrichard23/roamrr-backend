-- Roamrr backend schema, v0.1 (draft). Target: Postgres 15+ on Supabase.
-- Tables only. Helpers, money logic, RPC, and RLS live in the later files.
-- All money is integer minor units plus an ISO 4217 code. Never floating point.

create sequence public.server_seq_seq as bigint;

-- Reference data ---------------------------------------------------------------

create table public.currencies (
  code char(3) primary key check (code = upper(code)),
  name text not null,
  minor_unit smallint not null check (minor_unit between 0 and 4)
);

insert into public.currencies (code, name, minor_unit) values
  ('PHP', 'Philippine peso', 2),
  ('USD', 'US dollar', 2),
  ('EUR', 'Euro', 2),
  ('JPY', 'Japanese yen', 0),
  ('KRW', 'South Korean won', 0),
  ('SGD', 'Singapore dollar', 2),
  ('HKD', 'Hong Kong dollar', 2),
  ('THB', 'Thai baht', 2),
  ('VND', 'Vietnamese dong', 0),
  ('IDR', 'Indonesian rupiah', 2),
  ('MYR', 'Malaysian ringgit', 2),
  ('TWD', 'New Taiwan dollar', 2),
  ('CNY', 'Chinese yuan', 2),
  ('AUD', 'Australian dollar', 2),
  ('GBP', 'Pound sterling', 2),
  ('CAD', 'Canadian dollar', 2),
  ('AED', 'UAE dirham', 2),
  ('SAR', 'Saudi riyal', 2),
  ('CHF', 'Swiss franc', 2),
  ('KWD', 'Kuwaiti dinar', 3);

-- fx_rates holds cached rates from the exchange-rate provider (written by an Edge Function).
-- rate = units of quote currency per 1 unit of base currency.
create table public.fx_rates (
  base char(3) not null references public.currencies (code),
  quote char(3) not null references public.currencies (code),
  rate numeric(24, 12) not null check (rate > 0),
  as_of date not null,
  fetched_at timestamptz not null default now(),
  primary key (base, quote, as_of)
);

-- People -----------------------------------------------------------------------

create table public.profiles (
  id uuid primary key references auth.users (id) on delete cascade,
  display_name text not null check (char_length(display_name) between 1 and 60),
  -- No hosted avatars. The app draws initials on this colour.
  avatar_color text check (avatar_color ~ '^#[0-9A-Fa-f]{6}$'),
  locale text not null default 'en',
  preferred_currency char(3) not null default 'PHP' references public.currencies (code),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  deleted_at timestamptz,
  server_seq bigint not null default nextval('public.server_seq_seq')
);

-- Trips ------------------------------------------------------------------------

create table public.trips (
  id uuid primary key default gen_random_uuid(),
  name text not null check (char_length(name) between 1 and 80),
  start_date date,
  end_date date,
  home_currency char(3) not null references public.currencies (code),
  owner_id uuid not null references public.profiles (id),
  status text not null default 'planned'
    check (status in ('planned', 'active', 'ended', 'archived')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  deleted_at timestamptz,
  server_seq bigint not null default nextval('public.server_seq_seq'),
  check (start_date is null or end_date is null or end_date >= start_date)
);

-- A member is a person on a trip. user_id is null for a placeholder: a friend who
-- is not on the app yet. A placeholder can be claimed later through an invite.
create table public.trip_members (
  id uuid primary key default gen_random_uuid(),
  trip_id uuid not null references public.trips (id) on delete cascade,
  user_id uuid references public.profiles (id),
  display_name text not null check (char_length(display_name) between 1 and 60),
  role text not null default 'member' check (role in ('owner', 'member')),
  status text not null default 'active' check (status in ('active', 'left', 'removed')),
  joined_at timestamptz not null default now(),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  server_seq bigint not null default nextval('public.server_seq_seq')
);

create unique index trip_members_trip_user_key
  on public.trip_members (trip_id, user_id) where user_id is not null;
create unique index trip_members_one_owner
  on public.trip_members (trip_id) where role = 'owner' and status = 'active';
create index trip_members_user_idx
  on public.trip_members (user_id) where status = 'active';
create index trip_members_seq_idx on public.trip_members (trip_id, server_seq);

create table public.trip_invites (
  id uuid primary key default gen_random_uuid(),
  trip_id uuid not null references public.trips (id) on delete cascade,
  code text not null unique check (code ~ '^[A-HJ-NP-Z2-9]{8}$'),
  created_by uuid not null references public.profiles (id),
  -- When set, joining with this invite takes over that placeholder member.
  claim_member_id uuid references public.trip_members (id),
  expires_at timestamptz not null default now() + interval '7 days',
  max_uses integer not null default 20 check (max_uses between 1 and 100),
  use_count integer not null default 0 check (use_count >= 0),
  revoked_at timestamptz,
  created_at timestamptz not null default now()
);

create index trip_invites_trip_idx on public.trip_invites (trip_id);

-- Expenses ---------------------------------------------------------------------

-- Clients choose the id so an offline-created expense keeps it after sync.
-- amount_minor is in `currency`. amount_trip_minor is the same amount in the trip's
-- home currency, computed by the server. fx_rate = home-currency units per 1 unit of
-- `currency`, and is 1 when the currency equals the home currency.
create table public.expenses (
  id uuid primary key,
  trip_id uuid not null references public.trips (id) on delete cascade,
  payer_member_id uuid not null references public.trip_members (id),
  description text not null check (char_length(description) between 1 and 120),
  category text check (char_length(category) <= 30),
  notes text check (char_length(notes) <= 500),
  spent_on date not null,
  amount_minor bigint not null check (amount_minor > 0),
  currency char(3) not null references public.currencies (code),
  fx_rate numeric(24, 12) not null default 1 check (fx_rate > 0),
  fx_source text not null default 'none' check (fx_source in ('none', 'auto', 'manual')),
  amount_trip_minor bigint not null check (amount_trip_minor > 0),
  split_type text not null check (split_type in ('equal', 'exact', 'percent', 'shares')),
  version integer not null default 1,
  created_by uuid not null references public.profiles (id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  deleted_at timestamptz,
  server_seq bigint not null default nextval('public.server_seq_seq')
);

create index expenses_trip_date_idx on public.expenses (trip_id, spent_on desc);
create index expenses_trip_seq_idx on public.expenses (trip_id, server_seq);

-- split_value is what the user entered: 1 for equal, the percent, the share count, or
-- the exact amount in minor units of the expense currency. share_minor is the amount
-- this member owes, in the trip's home currency, as computed by the server.
create table public.expense_shares (
  expense_id uuid not null references public.expenses (id) on delete cascade,
  member_id uuid not null references public.trip_members (id),
  split_value numeric(20, 6) not null check (split_value > 0),
  share_minor bigint not null check (share_minor >= 0),
  primary key (expense_id, member_id)
);

create index expense_shares_member_idx on public.expense_shares (member_id);

-- One row per edit or delete, holding the previous state (including its shares).
create table public.expense_revisions (
  id bigint generated always as identity primary key,
  expense_id uuid not null references public.expenses (id) on delete cascade,
  version integer not null,
  snapshot jsonb not null,
  changed_by uuid references public.profiles (id),
  changed_at timestamptz not null default now()
);

create index expense_revisions_expense_idx on public.expense_revisions (expense_id, version);

-- A recorded payment between two members, in the trip's home currency.
-- The app records it; no money moves through Roamrr.
create table public.settlements (
  id uuid primary key,
  trip_id uuid not null references public.trips (id) on delete cascade,
  from_member_id uuid not null references public.trip_members (id),
  to_member_id uuid not null references public.trip_members (id),
  amount_minor bigint not null check (amount_minor > 0),
  method text check (char_length(method) <= 30),
  note text check (char_length(note) <= 200),
  settled_on date not null,
  created_by uuid not null references public.profiles (id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  deleted_at timestamptz,
  server_seq bigint not null default nextval('public.server_seq_seq'),
  check (from_member_id <> to_member_id)
);

create index settlements_trip_seq_idx on public.settlements (trip_id, server_seq);

-- Location ---------------------------------------------------------------------

-- Only the last known position is stored (no history). Rows are cleared on expiry.
create table public.location_shares (
  trip_id uuid not null references public.trips (id) on delete cascade,
  user_id uuid not null references public.profiles (id) on delete cascade,
  enabled boolean not null default false,
  expires_at timestamptz,
  last_lat double precision check (last_lat between -90 and 90),
  last_lng double precision check (last_lng between -180 and 180),
  last_accuracy_m real check (last_accuracy_m >= 0),
  last_seen_at timestamptz,
  updated_at timestamptz not null default now(),
  primary key (trip_id, user_id)
);

-- Places and album links (v1.1) ----------------------------------------------

create table public.places (
  id uuid primary key,
  trip_id uuid not null references public.trips (id) on delete cascade,
  name text not null check (char_length(name) between 1 and 120),
  latitude double precision not null check (latitude between -90 and 90),
  longitude double precision not null check (longitude between -180 and 180),
  address text check (char_length(address) <= 200),
  category text check (char_length(category) <= 30),
  notes text check (char_length(notes) <= 500),
  source text not null default 'mapkit' check (source in ('mapkit', 'manual')),
  added_by uuid not null references public.profiles (id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  deleted_at timestamptz,
  server_seq bigint not null default nextval('public.server_seq_seq')
);

create index places_trip_seq_idx on public.places (trip_id, server_seq);

-- Stores only a link. Roamrr never fetches or previews the target.
create table public.trip_album_links (
  id uuid primary key,
  trip_id uuid not null references public.trips (id) on delete cascade,
  url text not null check (char_length(url) <= 2048 and url ~ '^https://[^[:space:]]+$'),
  label text not null check (char_length(label) between 1 and 80),
  added_by uuid not null references public.profiles (id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  deleted_at timestamptz,
  server_seq bigint not null default nextval('public.server_seq_seq')
);

create index trip_album_links_trip_seq_idx on public.trip_album_links (trip_id, server_seq);

-- Account, safety, and plumbing -------------------------------------------------

-- Push needs the paid Apple Developer Program. The table exists so the schema is ready.
create table public.device_tokens (
  user_id uuid not null references public.profiles (id) on delete cascade,
  token text not null check (char_length(token) <= 200),
  environment text not null check (environment in ('sandbox', 'production')),
  updated_at timestamptz not null default now(),
  primary key (user_id, token)
);

create table public.notification_prefs (
  user_id uuid not null references public.profiles (id) on delete cascade,
  trip_id uuid not null references public.trips (id) on delete cascade,
  muted boolean not null default false,
  primary key (user_id, trip_id)
);

-- Prepared for freemium. Written only by the service role.
create table public.entitlements (
  user_id uuid primary key references public.profiles (id) on delete cascade,
  plan text not null default 'free' check (plan in ('free', 'pro')),
  source text,
  expires_at timestamptz,
  updated_at timestamptz not null default now()
);

create table public.blocks (
  blocker_id uuid not null references public.profiles (id) on delete cascade,
  blocked_id uuid not null references public.profiles (id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (blocker_id, blocked_id),
  check (blocker_id <> blocked_id)
);

create table public.reports (
  id uuid primary key default gen_random_uuid(),
  reporter_id uuid not null references public.profiles (id) on delete cascade,
  trip_id uuid references public.trips (id) on delete set null,
  target_type text not null check (target_type in ('user', 'album_link', 'place', 'expense')),
  target_id uuid not null,
  reason text not null check (char_length(reason) between 1 and 500),
  status text not null default 'open' check (status in ('open', 'reviewed', 'dismissed')),
  created_at timestamptz not null default now()
);

-- Remembers every applied mutation so a retried batch never applies twice.
-- Rows older than 30 days are pruned by prune_mutation_log().
create table public.mutation_log (
  mutation_id uuid primary key,
  user_id uuid not null references auth.users (id) on delete cascade,
  entity text not null,
  operation text not null,
  result jsonb not null,
  applied_at timestamptz not null default now()
);

create index mutation_log_applied_idx on public.mutation_log (applied_at);
