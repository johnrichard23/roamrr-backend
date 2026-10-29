-- Roamrr backend, v0.1 (draft). Money rules. Pure functions, no table writes.
-- Mirrors the Swift implementation in the Core package. Both must pass the same
-- golden test vectors.

-- Round to the nearest integer, ties to the nearest even integer.
create function public.round_half_even(n numeric) returns numeric
language plpgsql immutable
as $$
declare
  f numeric := floor(n);
  d numeric := n - floor(n);
begin
  if d < 0.5 then
    return f;
  elsif d > 0.5 then
    return f + 1;
  elsif mod(f, 2) = 0 then
    return f;
  else
    return f + 1;
  end if;
end;
$$;

create function public.currency_exponent(p_code char) returns smallint
language plpgsql stable
set search_path = public, pg_temp
as $$
declare
  v smallint;
begin
  select c.minor_unit into v from public.currencies c where c.code = upper(p_code);
  if v is null then
    raise exception 'unsupported currency %', p_code using errcode = 'RM001';
  end if;
  return v;
end;
$$;

-- Convert minor units of p_from into minor units of p_to.
-- p_rate = units of p_to per 1 unit of p_from. Rounds half to even, once.
create function public.convert_minor(
  p_amount bigint, p_from char, p_to char, p_rate numeric
) returns bigint
language plpgsql stable
set search_path = public, pg_temp
as $$
declare
  v_from smallint := public.currency_exponent(p_from);
  v_to smallint := public.currency_exponent(p_to);
begin
  if upper(p_from) = upper(p_to) then
    return p_amount;
  end if;
  if p_rate is null or p_rate <= 0 then
    raise exception 'exchange rate must be positive' using errcode = 'RM001';
  end if;
  return public.round_half_even(
    p_amount::numeric / power(10::numeric, v_from) * p_rate * power(10::numeric, v_to)
  )::bigint;
end;
$$;

-- Split p_total minor units across members in proportion to p_weights using the
-- largest-remainder method. Exact integer arithmetic, so results never drift.
-- Leftover units go to the largest remainders; ties go to the smaller member id.
-- Equal split = all weights 1. Percent, shares, and exact amounts are just weights.
create function public.compute_shares(
  p_total bigint, p_member_ids uuid[], p_weights numeric[]
) returns table (member_id uuid, share_minor bigint)
language plpgsql immutable
as $$
#variable_conflict use_column
begin
  if p_total is null or p_total <= 0 then
    raise exception 'total must be positive' using errcode = 'RM001';
  end if;
  if coalesce(array_length(p_member_ids, 1), 0) = 0
     or array_length(p_member_ids, 1) <> coalesce(array_length(p_weights, 1), 0) then
    raise exception 'members and weights must match and not be empty' using errcode = 'RM001';
  end if;
  if exists (select 1 from unnest(p_weights) w where w is null or w <= 0)
     or exists (select 1 from unnest(p_member_ids) m where m is null) then
    raise exception 'weights must be positive and members must be set' using errcode = 'RM001';
  end if;

  return query
  with w as (
    select u.mid, u.wt from unnest(p_member_ids, p_weights) as u(mid, wt)
  ),
  tot as (
    select sum(w.wt) as total_w from w
  ),
  calc as (
    select
      w.mid,
      mod(p_total::numeric * w.wt, tot.total_w) as rem,
      (p_total::numeric * w.wt - mod(p_total::numeric * w.wt, tot.total_w)) / tot.total_w as base
    from w cross join tot
  ),
  ranked as (
    select
      c.mid,
      c.base,
      row_number() over (order by c.rem desc, c.mid asc) as rn,
      p_total - sum(c.base) over () as leftover
    from calc c
  )
  select r.mid, (r.base + case when r.rn <= r.leftover then 1 else 0 end)::bigint
  from ranked r;
end;
$$;

-- Net balance per member in the trip's home currency.
-- Positive = is owed money. Negative = owes money. The column always sums to zero.
create function public.trip_balances(p_trip uuid)
returns table (member_id uuid, net_minor bigint)
language plpgsql stable security definer
set search_path = public, pg_temp
as $$
#variable_conflict use_column
begin
  if not public.is_trip_member(p_trip) then
    raise exception 'not a member of this trip' using errcode = '42501';
  end if;

  return query
  select
    m.id,
    (coalesce(paid.amt, 0) - coalesce(owed.amt, 0)
      + coalesce(sent.amt, 0) - coalesce(recv.amt, 0))::bigint
  from public.trip_members m
  left join (
    select e.payer_member_id as mid, sum(e.amount_trip_minor) as amt
    from public.expenses e
    where e.trip_id = p_trip and e.deleted_at is null
    group by 1
  ) paid on paid.mid = m.id
  left join (
    select s.member_id as mid, sum(s.share_minor) as amt
    from public.expense_shares s
    join public.expenses e on e.id = s.expense_id
    where e.trip_id = p_trip and e.deleted_at is null
    group by 1
  ) owed on owed.mid = m.id
  left join (
    select st.from_member_id as mid, sum(st.amount_minor) as amt
    from public.settlements st
    where st.trip_id = p_trip and st.deleted_at is null
    group by 1
  ) sent on sent.mid = m.id
  left join (
    select st.to_member_id as mid, sum(st.amount_minor) as amt
    from public.settlements st
    where st.trip_id = p_trip and st.deleted_at is null
    group by 1
  ) recv on recv.mid = m.id
  where m.trip_id = p_trip
  order by m.id;
