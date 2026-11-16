-- =====================================================================
--  KARTECH: ALL UPDATES IN ONE (updates 1, 2, 3 and 4)
--  Paste ALL of this into Supabase → SQL Editor → New query → Run. Safe to run again.
-- =====================================================================


-- =====================================================================
--  KARTECH UPDATE 1: website orders join the workshop + tap-your-name sign in
--  Paste ALL of this into Supabase → SQL Editor → New query → Run.
--  Safe to run again. Run setup-workshop.sql first (already done).
--
--  What it does:
--   • The owner can send a website order to the workshop in one tap.
--   • As the job moves through the workshop, the customer's tracking page
--     updates by itself (status + "Now in Finishing" message + step bar).
--   • Workers on the workshop screen just tap their name. No PIN.
-- =====================================================================

alter table public.ws_orders add column if not exists source_order_id uuid references public.orders(id) on delete set null;
alter table public.ws_orders add column if not exists source_no text;
create index if not exists ws_orders_source on public.ws_orders (source_order_id);


-- Keep the website order's status + message in step with the workshop
create or replace function public.ws_sync_source(p_src uuid) returns void
language plpgsql security definer set search_path = public as $$
declare total int; open_jobs int; undelivered int; note text;
begin
  if p_src is null then return; end if;
  select count(*), count(*) filter (where delivered_at is null) into total, undelivered from public.ws_orders where source_order_id = p_src;
  if total = 0 then return; end if;
  select count(*) into open_jobs from public.ws_tasks t join public.ws_orders o on o.id = t.order_id
   where o.source_order_id = p_src and t.status <> 'done';

  if undelivered = 0 then
    update public.orders set status = 'delivered', status_note = 'Delivered. Thank you for choosing Kartech!' where id = p_src;
  elsif open_jobs = 0 then
    update public.orders set status = 'ready', status_note = 'Everything is finished and checked. Ready for delivery or collection. We will call you to arrange it.' where id = p_src;
  else
    select string_agg(
             case when total > 1 then o.item || ': ' else '' end ||
             coalesce(public.ws_stage_name(cur.stage) || ' (step ' || cur.step || ' of ' || array_length(o.stages, 1) || ')', 'finished'),
             ' · ' order by o.created_at)
      into note
      from public.ws_orders o
      left join lateral (select t.stage, t.step from public.ws_tasks t where t.order_id = o.id and t.status <> 'done' order by t.step limit 1) cur on true
     where o.source_order_id = p_src;
    update public.orders set status = 'workshop', status_note = 'Now in the workshop: ' || note || '. This updates by itself as we work.' where id = p_src;
  end if;
end $$;


-- Owner: send a website order to the workshop (one workshop job per item line)
create or replace function public.ws_from_website(p jsonb) returns text
language plpgsql security definer set search_path = public as $$
declare w public.orders; it jsonb; v_ref text; refs text[] := '{}';
begin
  perform public.ws_need_owner();
  select * into w from public.orders where id = (p->>'order_id')::uuid;
  if w.id is null then raise exception 'Website order not found'; end if;
  if exists (select 1 from public.ws_orders where source_order_id = w.id) then raise exception 'This order is already in the workshop'; end if;
  for it in select * from jsonb_array_elements(w.items) loop
    v_ref := public.ws_create_order(jsonb_build_object(
      'customer', w.customer_name,
      'item', trim((it->>'name') || coalesce(' (' || nullif(it->>'finish','') || ')', '')),
      'qty', greatest(1, coalesce((it->>'qty')::int, 1)),
      'deadline', p->>'deadline',
      'urgency', coalesce(p->>'urgency', 'normal'),
      'stages', p->'stages',
      'notes', nullif(trim(concat_ws(' · ', nullif(p->>'notes',''), 'Website order ' || w.order_no)), '')));
    update public.ws_orders set source_order_id = w.id, source_no = w.order_no where ref = v_ref;
    refs := refs || v_ref;
  end loop;
  perform public.ws_note('info', 'Website order ' || w.order_no || ' sent to the workshop as ' || array_to_string(refs, ', '));
  perform public.ws_sync_source(w.id);
  return array_to_string(refs, ', ');
end $$;


-- Re-create the actions that move jobs, so they also update the website order
create or replace function public.ws_finish(p_token uuid) returns void
language plpgsql security definer set search_path = public as $$
declare w public.ws_workers; t public.ws_tasks; o public.ws_orders; nt uuid;
begin
  w := public.ws_me(p_token);
  select * into t from public.ws_tasks where id = w.task_id;
  if t.id is null then return; end if;
  select * into o from public.ws_orders where id = t.order_id;
  update public.ws_tasks set status = 'done', done_at = now(),
    problem_reason = null, problem_stopped = null, problem_at = null, problem_ack_at = null where id = t.id;
  update public.ws_workers set task_id = null, waiting_logged = false where id = w.id;
  perform public.ws_note('good', w.name || ' finished ' || o.ref || ' · ' || public.ws_stage_name(t.stage), o.id);
  select id into nt from public.ws_tasks where order_id = o.id and step = t.step + 1;
  if nt is not null then
    perform public.ws_enqueue(nt);
    perform public.ws_release((select stage from public.ws_tasks where id = nt));
  else
    perform public.ws_note('good', o.ref || ' is finished and loaded. Ready for delivery.', o.id);
  end if;
  perform public.ws_release(w.stage);
  perform public.ws_sync_source(o.source_order_id);
end $$;

create or replace function public.ws_deliver(p_order uuid) returns void
language plpgsql security definer set search_path = public as $$
declare o public.ws_orders;
begin
  perform public.ws_need_owner();
  if exists (select 1 from public.ws_tasks where order_id = p_order and status <> 'done') then raise exception 'This order is not finished yet'; end if;
  update public.ws_orders set delivered_at = now() where id = p_order returning * into o;
  perform public.ws_note('good', o.ref || ' delivered to ' || o.customer, o.id);
  perform public.ws_sync_source(o.source_order_id);