end;
$$;

-- Greedy debt simplification: repeatedly match the largest debtor with the largest
-- creditor. Every step clears at least one person, so the result has at most
-- (people - 1) payments. Ties break by member id so every run gives the same list.
create function public.simplified_settlements(p_trip uuid)
returns table (from_member uuid, to_member uuid, amount_minor bigint)
language plpgsql stable security definer
set search_path = public, pg_temp
as $$
declare
  d_ids uuid[]; d_amt bigint[];
  c_ids uuid[]; c_amt bigint[];
  i integer;
  j integer;
  pay bigint;
begin
  select array_agg(b.member_id order by b.member_id),
         array_agg(-b.net_minor order by b.member_id)
    into d_ids, d_amt
    from public.trip_balances(p_trip) b
    where b.net_minor < 0;

  select array_agg(b.member_id order by b.member_id),
         array_agg(b.net_minor order by b.member_id)
    into c_ids, c_amt
    from public.trip_balances(p_trip) b
    where b.net_minor > 0;

  -- Each round settles the largest remaining debtor against the largest remaining
  -- creditor (ties go to the smaller member id), then looks again at what is left.
  -- The lists are sorted by id, so the first maximum found is the tie winner.
  while d_ids is not null and c_ids is not null loop
    i := 1;
    for k in 2 .. array_length(d_ids, 1) loop
      if d_amt[k] > d_amt[i] then i := k; end if;
    end loop;
    j := 1;
    for k in 2 .. array_length(c_ids, 1) loop
      if c_amt[k] > c_amt[j] then j := k; end if;
    end loop;

    pay := least(d_amt[i], c_amt[j]);
    from_member := d_ids[i];
    to_member := c_ids[j];
    amount_minor := pay;
    return next;

    d_amt[i] := d_amt[i] - pay;
    c_amt[j] := c_amt[j] - pay;
    if d_amt[i] = 0 then
      d_ids := d_ids[1 : i - 1] || d_ids[i + 1 : array_length(d_ids, 1)];
      d_amt := d_amt[1 : i - 1] || d_amt[i + 1 : array_length(d_amt, 1)];
      if coalesce(array_length(d_ids, 1), 0) = 0 then d_ids := null; end if;
    end if;
    if c_amt[j] = 0 then
      c_ids := c_ids[1 : j - 1] || c_ids[j + 1 : array_length(c_ids, 1)];
      c_amt := c_amt[1 : j - 1] || c_amt[j + 1 : array_length(c_amt, 1)];
      if coalesce(array_length(c_ids, 1), 0) = 0 then c_ids := null; end if;
    end if;
  end loop;
end;
$$;

-- Safety net: an expense's shares must add up to its total in the home currency.
create function public._assert_expense_balanced(p_expense uuid) returns void
language plpgsql
set search_path = public, pg_temp
as $$
declare
  v_total bigint;
  v_sum bigint;
begin
  select e.amount_trip_minor into v_total from public.expenses e where e.id = p_expense;
  if v_total is null then
    return;
  end if;
  select coalesce(sum(s.share_minor), 0) into v_sum
  from public.expense_shares s where s.expense_id = p_expense;
  if v_sum <> v_total then
    raise exception 'shares (%) do not add up to the total (%)', v_sum, v_total
      using errcode = 'RM001';
  end if;
end;
$$;

create function public._check_expense_balanced() returns trigger
language plpgsql
set search_path = public, pg_temp
as $$
begin
  if tg_table_name = 'expenses' then
    perform public._assert_expense_balanced(new.id);
  elsif tg_op = 'DELETE' then
    perform public._assert_expense_balanced(old.expense_id);
  else
    perform public._assert_expense_balanced(new.expense_id);
  end if;
  return null;
end;
$$;

-- Deferred, so shares can be replaced inside one transaction.
create constraint trigger expenses_balanced
  after insert or update on public.expenses
  deferrable initially deferred
  for each row execute function public._check_expense_balanced();

create constraint trigger expense_shares_balanced
  after insert or update or delete on public.expense_shares
  deferrable initially deferred
  for each row execute function public._check_expense_balanced();