end $$;


-- Customer tracking: same as before, plus the live workshop steps
create or replace function public.track_order(p_order_no text, p_phone text)
returns jsonb
language sql stable security definer set search_path = public
as $$
  select jsonb_build_object(
           'order_no',    w.order_no,
           'created_at',  w.created_at,
           'updated_at',  w.updated_at,
           'status',      w.status,
           'status_note', w.status_note,
           'fulfilment',  w.fulfilment,
           'items',       w.items,
           'workshop',    (select coalesce(jsonb_agg(jsonb_build_object(
                              'item', o.item, 'qty', o.qty,
                              'steps', (select jsonb_agg(jsonb_build_object('name', public.ws_stage_name(t.stage), 'status', t.status) order by t.step)
                                          from public.ws_tasks t where t.order_id = o.id)) order by o.created_at), '[]'::jsonb)
                           from public.ws_orders o where o.source_order_id = w.id))
  from public.orders w
  where w.order_no = upper(trim(p_order_no))
    and length(regexp_replace(coalesce(p_phone, ''), '\D', '', 'g')) >= 9
    and right(w.phone_digits, 9) = right(regexp_replace(coalesce(p_phone, ''), '\D', '', 'g'), 9)
  limit 1;
$$;
-- (no customer names, workers or other orders are ever shown — only this order's steps)

revoke all on function public.ws_sync_source(uuid) from public, anon, authenticated;
revoke all on function public.ws_from_website(jsonb) from public, anon, authenticated;
revoke all on function public.ws_finish(uuid) from public, anon;
revoke all on function public.ws_deliver(uuid) from public, anon;
grant execute on function public.ws_from_website(jsonb) to authenticated;
grant execute on function public.ws_finish(uuid) to authenticated;
grant execute on function public.ws_deliver(uuid) to authenticated;
revoke all on function public.track_order(text, text) from public;
grant execute on function public.track_order(text, text) to anon, authenticated;


-- ---------------------------------------------------------------------
--  Workshop screen: tap your name to go in (no PIN)
-- ---------------------------------------------------------------------
create or replace function public.ws_tap_in(p_worker uuid) returns uuid
language plpgsql security definer set search_path = public as $$
declare w public.ws_workers; tok uuid;
begin
  if not (public.ws_is_station() or public.is_admin()) then raise exception 'This computer is not set up as the workshop screen'; end if;
  delete from public.ws_sessions where expires_at < now();
  select * into w from public.ws_workers where id = p_worker and active;
  if w.id is null then raise exception 'Worker not found'; end if;
  insert into public.ws_sessions (worker_id) values (w.id) returning token into tok;
  return tok;
end $$;

-- Adding a worker no longer needs a PIN
create or replace function public.ws_save_worker(p jsonb) returns void
language plpgsql security definer set search_path = public as $$
declare w public.ws_workers; v_name text := left(trim(coalesce(p->>'name','')), 60); v_stage text := p->>'stage';
begin
  perform public.ws_need_owner();
  if length(v_name) = 0 then raise exception 'Add a name'; end if;
  if v_stage not in ('metal','foam','finish','load') then raise exception 'Pick a step'; end if;
  if p->>'id' is null then
    insert into public.ws_workers (name, stage, pin_hash) values (v_name, v_stage, extensions.crypt(gen_random_uuid()::text, extensions.gen_salt('bf')));
    perform public.ws_note('good', 'New worker added: ' || v_name || ', ' || public.ws_stage_name(v_stage));
  else
    select * into w from public.ws_workers where id = (p->>'id')::uuid;
    update public.ws_workers set name = v_name, stage = case when w.task_id is null then v_stage else w.stage end,
      failed_tries = 0, locked_until = null where id = w.id;
    perform public.ws_note('info', 'Worker updated: ' || v_name);
  end if;
end $$;

revoke all on function public.ws_tap_in(uuid) from public, anon;
revoke all on function public.ws_save_worker(jsonb) from public, anon;
grant execute on function public.ws_tap_in(uuid) to authenticated;
grant execute on function public.ws_save_worker(jsonb) to authenticated;


-- =====================================================================
--  KARTECH UPDATE 2: raw materials (store, giving out, theft checks)
--  Paste ALL of this into Supabase → SQL Editor → New query → Run.
--  Safe to run again. Run update-1 first.
--
--  How it works:
--   • Only the owner changes stock. Workers can never change it.
--   • Delivery arrives  → owner taps "Received"  → store goes up.
--   • Worker needs some → owner taps "Give out" (to a worker, for an order) → store goes down.
--   • Leftovers come back → "Returned" → store goes up.
--   • Every so often she counts the store → "Count" → anything missing is flagged.
--   • Each product can have a "normal amount" per piece (e.g. 1 bar stool = 2 m steel tube).
--     If an order is given more than normal, she gets an alert.
-- =====================================================================

create table if not exists public.ws_materials (
  id         uuid primary key default gen_random_uuid(),
  name       text not null,
  unit       text not null default 'pcs',
  in_store   numeric not null default 0,
  low_at     numeric not null default 0,
  active     boolean not null default true,
  created_at timestamptz not null default now()
);

create table if not exists public.ws_moves (
  id          bigserial primary key,
  at          timestamptz not null default now(),
  material_id uuid not null references public.ws_materials(id) on delete cascade,
  kind        text not null check (kind in ('in','out','back','count')),
  qty         numeric not null,            -- change to the store: + for in/back, - for out, +/- for count
  order_id    uuid references public.ws_orders(id) on delete set null,
  worker_id   uuid references public.ws_workers(id) on delete set null,
  note        text
);
create index if not exists ws_moves_order on public.ws_moves (order_id);
create index if not exists ws_moves_mat on public.ws_moves (material_id, at desc);

-- normal amount per piece of a product (product name matched without the colour in brackets)
create table if not exists public.ws_usage_std (
  product     text not null,
  material_id uuid not null references public.ws_materials(id) on delete cascade,
  per_piece   numeric not null check (per_piece > 0),
  primary key (product, material_id)
);

alter table public.ws_materials enable row level security;
alter table public.ws_moves     enable row level security;
alter table public.ws_usage_std enable row level security;
drop policy if exists "owner reads materials" on public.ws_materials;
drop policy if exists "owner reads moves"     on public.ws_moves;
drop policy if exists "owner reads std"       on public.ws_usage_std;
create policy "owner reads materials" on public.ws_materials for select to authenticated using (public.is_admin());
create policy "owner reads moves"     on public.ws_moves     for select to authenticated using (public.is_admin());
create policy "owner reads std"       on public.ws_usage_std for select to authenticated using (public.is_admin());
revoke all on public.ws_materials, public.ws_moves, public.ws_usage_std from anon, authenticated;
grant select on public.ws_materials, public.ws_moves, public.ws_usage_std to authenticated;


-- ---------- helpers ----------
create or replace function public.ws_product_key(p text) returns text
language sql immutable as $$ select lower(trim(regexp_replace(coalesce(p,''), '\s*\(.*\)\s*$', ''))); $$;

create or replace function public.ws_fmt(n numeric) returns text
language sql immutable as $$ select trim(trailing '.' from trim(trailing '0' from round(n, 2)::text)); $$;

-- after any stock change: warn when low
create or replace function public.ws_check_low(p_mat uuid) returns void
language plpgsql security definer set search_path = public as $$
declare m public.ws_materials;
begin
  select * into m from public.ws_materials where id = p_mat;
  if m.low_at > 0 and m.in_store <= m.low_at then
    perform public.ws_note('alert', 'Low stock: only ' || public.ws_fmt(m.in_store) || ' ' || m.unit || ' of ' || m.name || ' left in the store');
  end if;
end $$;


-- ---------- owner actions ----------
create or replace function public.ws_save_material(p jsonb) returns void
language plpgsql security definer set search_path = public as $$
declare v_name text := left(trim(coalesce(p->>'name','')), 80); v_unit text := left(trim(coalesce(nullif(p->>'unit',''),'pcs')), 20);
begin
  perform public.ws_need_owner();
  if length(v_name) = 0 then raise exception 'Add a name'; end if;
  if p->>'id' is null then
    insert into public.ws_materials (name, unit, low_at) values (v_name, v_unit, greatest(coalesce((p->>'low_at')::numeric, 0), 0));
    perform public.ws_note('info', 'New material added: ' || v_name);
  else
    update public.ws_materials set name = v_name, unit = v_unit, low_at = greatest(coalesce((p->>'low_at')::numeric, 0), 0)
     where id = (p->>'id')::uuid;
  end if;
end $$;

-- kind: 'in' (received), 'out' (give out), 'back' (returned)
create or replace function public.ws_stock_move(p jsonb) returns void
language plpgsql security definer set search_path = public as $$
declare m public.ws_materials; k text := p->>'kind'; q numeric := (p->>'qty')::numeric;
        v_order uuid := nullif(p->>'order_id','')::uuid; v_worker uuid := nullif(p->>'worker_id','')::uuid;
        o public.ws_orders; wname text; given numeric; expected numeric;
begin
  perform public.ws_need_owner();
  if k not in ('in','out','back') then raise exception 'Unknown action'; end if;
  if q is null or q <= 0 then raise exception 'Enter how much'; end if;
  select * into m from public.ws_materials where id = (p->>'material_id')::uuid for update;
  if m.id is null then raise exception 'Material not found'; end if;
  if k = 'out' and q > m.in_store then raise exception 'Only % % in the store', public.ws_fmt(m.in_store), m.unit; end if;
  if k = 'out' and v_worker is null then raise exception 'Pick who is taking it'; end if;

  insert into public.ws_moves (material_id, kind, qty, order_id, worker_id, note)
  values (m.id, k, case when k = 'out' then -q else q end, v_order, v_worker, nullif(left(trim(coalesce(p->>'note','')), 200), ''));
  update public.ws_materials set in_store = in_store + case when k = 'out' then -q else q end where id = m.id;

  select * into o from public.ws_orders where id = v_order;
  select name into wname from public.ws_workers where id = v_worker;
  perform public.ws_note(case when k = 'out' then 'info' else 'good' end,
    case k when 'in' then 'Received ' || public.ws_fmt(q) || ' ' || m.unit || ' of ' || m.name
           when 'out' then 'Gave ' || public.ws_fmt(q) || ' ' || m.unit || ' of ' || m.name || ' to ' || coalesce(wname, 'a worker') || coalesce(' for ' || o.ref, '')
           else coalesce(wname, 'A worker') || ' returned ' || public.ws_fmt(q) || ' ' || m.unit || ' of ' || m.name end, v_order);

  -- more than normal for this order?
  if k = 'out' and o.id is not null then
    select -coalesce(sum(qty), 0) into given from public.ws_moves where order_id = o.id and material_id = m.id and kind in ('out','back');
    select s.per_piece * o.qty into expected from public.ws_usage_std s where s.product = public.ws_product_key(o.item) and s.material_id = m.id;
    if expected is not null and given > expected * 1.1 then
      perform public.ws_note('alert', o.ref || ' has been given ' || public.ws_fmt(given) || ' ' || m.unit || ' of ' || m.name
        || '. Normal for ' || o.qty || ' × ' || o.item || ' is ' || public.ws_fmt(expected) || ' ' || m.unit
        || ' (' || round(100 * (given - expected) / expected) || '% more)', o.id);
    end if;
  end if;
  perform public.ws_check_low(m.id);
end $$;

-- she counts what is really in the store
create or replace function public.ws_stock_count(p_material uuid, p_counted numeric) returns numeric
language plpgsql security definer set search_path = public as $$
declare m public.ws_materials; diff numeric;
begin
  perform public.ws_need_owner();
  if p_counted is null or p_counted < 0 then raise exception 'Enter what you counted'; end if;
  select * into m from public.ws_materials where id = p_material for update;
  if m.id is null then raise exception 'Material not found'; end if;
  diff := p_counted - m.in_store;
  insert into public.ws_moves (material_id, kind, qty, note) values (m.id, 'count', diff, 'Counted ' || public.ws_fmt(p_counted) || ', system said ' || public.ws_fmt(m.in_store));
  update public.ws_materials set in_store = p_counted where id = m.id;
  if diff < 0 then
    perform public.ws_note('alert', 'Stock count: ' || public.ws_fmt(-diff) || ' ' || m.unit || ' of ' || m.name || ' is MISSING from the store');
  elsif diff > 0 then
    perform public.ws_note('info', 'Stock count: ' || public.ws_fmt(diff) || ' ' || m.unit || ' more ' || m.name || ' than expected');
  else
    perform public.ws_note('good', 'Stock count: ' || m.name || ' is correct');
  end if;
  perform public.ws_check_low(m.id);
  return diff;
end $$;

-- normal amount per piece; per_piece 0 or empty removes it
create or replace function public.ws_save_std(p_product text, p_material uuid, p_per_piece numeric) returns void
language plpgsql security definer set search_path = public as $$
begin
  perform public.ws_need_owner();
  if public.ws_product_key(p_product) = '' then raise exception 'Add the product name'; end if;
  if coalesce(p_per_piece, 0) <= 0 then
    delete from public.ws_usage_std where product = public.ws_product_key(p_product) and material_id = p_material;
  else
    insert into public.ws_usage_std (product, material_id, per_piece) values (public.ws_product_key(p_product), p_material, p_per_piece)
    on conflict (product, material_id) do update set per_piece = excluded.per_piece;
  end if;
end $$;


-- ---------- workshop screen: what was given to me for this job (read only) ----------
create or replace function public.ws_my_materials(p_token uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare w public.ws_workers; t public.ws_tasks;
begin
  w := public.ws_me(p_token);
  select * into t from public.ws_tasks where id = w.task_id;
  if t.id is null then return '[]'::jsonb; end if;
  return coalesce((select jsonb_agg(jsonb_build_object('name', m.name, 'unit', m.unit, 'qty', x.q) order by m.name)
    from (select material_id, -sum(qty) q from public.ws_moves where order_id = t.order_id and worker_id = w.id and kind in ('out','back') group by material_id) x
    join public.ws_materials m on m.id = x.material_id where x.q > 0), '[]'::jsonb);
end $$;


revoke all on function public.ws_product_key(text), public.ws_fmt(numeric) from public, anon;
revoke all on function public.ws_check_low(uuid) from public, anon, authenticated;
revoke all on function public.ws_save_material(jsonb), public.ws_stock_move(jsonb), public.ws_stock_count(uuid, numeric),
                       public.ws_save_std(text, uuid, numeric), public.ws_my_materials(uuid) from public, anon;
grant execute on function public.ws_save_material(jsonb)                to authenticated;
grant execute on function public.ws_stock_move(jsonb)                   to authenticated;
grant execute on function public.ws_stock_count(uuid, numeric)          to authenticated;
grant execute on function public.ws_save_std(text, uuid, numeric)       to authenticated;
grant execute on function public.ws_my_materials(uuid)                  to authenticated;


-- =====================================================================
--  KARTECH UPDATE 3: tools (grinders, welders, drills…) evening check
--  Paste ALL of this into Supabase → SQL Editor → New query → Run.
--  Safe to run again. Run update-1 and update-2 first.
--
--  How it works:
--   • The owner lists each tool once, with who normally uses it.
--   • Nothing is recorded in the morning.
--   • At closing time the foreman opens "Tool check" on the workshop screen.
--     Everything is ticked as back; he taps only what is missing → Done.
--   • Missing tools go to the owner's phone as an alert, with who normally uses it.
--     They stay on her list until the tool is back.
-- =====================================================================

create table if not exists public.ws_tools (
  id           uuid primary key default gen_random_uuid(),
  name         text not null,
  usual_worker uuid references public.ws_workers(id) on delete set null,
  active       boolean not null default true,
  created_at   timestamptz not null default now()
);

create table if not exists public.ws_tool_checks (
  day        date primary key,                -- one check per day (Nairobi date)
  done_at    timestamptz not null default now(),
  missing    int not null default 0
);

create table if not exists public.ws_tool_missing (
  id        bigserial primary key,
  tool_id   uuid not null references public.ws_tools(id) on delete cascade,
  worker_id uuid references public.ws_workers(id) on delete set null,   -- who normally uses it (on that day)
  since     date not null,
  found_at  timestamptz
);
create index if not exists ws_tool_missing_open on public.ws_tool_missing (tool_id) where found_at is null;

alter table public.ws_tools        enable row level security;
alter table public.ws_tool_checks  enable row level security;
alter table public.ws_tool_missing enable row level security;
drop policy if exists "owner reads tools"   on public.ws_tools;
drop policy if exists "owner reads checks"  on public.ws_tool_checks;
drop policy if exists "owner reads missing" on public.ws_tool_missing;
create policy "owner reads tools"   on public.ws_tools        for select to authenticated using (public.is_admin());
create policy "owner reads checks"  on public.ws_tool_checks  for select to authenticated using (public.is_admin());
create policy "owner reads missing" on public.ws_tool_missing for select to authenticated using (public.is_admin());
revoke all on public.ws_tools, public.ws_tool_checks, public.ws_tool_missing from anon, authenticated;
grant select on public.ws_tools, public.ws_tool_checks, public.ws_tool_missing to authenticated;

create or replace function public.ws_today() returns date
language sql stable as $$ select (now() at time zone 'Africa/Nairobi')::date; $$;


-- ---------- owner ----------
create or replace function public.ws_save_tool(p jsonb) returns void
language plpgsql security definer set search_path = public as $$
declare v_name text := left(trim(coalesce(p->>'name','')), 60);
begin
  perform public.ws_need_owner();
  if length(v_name) = 0 then raise exception 'Add a name, e.g. Grinder 1'; end if;
  if p->>'id' is null then
    insert into public.ws_tools (name, usual_worker) values (v_name, nullif(p->>'usual_worker','')::uuid);
    perform public.ws_note('info', 'New tool added: ' || v_name);
  else
    update public.ws_tools set name = v_name, usual_worker = nullif(p->>'usual_worker','')::uuid,
      active = coalesce((p->>'active')::boolean, active)
     where id = (p->>'id')::uuid;
  end if;
end $$;

-- owner marks a missing tool as found
create or replace function public.ws_tool_found(p_tool uuid) returns void
language plpgsql security definer set search_path = public as $$
declare n text;
begin
  perform public.ws_need_owner();
  update public.ws_tool_missing set found_at = now() where tool_id = p_tool and found_at is null;
  select name into n from public.ws_tools where id = p_tool;
  perform public.ws_note('good', 'Tool back: ' || n);
end $$;


-- ---------- workshop screen (foreman) ----------
create or replace function public.ws_tool_list() returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  if not (public.ws_is_station() or public.is_admin()) then raise exception 'Not allowed'; end if;
  return jsonb_build_object(
    'done_today', (select done_at from public.ws_tool_checks where day = public.ws_today()),
    'tools', coalesce((select jsonb_agg(jsonb_build_object(
        'id', t.id, 'name', t.name, 'worker', w.name,
        'missing_since', (select min(since) from public.ws_tool_missing m where m.tool_id = t.id and m.found_at is null))
        order by w.name nulls last, t.name)
      from public.ws_tools t left join public.ws_workers w on w.id = t.usual_worker where t.active), '[]'::jsonb));
end $$;

-- p_list = the tools NOT on the rack tonight (a list of tool ids)
drop function if exists public.ws_tool_check(uuid[]);
create or replace function public.ws_tool_check(p_list jsonb) returns int
language plpgsql security definer set search_path = public as $$
declare t record; n int := 0; names text := ''; p_missing uuid[];
begin
  if not (public.ws_is_station() or public.is_admin()) then raise exception 'Not allowed'; end if;
  p_missing := array(select jsonb_array_elements_text(coalesce(p_list, '[]'::jsonb))::uuid);
  -- tools that were missing and are back now
  for t in select distinct m.tool_id, tl.name from public.ws_tool_missing m join public.ws_tools tl on tl.id = m.tool_id
            where m.found_at is null and not (m.tool_id = any(p_missing)) loop
    update public.ws_tool_missing set found_at = now() where tool_id = t.tool_id and found_at is null;
    perform public.ws_note('good', 'Tool back: ' || t.name);
  end loop;
  -- newly missing tonight
  for t in select tl.id, tl.name, tl.usual_worker, w.name wname from public.ws_tools tl left join public.ws_workers w on w.id = tl.usual_worker
            where tl.id = any(p_missing) and tl.active loop
    n := n + 1;
    if not exists (select 1 from public.ws_tool_missing where tool_id = t.id and found_at is null) then
      insert into public.ws_tool_missing (tool_id, worker_id, since) values (t.id, t.usual_worker, public.ws_today());
    end if;
    names := names || case when names = '' then '' else ', ' end || t.name || coalesce(' (normally ' || t.wname || ')', '');
  end loop;
  insert into public.ws_tool_checks (day, done_at, missing) values (public.ws_today(), now(), n)
  on conflict (day) do update set done_at = now(), missing = excluded.missing;
  if n = 0 then
    perform public.ws_note('good', 'Tool check done: all tools are back');
  else
    perform public.ws_note('alert', 'Tool check: ' || n || ' missing. ' || names);
  end if;
  return n;
end $$;

revoke all on function public.ws_today() from public, anon;
revoke all on function public.ws_save_tool(jsonb), public.ws_tool_found(uuid), public.ws_tool_list(), public.ws_tool_check(jsonb) from public, anon;
grant execute on function public.ws_save_tool(jsonb)    to authenticated;
grant execute on function public.ws_tool_found(uuid)    to authenticated;
grant execute on function public.ws_tool_list()         to authenticated;
grant execute on function public.ws_tool_check(jsonb)   to authenticated;


-- =====================================================================
--  KARTECH UPDATE 4: the foreman page on the workshop screen
--  Paste ALL of this into Supabase → SQL Editor → New query → Run.
--  Safe to run again. Run updates 1, 2 and 3 first.
--
--  • The foreman opens "Foreman" on the workshop screen with his 4-digit code.
--  • He taps a worker → ticks the tools they take (and ticks them back when returned)
--    and taps the materials they take (amount with big number buttons).
--  • Materials are linked by themselves to that worker and the job they are on.
--  • The evening tool check is also behind the foreman code, and shows who has what.
-- =====================================================================

-- which steps use a material (empty = all steps)
alter table public.ws_materials add column if not exists stages text[] not null default '{}';

create table if not exists public.ws_settings (key text primary key, value text, updated_at timestamptz not null default now());
alter table public.ws_settings enable row level security;
revoke all on public.ws_settings from anon, authenticated;

create table if not exists public.ws_tool_loans (
  id        bigserial primary key,
  tool_id   uuid not null references public.ws_tools(id) on delete cascade,
  worker_id uuid references public.ws_workers(id) on delete set null,
  out_at    timestamptz not null default now(),
  back_at   timestamptz
);
create index if not exists ws_tool_loans_open on public.ws_tool_loans (tool_id) where back_at is null;
alter table public.ws_tool_loans enable row level security;
drop policy if exists "owner reads loans" on public.ws_tool_loans;
create policy "owner reads loans" on public.ws_tool_loans for select to authenticated using (public.is_admin());
revoke all on public.ws_tool_loans from anon, authenticated;
grant select on public.ws_tool_loans to authenticated;


-- ---------- foreman code ----------
create or replace function public.ws_set_foreman_pin(p_pin text) returns void
language plpgsql security definer set search_path = public as $$
begin
  perform public.ws_need_owner();
  if coalesce(p_pin,'') !~ '^[0-9]{4}$' then raise exception 'The code must be exactly 4 numbers'; end if;
  insert into public.ws_settings (key, value) values ('foreman_pin', extensions.crypt(p_pin, extensions.gen_salt('bf')))
  on conflict (key) do update set value = excluded.value, updated_at = now();
  delete from public.ws_settings where key in ('foreman_fails','foreman_locked');
  perform public.ws_note('info', 'Manager code changed');
end $$;

create or replace function public.ws_has_foreman_pin() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.ws_settings where key = 'foreman_pin');
$$;

-- checks the code; 5 wrong tries locks it for 5 minutes. Returns 'ok', 'wrong', 'locked' or 'nocode'
-- (does not raise, so wrong tries are remembered)
create or replace function public.ws_foreman_check(p_pin text) returns text
language plpgsql security definer set search_path = public as $$
declare h text; fails int; lk timestamptz;
begin
  if not (public.ws_is_station() or public.is_admin()) then raise exception 'This computer is not set up as the workshop screen'; end if;
  select value into h from public.ws_settings where key = 'foreman_pin';
  if h is null then return 'nocode'; end if;
  select value::timestamptz into lk from public.ws_settings where key = 'foreman_locked';
  if lk is not null and lk > now() then return 'locked'; end if;
  if h <> extensions.crypt(coalesce(p_pin,''), h) then
    select value::int + 1 into fails from public.ws_settings where key = 'foreman_fails';
    fails := coalesce(fails, 1);
    insert into public.ws_settings (key, value) values ('foreman_fails', fails::text) on conflict (key) do update set value = excluded.value;
    if fails >= 5 then
      insert into public.ws_settings (key, value) values ('foreman_locked', (now() + interval '5 minutes')::text) on conflict (key) do update set value = excluded.value;
      delete from public.ws_settings where key = 'foreman_fails';
      perform public.ws_note('alert', 'Someone typed a wrong manager code 5 times on the workshop screen');
      return 'locked';
    end if;
    return 'wrong';
  end if;
  delete from public.ws_settings where key in ('foreman_fails','foreman_locked');
  return 'ok';
end $$;

create or replace function public.ws_foreman_ok(p_pin text) returns void
language plpgsql security definer set search_path = public as $$
declare st text := public.ws_foreman_check(p_pin);
begin
  if st = 'nocode' then raise exception 'The owner has not set a manager code yet'; end if;
  if st = 'locked' then raise exception 'Too many wrong codes. Try again in a few minutes.'; end if;
  if st <> 'ok' then raise exception 'Wrong code'; end if;
end $$;


-- ---------- materials: one place that moves stock (owner or foreman) ----------
create or replace function public.ws_do_move(p jsonb, p_by text) returns void
language plpgsql security definer set search_path = public as $$
declare m public.ws_materials; k text := p->>'kind'; q numeric := (p->>'qty')::numeric;
        v_order uuid := nullif(p->>'order_id','')::uuid; v_worker uuid := nullif(p->>'worker_id','')::uuid;
        o public.ws_orders; wname text; given numeric; expected numeric;
begin
  if k not in ('in','out','back') then raise exception 'Unknown action'; end if;
  if q is null or q <= 0 then raise exception 'Enter how much'; end if;
  select * into m from public.ws_materials where id = (p->>'material_id')::uuid for update;
  if m.id is null then raise exception 'Material not found'; end if;
  if k = 'out' and q > m.in_store then raise exception 'Only % % in the store', public.ws_fmt(m.in_store), m.unit; end if;
  if k = 'out' and v_worker is null then raise exception 'Pick who is taking it'; end if;

  insert into public.ws_moves (material_id, kind, qty, order_id, worker_id, note)
  values (m.id, k, case when k = 'out' then -q else q end, v_order, v_worker,
          nullif(trim(concat_ws(' · ', nullif(left(trim(coalesce(p->>'note','')), 200), ''), case when p_by = 'foreman' then 'by manager' end)), ''));
  update public.ws_materials set in_store = in_store + case when k = 'out' then -q else q end where id = m.id;

  select * into o from public.ws_orders where id = v_order;
  select name into wname from public.ws_workers where id = v_worker;
  perform public.ws_note(case when k = 'out' then 'info' else 'good' end,
    case k when 'in' then 'Received ' || public.ws_fmt(q) || ' ' || m.unit || ' of ' || m.name
           when 'out' then case when p_by = 'foreman' then 'Manager gave ' else 'Gave ' end || public.ws_fmt(q) || ' ' || m.unit || ' of ' || m.name || ' to ' || coalesce(wname, 'a worker') || coalesce(' for ' || o.ref, '')
           else coalesce(wname, 'A worker') || ' returned ' || public.ws_fmt(q) || ' ' || m.unit || ' of ' || m.name end, v_order);

  if k = 'out' and o.id is not null then
    select -coalesce(sum(qty), 0) into given from public.ws_moves where order_id = o.id and material_id = m.id and kind in ('out','back');
    select s.per_piece * o.qty into expected from public.ws_usage_std s where s.product = public.ws_product_key(o.item) and s.material_id = m.id;
    if expected is not null and given > expected * 1.1 then
      perform public.ws_note('alert', o.ref || ' has been given ' || public.ws_fmt(given) || ' ' || m.unit || ' of ' || m.name
        || '. Normal for ' || o.qty || ' × ' || o.item || ' is ' || public.ws_fmt(expected) || ' ' || m.unit
        || ' (' || round(100 * (given - expected) / expected) || '% more)', o.id);
    end if;
  end if;
  perform public.ws_check_low(m.id);
end $$;

create or replace function public.ws_stock_move(p jsonb) returns void
language plpgsql security definer set search_path = public as $$
begin
  perform public.ws_need_owner();
  perform public.ws_do_move(p, 'owner');
end $$;

-- owner: add/edit a material, now with the steps that use it
create or replace function public.ws_save_material(p jsonb) returns void
language plpgsql security definer set search_path = public as $$
declare v_name text := left(trim(coalesce(p->>'name','')), 80); v_unit text := left(trim(coalesce(nullif(p->>'unit',''),'pcs')), 20);
        v_stages text[] := coalesce(array(select jsonb_array_elements_text(coalesce(p->'stages','[]'::jsonb))), '{}');
begin
  perform public.ws_need_owner();
  if length(v_name) = 0 then raise exception 'Add a name'; end if;
  if p->>'id' is null then
    insert into public.ws_materials (name, unit, low_at, stages) values (v_name, v_unit, greatest(coalesce((p->>'low_at')::numeric, 0), 0), v_stages);
    perform public.ws_note('info', 'New material added: ' || v_name);
  else
    update public.ws_materials set name = v_name, unit = v_unit, low_at = greatest(coalesce((p->>'low_at')::numeric, 0), 0), stages = v_stages
     where id = (p->>'id')::uuid;
  end if;
end $$;


-- ---------- foreman page ----------
create or replace function public.ws_foreman_open(p_pin text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare today timestamptz := (public.ws_today()::timestamp at time zone 'Africa/Nairobi'); st text;
begin
  st := public.ws_foreman_check(p_pin);
  if st <> 'ok' then return jsonb_build_object('error', st); end if;
  return jsonb_build_object(
    'workers', coalesce((select jsonb_agg(jsonb_build_object('id', w.id, 'name', w.name, 'stage', w.stage,
        'job', (select jsonb_build_object('order_id', o.id, 'ref', o.ref, 'item', o.item, 'qty', o.qty)
                  from public.ws_tasks t join public.ws_orders o on o.id = t.order_id where t.id = w.task_id),
        'today', coalesce((select jsonb_agg(jsonb_build_object('material_id', m.id, 'material', m.name, 'unit', m.unit, 'qty', x.q,
                    'last', (select -qty from public.ws_moves z where z.worker_id = w.id and z.material_id = m.id and z.kind = 'out' and z.at >= today order by z.id desc limit 1),
                    'times', x.n) order by m.name)
                  from (select material_id, -sum(qty) q, count(*) filter (where kind = 'out') n from public.ws_moves where worker_id = w.id and kind in ('out','back') and at >= today group by material_id) x
                  join public.ws_materials m on m.id = x.material_id where x.q > 0), '[]'::jsonb))
        order by w.stage, w.name) from public.ws_workers w where w.active), '[]'::jsonb),
    'tools', coalesce((select jsonb_agg(jsonb_build_object('id', t.id, 'name', t.name, 'usual', t.usual_worker,
        'with', l.worker_id, 'with_name', lw.name, 'since', l.out_at,
        'missing', exists (select 1 from public.ws_tool_missing mm where mm.tool_id = t.id and mm.found_at is null)) order by t.name)
        from public.ws_tools t
        left join lateral (select * from public.ws_tool_loans x where x.tool_id = t.id and x.back_at is null order by x.id desc limit 1) l on true
        left join public.ws_workers lw on lw.id = l.worker_id
       where t.active), '[]'::jsonb),
    'materials', coalesce((select jsonb_agg(jsonb_build_object('id', m.id, 'name', m.name, 'unit', m.unit, 'in_store', m.in_store, 'stages', m.stages) order by m.name)
        from public.ws_materials m where m.active), '[]'::jsonb),
    'done_today', (select done_at from public.ws_tool_checks where day = public.ws_today()));
end $$;

-- tap a tool on a worker's page: takes it, or returns it if they have it
create or replace function public.ws_foreman_tool(p_pin text, p_tool uuid, p_worker uuid) returns text
language plpgsql security definer set search_path = public as $$
declare l public.ws_tool_loans; tname text; wname text; oname text;
begin
  perform public.ws_foreman_ok(p_pin);
  select name into tname from public.ws_tools where id = p_tool and active;
  select name into wname from public.ws_workers where id = p_worker and active;
  if tname is null or wname is null then raise exception 'Not found'; end if;
  select * into l from public.ws_tool_loans where tool_id = p_tool and back_at is null order by id desc limit 1;
  if l.id is not null and l.worker_id = p_worker then
    update public.ws_tool_loans set back_at = now() where id = l.id;
    update public.ws_tool_missing set found_at = now() where tool_id = p_tool and found_at is null;
    return 'back';
  end if;
  if l.id is not null then
    update public.ws_tool_loans set back_at = now() where id = l.id;
    select name into oname from public.ws_workers where id = l.worker_id;
    perform public.ws_note('info', tname || ' moved from ' || coalesce(oname, 'someone') || ' to ' || wname);
  end if;
  insert into public.ws_tool_loans (tool_id, worker_id) values (p_tool, p_worker);
  return 'out';
end $$;

-- tap a material on a worker's page: linked to the job they are on
create or replace function public.ws_foreman_give(p_pin text, p_material uuid, p_worker uuid, p_qty numeric) returns void
language plpgsql security definer set search_path = public as $$
declare v_order uuid;
begin
  perform public.ws_foreman_ok(p_pin);
  select t.order_id into v_order from public.ws_workers w join public.ws_tasks t on t.id = w.task_id where w.id = p_worker;
  perform public.ws_do_move(jsonb_build_object('kind','out','qty',p_qty,'material_id',p_material,'worker_id',p_worker,'order_id',v_order), 'foreman');
end $$;

create or replace function public.ws_foreman_return(p_pin text, p_material uuid, p_worker uuid, p_qty numeric) returns void
language plpgsql security definer set search_path = public as $$
declare v_order uuid;
begin
  perform public.ws_foreman_ok(p_pin);
  select t.order_id into v_order from public.ws_workers w join public.ws_tasks t on t.id = w.task_id where w.id = p_worker;
  perform public.ws_do_move(jsonb_build_object('kind','back','qty',p_qty,'material_id',p_material,'worker_id',p_worker,'order_id',v_order), 'foreman');
end $$;

-- evening check, now behind the foreman code; knows who had each tool
drop function if exists public.ws_tool_check(uuid[]);
drop function if exists public.ws_tool_check(jsonb);
create or replace function public.ws_tool_check(p_pin text, p_list jsonb) returns int
language plpgsql security definer set search_path = public as $$
declare t record; n int := 0; names text := ''; p_missing uuid[];
begin
  perform public.ws_foreman_ok(p_pin);
  p_missing := array(select jsonb_array_elements_text(coalesce(p_list, '[]'::jsonb))::uuid);
  -- everything ticked as back: close loans, clear old "missing"
  for t in select tl.id, tl.name from public.ws_tools tl where tl.active and not (tl.id = any(p_missing)) loop
    update public.ws_tool_loans set back_at = now() where tool_id = t.id and back_at is null;
    if exists (select 1 from public.ws_tool_missing where tool_id = t.id and found_at is null) then
      update public.ws_tool_missing set found_at = now() where tool_id = t.id and found_at is null;
      perform public.ws_note('good', 'Tool back: ' || t.name);
    end if;
  end loop;
  -- missing tonight: blame whoever had it, otherwise who normally uses it
  for t in select tl.id, tl.name, coalesce(l.worker_id, tl.usual_worker) wid, w.name wname, l.worker_id is not null had
             from public.ws_tools tl
             left join lateral (select worker_id from public.ws_tool_loans x where x.tool_id = tl.id and x.back_at is null order by x.id desc limit 1) l on true
             left join public.ws_workers w on w.id = coalesce(l.worker_id, tl.usual_worker)
            where tl.id = any(p_missing) and tl.active loop
    n := n + 1;
    if not exists (select 1 from public.ws_tool_missing where tool_id = t.id and found_at is null) then
      insert into public.ws_tool_missing (tool_id, worker_id, since) values (t.id, t.wid, public.ws_today());
    end if;
    names := names || case when names = '' then '' else ', ' end || t.name
             || coalesce(case when t.had then ' (taken by ' else ' (normally ' end || t.wname || ')', '');
  end loop;
  insert into public.ws_tool_checks (day, done_at, missing) values (public.ws_today(), now(), n)
  on conflict (day) do update set done_at = now(), missing = excluded.missing;
  if n = 0 then perform public.ws_note('good', 'Tool check done: all tools are back');
  else perform public.ws_note('alert', 'Tool check: ' || n || ' missing. ' || names); end if;
  return n;
end $$;

-- the screen only needs to know if a check is due (no tool details without the code)
create or replace function public.ws_tool_list() returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  if not (public.ws_is_station() or public.is_admin()) then raise exception 'Not allowed'; end if;
  return jsonb_build_object(
    'done_today', (select done_at from public.ws_tool_checks where day = public.ws_today()),
    'has_tools', exists (select 1 from public.ws_tools where active),
    'has_code', public.ws_has_foreman_pin(),
    'tools', '[]'::jsonb);
end $$;

revoke all on function public.ws_foreman_ok(text), public.ws_foreman_check(text), public.ws_do_move(jsonb, text) from public, anon, authenticated;
revoke all on function public.ws_set_foreman_pin(text), public.ws_has_foreman_pin(), public.ws_foreman_open(text),
  public.ws_foreman_tool(text, uuid, uuid), public.ws_foreman_give(text, uuid, uuid, numeric), public.ws_foreman_return(text, uuid, uuid, numeric),
  public.ws_tool_check(text, jsonb), public.ws_stock_move(jsonb), public.ws_save_material(jsonb), public.ws_tool_list() from public, anon;
grant execute on function public.ws_set_foreman_pin(text)                        to authenticated;
grant execute on function public.ws_has_foreman_pin()                            to authenticated;
grant execute on function public.ws_foreman_open(text)                           to authenticated;
grant execute on function public.ws_foreman_tool(text, uuid, uuid)               to authenticated;
grant execute on function public.ws_foreman_give(text, uuid, uuid, numeric)      to authenticated;
grant execute on function public.ws_foreman_return(text, uuid, uuid, numeric)    to authenticated;
grant execute on function public.ws_tool_check(text, jsonb)                      to authenticated;
grant execute on function public.ws_stock_move(jsonb)                            to authenticated;
grant execute on function public.ws_save_material(jsonb)                         to authenticated;
grant execute on function public.ws_tool_list()                                  to authenticated;
