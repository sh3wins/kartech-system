-- =====================================================================
--  KARTECH WORKSHOP: INSTALL EVERYTHING (brand-new Supabase project)
--  This is every database file, in the right order, in one file:
--  00-website-basics → setup-workshop → update-1 … update-26.
--
--  Use it for a NEW project, or to bring an existing project fully up
--  to date. Paste ALL of it into Supabase → SQL Editor → New query → Run.
--  It is safe to run again: running the whole file always ends on the
--  newest version of everything.
--
--  DO NOT re-run one old update file on its own (for example only
--  update-12): it can put back an older version of a function.
--  Either run the newest update you are missing, or run this whole file.
--
--  This file is made from the separate files. If you change one of
--  them, rebuild this file (see docs/DATABASE.md).
-- =====================================================================


-- #####################################################################
-- ##  FILE: 00-website-basics.sql
-- #####################################################################

-- =====================================================================
--  STEP 0 (only for a brand-new Supabase project)
--  The workshop system shares one Supabase project with the Kartech
--  website. It needs four things the website normally creates:
--    • public.admins         (who is the owner)
--    • public.is_admin()     (is the signed-in person the owner?)
--    • public.orders         (orders placed on the website)
--    • public.custom_requests (quote requests from the website)
--  If the website is already set up in this project, this file changes
--  NOTHING (every part checks first). Safe to run again.
-- =====================================================================

create table if not exists public.admins (
  user_id uuid primary key references auth.users(id) on delete cascade,
  created_at timestamptz not null default now()
);
alter table public.admins enable row level security;
do $$ begin
  if not exists (select 1 from pg_policies where schemaname = 'public' and tablename = 'admins' and policyname = 'see own admin row') then
    create policy "see own admin row" on public.admins for select using (user_id = auth.uid());
  end if;
end $$;

do $$ begin
  if not exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace where n.nspname = 'public' and p.proname = 'is_admin') then
    execute $f$
      create function public.is_admin() returns boolean
      language sql stable security definer set search_path = public as
      $b$ select exists (select 1 from public.admins where user_id = auth.uid()) $b$ $f$;
  end if;
  if not exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace where n.nspname = 'public' and p.proname = 'touch_updated_at') then
    execute $f$
      create function public.touch_updated_at() returns trigger language plpgsql as
      $b$ begin new.updated_at := now(); return new; end $b$ $f$;
  end if;
end $$;

create table if not exists public.orders (
  id uuid primary key default gen_random_uuid(),
  order_no text not null unique,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  status text not null default 'received'
    check (status in ('received','confirmed','workshop','ready','delivered','cancelled')),
  status_note text,
  customer_name text not null,
  phone text not null,
  phone_digits text not null,
  email text,
  fulfilment text not null,
  delivery_location text,
  notes text,
  items jsonb not null,
  subtotal numeric not null default 0,
  unpriced_items integer not null default 0
);
alter table public.orders enable row level security;

create table if not exists public.custom_requests (
  id uuid primary key default gen_random_uuid(),
  ref text not null unique,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  status text not null default 'new'
    check (status in ('new','contacted','quoted','in_progress','closed')),
  admin_notes text,
  need text not null,
  space text,
  name text not null,
  phone text,
  email text,
  files text[] not null default '{}'
);
alter table public.custom_requests enable row level security;

do $$ begin
  if not exists (select 1 from pg_policies where schemaname = 'public' and tablename = 'orders' and policyname = 'admins read orders') then
    create policy "admins read orders" on public.orders for select using (public.is_admin());
    create policy "admins update orders" on public.orders for update using (public.is_admin()) with check (public.is_admin());
  end if;
  if not exists (select 1 from pg_policies where schemaname = 'public' and tablename = 'custom_requests' and policyname = 'admins read requests') then
    create policy "admins read requests" on public.custom_requests for select using (public.is_admin());
    create policy "admins update requests" on public.custom_requests for update using (public.is_admin()) with check (public.is_admin());
  end if;
  if not exists (select 1 from pg_trigger where tgname = 'orders_touch') then
    create trigger orders_touch before update on public.orders for each row execute function public.touch_updated_at();
  end if;
  if not exists (select 1 from pg_trigger where tgname = 'requests_touch') then
    create trigger requests_touch before update on public.custom_requests for each row execute function public.touch_updated_at();
  end if;
end $$;


-- #####################################################################
-- ##  FILE: setup-workshop.sql
-- #####################################################################

-- =====================================================================
--  KARTECH WORKSHOP SYSTEM: database setup
--  Paste ALL of this into Supabase → SQL Editor → New query → Run.
--  Safe to run again. It does not touch the website's orders tables.
--
--  Who can do what:
--   • Owner (anyone in public.admins): sees everything, manages orders and workers.
--   • Workshop PC (a login listed in public.ws_stations): lets workers sign in
--     with their PIN and update only their own job.
--   • The public website and strangers: no access at all.
-- =====================================================================

create extension if not exists pgcrypto with schema extensions;

-- ---------- TABLES ----------
create table if not exists public.ws_workers (
  id             uuid primary key default gen_random_uuid(),
  name           text not null,
  stage          text not null check (stage in ('metal','foam','finish','load')),
  pin_hash       text not null,
  active         boolean not null default true,
  task_id        uuid,
  failed_tries   int not null default 0,
  locked_until   timestamptz,
  waiting_logged boolean not null default false,
  created_at     timestamptz not null default now()
);

create sequence if not exists public.ws_ref_seq start 1001;

create table if not exists public.ws_orders (
  id           uuid primary key default gen_random_uuid(),
  ref          text unique not null,
  customer     text not null,
  item         text not null,
  qty          int not null check (qty > 0),
  deadline     date not null,
  urgency      text not null default 'normal' check (urgency in ('urgent','high','normal')),
  notes        text,
  stages       text[] not null,
  delivered_at timestamptz,
  created_at   timestamptz not null default now()
);

create table if not exists public.ws_tasks (
  id              uuid primary key default gen_random_uuid(),
  order_id        uuid not null references public.ws_orders(id) on delete cascade,
  step            int not null,
  stage           text not null check (stage in ('metal','foam','finish','load')),
  status          text not null default 'waiting' check (status in ('waiting','queued','assigned','working','done')),
  worker_id       uuid references public.ws_workers(id) on delete set null,
  rank            double precision not null default 0,
  problem_reason  text,
  problem_stopped boolean,
  problem_at      timestamptz,
  problem_ack_at  timestamptz,
  assigned_at     timestamptz,
  started_at      timestamptz,
  done_at         timestamptz
);
create index if not exists ws_tasks_queue on public.ws_tasks (stage, status, rank);

create table if not exists public.ws_log (
  id       bigserial primary key,
  at       timestamptz not null default now(),
  kind     text not null default 'info',
  text     text not null,
  order_id uuid
);

create table if not exists public.ws_sessions (
  token      uuid primary key default gen_random_uuid(),
  worker_id  uuid not null references public.ws_workers(id) on delete cascade,
  expires_at timestamptz not null default now() + interval '12 hours'
);

create table if not exists public.ws_stations (
  user_id uuid primary key references auth.users(id) on delete cascade
);

alter table public.ws_workers  enable row level security;
alter table public.ws_orders   enable row level security;
alter table public.ws_tasks    enable row level security;
alter table public.ws_log      enable row level security;
alter table public.ws_sessions enable row level security;
alter table public.ws_stations enable row level security;

-- The owner can READ everything. All changes go through the functions below.
drop policy if exists "owner reads workers" on public.ws_workers;
drop policy if exists "owner reads orders"  on public.ws_orders;
drop policy if exists "owner reads tasks"   on public.ws_tasks;
drop policy if exists "owner reads log"     on public.ws_log;
create policy "owner reads workers" on public.ws_workers for select to authenticated using (public.is_admin());
create policy "owner reads orders"  on public.ws_orders  for select to authenticated using (public.is_admin());
create policy "owner reads tasks"   on public.ws_tasks   for select to authenticated using (public.is_admin());
create policy "owner reads log"     on public.ws_log     for select to authenticated using (public.is_admin());
-- PINs never leave the database, not even to the owner
revoke all on public.ws_workers, public.ws_orders, public.ws_tasks, public.ws_log, public.ws_sessions, public.ws_stations from anon, authenticated;
grant select (id, name, stage, active, task_id, locked_until, created_at) on public.ws_workers to authenticated;
grant select on public.ws_orders, public.ws_tasks, public.ws_log to authenticated;


-- ---------- SMALL HELPERS ----------
create or replace function public.ws_is_station() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.ws_stations where user_id = auth.uid());
$$;

create or replace function public.ws_stage_name(s text) returns text
language sql immutable as $$
  select case s when 'metal' then 'Metalwork' when 'foam' then 'Foaming & fabrication'
                when 'finish' then 'Finishing' when 'load' then 'Loading' else s end;
$$;

create or replace function public.ws_urank(u text) returns int
language sql immutable as $$ select case u when 'urgent' then 0 when 'high' then 1 else 2 end; $$;

create or replace function public.ws_note(p_kind text, p_text text, p_order uuid default null) returns void
language sql security definer set search_path = public as $$
  insert into public.ws_log (kind, text, order_id) values (p_kind, p_text, p_order);
$$;

create or replace function public.ws_need_owner() returns void
language plpgsql stable security definer set search_path = public as $$
begin if not public.is_admin() then raise exception 'Only the owner can do this'; end if; end $$;

-- Put a job in its step's line: by urgency, then deadline
create or replace function public.ws_enqueue(p_task uuid) returns void
language plpgsql security definer set search_path = public as $$
declare t public.ws_tasks; o public.ws_orders; nxt double precision; prv double precision; r double precision;
begin
  select * into t from public.ws_tasks where id = p_task;
  select * into o from public.ws_orders where id = t.order_id;
  select q.rank into nxt from public.ws_tasks q join public.ws_orders qo on qo.id = q.order_id
   where q.stage = t.stage and q.status = 'queued' and q.id <> t.id
     and (public.ws_urank(qo.urgency), qo.deadline) > (public.ws_urank(o.urgency), o.deadline)
   order by q.rank limit 1;
  if nxt is null then
    select coalesce(max(rank), 0) + 1 into r from public.ws_tasks where stage = t.stage and status = 'queued' and id <> t.id;
  else
    select max(rank) into prv from public.ws_tasks where stage = t.stage and status = 'queued' and id <> t.id and rank < nxt;
    r := case when prv is null then nxt - 1 else (prv + nxt) / 2 end;
  end if;
  update public.ws_tasks set status = 'queued', rank = r, worker_id = null where id = p_task;
end $$;

-- Give every free worker in a step the next job in line
create or replace function public.ws_release(p_stage text) returns void
language plpgsql security definer set search_path = public as $$
declare w record; tid uuid; o public.ws_orders;
begin
  for w in select * from public.ws_workers where active and stage = p_stage and task_id is null order by created_at loop
    select id into tid from public.ws_tasks where stage = p_stage and status = 'queued' order by rank limit 1 for update skip locked;
    if tid is null then
      if not w.waiting_logged then
        perform public.ws_note('warn', w.name || ' (' || public.ws_stage_name(p_stage) || ') has no work waiting');
        update public.ws_workers set waiting_logged = true where id = w.id;
      end if;
    else
      update public.ws_tasks set status = 'assigned', worker_id = w.id, assigned_at = now() where id = tid;
      update public.ws_workers set task_id = tid, waiting_logged = false where id = w.id;
      select o2.* into o from public.ws_orders o2 join public.ws_tasks t on t.order_id = o2.id where t.id = tid;
      perform public.ws_note('info', w.name || ' got the next job: ' || o.ref || ' · ' || public.ws_stage_name(p_stage), o.id);
    end if;
  end loop;
end $$;


-- ---------- OWNER ACTIONS ----------
create or replace function public.ws_create_order(p jsonb) returns text
language plpgsql security definer set search_path = public as $$
declare o_id uuid; v_ref text; st text[]; i int; first_task uuid; t_id uuid;
begin
  perform public.ws_need_owner();
  select coalesce(array_agg(x), '{}') into st
    from (select jsonb_array_elements_text(p->'stages') x) s where x in ('metal','foam','finish','load');
  -- keep the workshop order of steps
  select array_agg(s order by array_position(array['metal','foam','finish','load'], s)) into st from unnest(st) s;
  if st is null or array_length(st, 1) is null then raise exception 'Pick at least one step'; end if;
  if length(trim(coalesce(p->>'customer',''))) = 0 or length(trim(coalesce(p->>'item',''))) = 0 then raise exception 'Customer and item are required'; end if;
  v_ref := 'KT-' || nextval('public.ws_ref_seq');
  insert into public.ws_orders (ref, customer, item, qty, deadline, urgency, notes, stages)
  values (v_ref, left(trim(p->>'customer'), 120), left(trim(p->>'item'), 120), greatest(1, (p->>'qty')::int),
          coalesce((p->>'deadline')::date, current_date + 7),
          case when p->>'urgency' in ('urgent','high','normal') then p->>'urgency' else 'normal' end,
          nullif(left(trim(coalesce(p->>'notes','')), 500), ''), st)
  returning id into o_id;
  for i in 1 .. array_length(st, 1) loop
    insert into public.ws_tasks (order_id, step, stage) values (o_id, i, st[i]) returning id into t_id;
    if i = 1 then first_task := t_id; end if;
  end loop;
  perform public.ws_note(case when p->>'urgency' = 'urgent' then 'alert' else 'info' end,
    'New order ' || v_ref || ': ' || (p->>'qty') || ' × ' || trim(p->>'item') || ' for ' || trim(p->>'customer'), o_id);
  perform public.ws_enqueue(first_task);
  perform public.ws_release(st[1]);
  return v_ref;
end $$;

create or replace function public.ws_move(p_task uuid, p_up boolean) returns void
language plpgsql security definer set search_path = public as $$
declare t public.ws_tasks; other public.ws_tasks;
begin
  perform public.ws_need_owner();
  select * into t from public.ws_tasks where id = p_task and status = 'queued';
  if t.id is null then return; end if;
  if p_up then
    select * into other from public.ws_tasks where stage = t.stage and status = 'queued' and rank < t.rank order by rank desc limit 1;
  else
    select * into other from public.ws_tasks where stage = t.stage and status = 'queued' and rank > t.rank order by rank limit 1;
  end if;
  if other.id is null then return; end if;
  update public.ws_tasks set rank = other.rank where id = t.id;
  update public.ws_tasks set rank = t.rank where id = other.id;
end $$;

create or replace function public.ws_make_urgent(p_order uuid) returns void
language plpgsql security definer set search_path = public as $$
declare t record; o public.ws_orders;
begin
  perform public.ws_need_owner();
  update public.ws_orders set urgency = 'urgent' where id = p_order returning * into o;
  for t in select * from public.ws_tasks where order_id = p_order and status = 'queued' loop
    update public.ws_tasks set rank = (select coalesce(min(rank), 1) - 1 from public.ws_tasks where stage = t.stage and status = 'queued') where id = t.id;
  end loop;
  perform public.ws_note('alert', o.ref || ' made urgent. Moved to the front of the line.', o.id);
end $$;

create or replace function public.ws_ack(p_task uuid) returns void
language plpgsql security definer set search_path = public as $$
declare t public.ws_tasks;
begin
  perform public.ws_need_owner();
  update public.ws_tasks set problem_ack_at = now() where id = p_task and problem_at is not null returning * into t;
  if t.id is not null then
    perform public.ws_note('good', 'Owner is on it: ' || (select name from public.ws_workers where id = t.worker_id) || ', ' || (select ref from public.ws_orders where id = t.order_id) || ' (' || t.problem_reason || ')', t.order_id);
  end if;
end $$;

create or replace function public.ws_solve(p_task uuid) returns void
language plpgsql security definer set search_path = public as $$
declare t public.ws_tasks;
begin
  perform public.ws_need_owner();
  select * into t from public.ws_tasks where id = p_task;
  update public.ws_tasks set problem_reason = null, problem_stopped = null, problem_at = null, problem_ack_at = null where id = p_task;
  perform public.ws_note('good', 'Problem solved on ' || (select ref from public.ws_orders where id = t.order_id), t.order_id);
end $$;

create or replace function public.ws_deliver(p_order uuid) returns void
language plpgsql security definer set search_path = public as $$
declare o public.ws_orders;
begin
  perform public.ws_need_owner();
  if exists (select 1 from public.ws_tasks where order_id = p_order and status <> 'done') then raise exception 'This order is not finished yet'; end if;
  update public.ws_orders set delivered_at = now() where id = p_order returning * into o;
  perform public.ws_note('good', o.ref || ' delivered to ' || o.customer, o.id);
end $$;

create or replace function public.ws_save_worker(p jsonb) returns void
language plpgsql security definer set search_path = public as $$
declare w public.ws_workers; v_name text := left(trim(coalesce(p->>'name','')), 60); v_stage text := p->>'stage'; v_pin text := coalesce(p->>'pin','');
begin
  perform public.ws_need_owner();
  if length(v_name) = 0 then raise exception 'Add a name'; end if;
  if v_stage not in ('metal','foam','finish','load') then raise exception 'Pick a step'; end if;
  if v_pin <> '' and v_pin !~ '^[0-9]{4}$' then raise exception 'The PIN must be exactly 4 numbers'; end if;
  if p->>'id' is null then
    if v_pin = '' then raise exception 'The PIN must be exactly 4 numbers'; end if;
    insert into public.ws_workers (name, stage, pin_hash) values (v_name, v_stage, extensions.crypt(v_pin, extensions.gen_salt('bf')));
    perform public.ws_note('good', 'New worker added: ' || v_name || ', ' || public.ws_stage_name(v_stage));
  else
    select * into w from public.ws_workers where id = (p->>'id')::uuid;
    update public.ws_workers set
      name = v_name,
      stage = case when w.task_id is null then v_stage else w.stage end,
      pin_hash = case when v_pin <> '' then extensions.crypt(v_pin, extensions.gen_salt('bf')) else pin_hash end,
      failed_tries = case when v_pin <> '' then 0 else failed_tries end,
      locked_until = case when v_pin <> '' then null else locked_until end
    where id = w.id;
    perform public.ws_note('info', 'Worker updated: ' || v_name || case when v_pin <> '' then ' (new PIN)' else '' end);
  end if;
  perform public.ws_release(v_stage);
end $$;

create or replace function public.ws_set_worker_active(p_worker uuid, p_active boolean) returns void
language plpgsql security definer set search_path = public as $$
declare w public.ws_workers;
begin
  perform public.ws_need_owner();
  select * into w from public.ws_workers where id = p_worker;
  if p_active then
    update public.ws_workers set active = true, waiting_logged = false where id = w.id;
    perform public.ws_note('info', w.name || ' switched back on');
  else
    if w.task_id is not null then
      update public.ws_tasks set status = 'queued', worker_id = null,
        problem_reason = null, problem_stopped = null, problem_at = null, problem_ack_at = null,
        rank = (select coalesce(min(rank), 1) - 1 from public.ws_tasks where stage = w.stage and status = 'queued')
      where id = w.task_id;
    end if;
    update public.ws_workers set active = false, task_id = null where id = w.id;
    delete from public.ws_sessions where worker_id = w.id;
    perform public.ws_note('warn', w.name || ' switched off. Can no longer sign in.');
  end if;
  perform public.ws_release(w.stage);
end $$;


-- ---------- WORKSHOP PC ACTIONS ----------
create or replace function public.ws_station_workers() returns table (id uuid, name text, stage text)
language plpgsql stable security definer set search_path = public as $$
begin
  if not (public.ws_is_station() or public.is_admin()) then raise exception 'This computer is not set up as the workshop PC'; end if;
  return query select w.id, w.name, w.stage from public.ws_workers w where w.active order by w.name;
end $$;

create or replace function public.ws_login(p_worker uuid, p_pin text) returns uuid
language plpgsql security definer set search_path = public as $$
declare w public.ws_workers; tok uuid;
begin
  if not (public.ws_is_station() or public.is_admin()) then raise exception 'This computer is not set up as the workshop PC'; end if;
  delete from public.ws_sessions where expires_at < now();
  select * into w from public.ws_workers where id = p_worker and active;
  if w.id is null then raise exception 'Worker not found'; end if;
  if w.locked_until is not null and w.locked_until > now() then raise exception 'Too many wrong PINs. Try again in a few minutes.'; end if;
  if w.pin_hash <> extensions.crypt(coalesce(p_pin,''), w.pin_hash) then
    update public.ws_workers set failed_tries = failed_tries + 1,
      locked_until = case when failed_tries + 1 >= 5 then now() + interval '5 minutes' else null end
    where id = w.id;
    raise exception 'Wrong PIN';
  end if;
  update public.ws_workers set failed_tries = 0, locked_until = null where id = w.id;
  insert into public.ws_sessions (worker_id) values (w.id) returning token into tok;
  return tok;
end $$;

create or replace function public.ws_me(p_token uuid) returns public.ws_workers
language plpgsql security definer set search_path = public as $$
declare w public.ws_workers;
begin
  if not (public.ws_is_station() or public.is_admin()) then raise exception 'This computer is not set up as the workshop PC'; end if;
  select wk.* into w from public.ws_sessions s join public.ws_workers wk on wk.id = s.worker_id
   where s.token = p_token and s.expires_at > now() and wk.active;
  if w.id is null then raise exception 'Signed out'; end if;
  return w;
end $$;

create or replace function public.ws_my_job(p_token uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare w public.ws_workers; t public.ws_tasks; o public.ws_orders; nxt record; after_stage text;
begin
  w := public.ws_me(p_token);
  if w.task_id is not null then
    select * into t from public.ws_tasks where id = w.task_id;
    select * into o from public.ws_orders where id = t.order_id;
    after_stage := o.stages[t.step + 1];
  end if;
  select o2.ref, o2.qty, o2.item into nxt from public.ws_tasks q join public.ws_orders o2 on o2.id = q.order_id
   where q.stage = w.stage and q.status = 'queued' order by q.rank limit 1;
  return jsonb_build_object(
    'worker', jsonb_build_object('name', w.name, 'stage', w.stage),
    'task', case when t.id is null then null else jsonb_build_object(
      'status', t.status, 'stage', t.stage, 'problem_reason', t.problem_reason, 'problem_stopped', t.problem_stopped,
      'problem_ack', t.problem_ack_at is not null) end,
    'order', case when o.id is null then null else jsonb_build_object(
      'ref', o.ref, 'item', o.item, 'qty', o.qty, 'deadline', o.deadline, 'urgency', o.urgency, 'notes', o.notes) end,
    'after', after_stage,
    'next', case when nxt.ref is null then null else jsonb_build_object('ref', nxt.ref, 'qty', nxt.qty, 'item', nxt.item) end);
end $$;

create or replace function public.ws_start(p_token uuid) returns void
language plpgsql security definer set search_path = public as $$
declare w public.ws_workers; t public.ws_tasks;
begin
  w := public.ws_me(p_token);
  update public.ws_tasks set status = 'working', started_at = now() where id = w.task_id and status = 'assigned' returning * into t;
  if t.id is not null then
    perform public.ws_note('info', w.name || ' started ' || (select ref from public.ws_orders where id = t.order_id) || ' · ' || public.ws_stage_name(t.stage), t.order_id);
  end if;
end $$;

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
end $$;

create or replace function public.ws_report(p_token uuid, p_reason text, p_stopped boolean) returns void
language plpgsql security definer set search_path = public as $$
declare w public.ws_workers; t public.ws_tasks;
begin
  w := public.ws_me(p_token);
  update public.ws_tasks set problem_reason = left(coalesce(p_reason, 'Problem'), 80), problem_stopped = coalesce(p_stopped, false),
    problem_at = now(), problem_ack_at = null where id = w.task_id returning * into t;
  if t.id is not null then
    perform public.ws_note('alert', w.name || case when p_stopped then ' has STOPPED work on ' else ' reported a problem on ' end ||
      (select ref from public.ws_orders where id = t.order_id) || ': ' || t.problem_reason, t.order_id);
  end if;
end $$;

create or replace function public.ws_logout(p_token uuid) returns void
language sql security definer set search_path = public as $$
  delete from public.ws_sessions where token = p_token;
$$;


-- ---------- WHO CAN CALL WHAT ----------
-- Nothing is open to the public (anon). Only signed-in owner / workshop PC.
do $$
declare f record;
begin
  for f in select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
           where n.nspname = 'public' and p.proname like 'ws\_%' loop
    execute format('revoke all on function %s from public, anon, authenticated', f.sig);
  end loop;
end $$;

grant execute on function public.ws_is_station()                     to authenticated;
grant execute on function public.ws_create_order(jsonb)              to authenticated;
grant execute on function public.ws_move(uuid, boolean)              to authenticated;
grant execute on function public.ws_make_urgent(uuid)                to authenticated;
grant execute on function public.ws_ack(uuid)                        to authenticated;
grant execute on function public.ws_solve(uuid)                      to authenticated;
grant execute on function public.ws_deliver(uuid)                    to authenticated;
grant execute on function public.ws_save_worker(jsonb)               to authenticated;
grant execute on function public.ws_set_worker_active(uuid, boolean) to authenticated;
grant execute on function public.ws_station_workers()                to authenticated;
grant execute on function public.ws_login(uuid, text)                to authenticated;
grant execute on function public.ws_my_job(uuid)                     to authenticated;
grant execute on function public.ws_start(uuid)                      to authenticated;
grant execute on function public.ws_finish(uuid)                     to authenticated;
grant execute on function public.ws_report(uuid, text, boolean)      to authenticated;
grant execute on function public.ws_logout(uuid)                     to authenticated;

-- =====================================================================
--  AFTER THIS: make the workshop PC login (see SETUP.md, step 3):
--
--  insert into public.ws_stations (user_id)
--  select id from auth.users where email = 'workshop@kartech.co.ke'
--  on conflict do nothing;
-- =====================================================================


-- #####################################################################
-- ##  FILE: update-1-website-link.sql
-- #####################################################################

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


-- #####################################################################
-- ##  FILE: update-2-materials.sql
-- #####################################################################

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


-- #####################################################################
-- ##  FILE: update-3-tools.sql
-- #####################################################################

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


-- #####################################################################
-- ##  FILE: update-4-foreman.sql
-- #####################################################################

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


-- #####################################################################
-- ##  FILE: update-5-steps.sql
-- #####################################################################

-- =====================================================================
--  KARTECH UPDATE 5: workshop steps the owner can change
--  Paste ALL of this into Supabase → SQL Editor → New query → Run.
--  Safe to run again. Run ALL-UPDATES.sql first (already done).
--
--  Metalwork is now split into its real steps, each with its own people:
--   Getting metals → Cutting → Folding → Welding → Grinding → Painting
--   → Foaming & fabrication → Finishing → Loading
--  The owner can rename, reorder, add or switch off steps in the app.
--  Customers on the website still see the simple version:
--   Metalwork → Foaming & fabrication → Finishing → Loading
-- =====================================================================

create table if not exists public.ws_steps (
  id     text primary key,
  name   text not null,
  grp    text not null,             -- what the customer sees (Metalwork, Finishing…)
  sort   int  not null default 0,
  active boolean not null default true
);
alter table public.ws_steps enable row level security;
drop policy if exists "signed in reads steps" on public.ws_steps;
create policy "signed in reads steps" on public.ws_steps for select to authenticated using (true);
revoke all on public.ws_steps from anon, authenticated;
grant select on public.ws_steps to authenticated;

insert into public.ws_steps (id, name, grp, sort) values
  ('get',    'Getting metals',        'Metalwork',             10),
  ('cut',    'Cutting',               'Metalwork',             20),
  ('fold',   'Folding',               'Metalwork',             30),
  ('weld',   'Welding',               'Metalwork',             40),
  ('grind',  'Grinding',              'Metalwork',             50),
  ('paint',  'Painting',              'Metalwork',             60),
  ('foam',   'Foaming & fabrication', 'Foaming & fabrication', 70),
  ('finish', 'Finishing',             'Finishing',             80),
  ('load',   'Loading',               'Loading',               90)
on conflict (id) do nothing;

-- steps are no longer a fixed list of four
alter table public.ws_workers drop constraint if exists ws_workers_stage_check;
alter table public.ws_tasks   drop constraint if exists ws_tasks_stage_check;

-- anything still on the old single "metal" step moves to Cutting
update public.ws_workers set stage = 'cut' where stage = 'metal';
update public.ws_tasks   set stage = 'cut' where stage = 'metal';
update public.ws_orders  set stages = array_replace(stages, 'metal', 'cut') where 'metal' = any(stages);
update public.ws_materials set stages = array(select distinct x from unnest(array_remove(stages, 'metal') || array['get','cut','fold','weld','grind','paint']) x)
 where 'metal' = any(stages);


-- ---------- names ----------
create or replace function public.ws_stage_name(s text) returns text
language sql stable security definer set search_path = public as $$
  select coalesce((select name from public.ws_steps where id = s),
    case s when 'metal' then 'Metalwork' when 'foam' then 'Foaming & fabrication'
           when 'finish' then 'Finishing' when 'load' then 'Loading' else s end);
$$;

create or replace function public.ws_step_group(s text) returns text
language sql stable security definer set search_path = public as $$
  select coalesce((select grp from public.ws_steps where id = s), public.ws_stage_name(s));
$$;


-- ---------- owner: edit the steps ----------
create or replace function public.ws_save_step(p jsonb) returns void
language plpgsql security definer set search_path = public as $$
declare v_name text := left(trim(coalesce(p->>'name','')), 40); v_grp text := left(trim(coalesce(nullif(p->>'grp',''), p->>'name', '')), 40);
begin
  perform public.ws_need_owner();
  if length(v_name) = 0 then raise exception 'Add a name for the step'; end if;
  if p->>'id' is null then
    insert into public.ws_steps (id, name, grp, sort)
    values ('s' || substr(md5(random()::text || clock_timestamp()::text), 1, 6), v_name, v_grp,
            coalesce((select max(sort) from public.ws_steps), 0) + 10);
    perform public.ws_note('info', 'New workshop step: ' || v_name);
  else
    if coalesce((p->>'active')::boolean, true) = false and exists (select 1 from public.ws_tasks where stage = p->>'id' and status in ('queued','assigned','working')) then
      raise exception 'Some jobs are still waiting in this step. Finish them first.';
    end if;
    update public.ws_steps set name = v_name, grp = v_grp, active = coalesce((p->>'active')::boolean, active) where id = p->>'id';
  end if;
end $$;

create or replace function public.ws_move_step(p_id text, p_up boolean) returns void
language plpgsql security definer set search_path = public as $$
declare a public.ws_steps; b public.ws_steps;
begin
  perform public.ws_need_owner();
  select * into a from public.ws_steps where id = p_id;
  if p_up then select * into b from public.ws_steps where sort < a.sort order by sort desc limit 1;
  else select * into b from public.ws_steps where sort > a.sort order by sort limit 1; end if;
  if b.id is null then return; end if;
  update public.ws_steps set sort = b.sort where id = a.id;
  update public.ws_steps set sort = a.sort where id = b.id;
end $$;


-- ---------- orders use whatever steps exist ----------
create or replace function public.ws_create_order(p jsonb) returns text
language plpgsql security definer set search_path = public as $$
declare o_id uuid; v_ref text; st text[]; i int; first_task uuid; t_id uuid;
begin
  perform public.ws_need_owner();
  select array_agg(s.id order by s.sort) into st
    from public.ws_steps s where s.active and s.id in (select jsonb_array_elements_text(p->'stages'));
  if st is null or array_length(st, 1) is null then raise exception 'Pick at least one step'; end if;
  if length(trim(coalesce(p->>'customer',''))) = 0 or length(trim(coalesce(p->>'item',''))) = 0 then raise exception 'Customer and item are required'; end if;
  v_ref := 'KT-' || nextval('public.ws_ref_seq');
  insert into public.ws_orders (ref, customer, item, qty, deadline, urgency, notes, stages)
  values (v_ref, left(trim(p->>'customer'), 120), left(trim(p->>'item'), 120), greatest(1, (p->>'qty')::int),
          coalesce((p->>'deadline')::date, current_date + 7),
          case when p->>'urgency' in ('urgent','high','normal') then p->>'urgency' else 'normal' end,
          nullif(left(trim(coalesce(p->>'notes','')), 500), ''), st)
  returning id into o_id;
  for i in 1 .. array_length(st, 1) loop
    insert into public.ws_tasks (order_id, step, stage) values (o_id, i, st[i]) returning id into t_id;
    if i = 1 then first_task := t_id; end if;
  end loop;
  perform public.ws_note(case when p->>'urgency' = 'urgent' then 'alert' else 'info' end,
    'New order ' || v_ref || ': ' || (p->>'qty') || ' × ' || trim(p->>'item') || ' for ' || trim(p->>'customer'), o_id);
  perform public.ws_enqueue(first_task);
  perform public.ws_release(st[1]);
  return v_ref;
end $$;

create or replace function public.ws_save_worker(p jsonb) returns void
language plpgsql security definer set search_path = public as $$
declare w public.ws_workers; v_name text := left(trim(coalesce(p->>'name','')), 60); v_stage text := p->>'stage';
begin
  perform public.ws_need_owner();
  if length(v_name) = 0 then raise exception 'Add a name'; end if;
  if not exists (select 1 from public.ws_steps where id = v_stage and active) then raise exception 'Pick a step'; end if;
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


-- ---------- the customer sees the simple groups ----------
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
             coalesce(public.ws_step_group(cur.stage) ||
                      case when public.ws_step_group(cur.stage) <> public.ws_stage_name(cur.stage) then ' (' || lower(public.ws_stage_name(cur.stage)) || ')' else '' end,
                      'finished'),
             ' · ' order by o.created_at)
      into note
      from public.ws_orders o
      left join lateral (select t.stage from public.ws_tasks t where t.order_id = o.id and t.status <> 'done' order by t.step limit 1) cur on true
     where o.source_order_id = p_src;
    update public.orders set status = 'workshop', status_note = 'Now in the workshop: ' || note || '. This updates by itself as we work.' where id = p_src;
  end if;
end $$;

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
                              'steps', (select jsonb_agg(jsonb_build_object('name', g.grp, 'status', g.st) order by g.first_step)
                                          from (select public.ws_step_group(t.stage) grp, min(t.step) first_step,
                                                       case when bool_and(t.status = 'done') then 'done'
                                                            when bool_or(t.status in ('working','assigned','done')) then 'working'
                                                            else 'waiting' end st
                                                  from public.ws_tasks t where t.order_id = o.id group by 1) g)) order by o.created_at), '[]'::jsonb)
                           from public.ws_orders o where o.source_order_id = w.id))
  from public.orders w
  where w.order_no = upper(trim(p_order_no))
    and length(regexp_replace(coalesce(p_phone, ''), '\D', '', 'g')) >= 9
    and right(w.phone_digits, 9) = right(regexp_replace(coalesce(p_phone, ''), '\D', '', 'g'), 9)
  limit 1;
$$;

revoke all on function public.ws_step_group(text) from public, anon;
revoke all on function public.ws_save_step(jsonb), public.ws_move_step(text, boolean) from public, anon;
grant execute on function public.ws_save_step(jsonb)          to authenticated;
grant execute on function public.ws_move_step(text, boolean)  to authenticated;
grant execute on function public.ws_save_worker(jsonb)        to authenticated;
grant execute on function public.ws_create_order(jsonb)       to authenticated;
revoke all on function public.track_order(text, text) from public;
grant execute on function public.track_order(text, text) to anon, authenticated;


-- #####################################################################
-- ##  FILE: update-6-attendance.sql
-- #####################################################################

-- =====================================================================
--  KARTECH UPDATE 6: who is here today + the owner can give a job to anyone
--  Paste ALL of this into Supabase → SQL Editor → New query → Run.
--  Safe to run again. Run update-5-steps.sql first.
--
--  • "Away today": that worker gets no jobs today. Their unfinished job goes
--    back to the front of the line for someone else. Resets by itself tomorrow.
--  • "Can also do": a worker can cover other steps when they have nothing
--    to do in their own step (e.g. a painter who can also grind).
--  • "Give to…": the owner can hand any step of any order to a free worker,
--    even from another step (someone stepping up).
-- =====================================================================

alter table public.ws_workers add column if not exists away_on date;
alter table public.ws_workers add column if not exists covers text[] not null default '{}';
grant select (away_on, covers) on public.ws_workers to authenticated;

create or replace function public.ws_is_here(w public.ws_workers) returns boolean
language sql stable as $$ select w.active and (w.away_on is null or w.away_on <> public.ws_today()); $$;


-- ---------- handing out work ----------
-- a free worker takes the top job of a step: their own step first,
-- a step they "can also do" only when their own line is empty
create or replace function public.ws_release(p_stage text) returns void
language plpgsql security definer set search_path = public as $$
declare w record; tid uuid; o public.ws_orders;
begin
  for w in select * from public.ws_workers wk
            where wk.active and (wk.away_on is null or wk.away_on <> public.ws_today()) and wk.task_id is null
              and (wk.stage = p_stage or (p_stage = any(wk.covers)
                   and not exists (select 1 from public.ws_tasks q where q.stage = wk.stage and q.status = 'queued')))
            order by (wk.stage = p_stage) desc, wk.created_at loop
    select id into tid from public.ws_tasks where stage = p_stage and status = 'queued' order by rank limit 1 for update skip locked;
    if tid is null then
      if w.stage = p_stage and not w.waiting_logged then
        perform public.ws_note('warn', w.name || ' (' || public.ws_stage_name(p_stage) || ') has no work waiting');
        update public.ws_workers set waiting_logged = true where id = w.id;
      end if;
      exit;
    end if;
    update public.ws_tasks set status = 'assigned', worker_id = w.id, assigned_at = now() where id = tid;
    update public.ws_workers set task_id = tid, waiting_logged = false where id = w.id;
    select o2.* into o from public.ws_orders o2 join public.ws_tasks t on t.order_id = o2.id where t.id = tid;
    perform public.ws_note('info', w.name || ' got the next job: ' || o.ref || ' · ' || public.ws_stage_name(p_stage)
      || case when w.stage <> p_stage then ' (covering)' else '' end, o.id);
  end loop;
end $$;

create or replace function public.ws_release_all() returns void
language plpgsql security definer set search_path = public as $$
declare s record;
begin
  for s in select id from public.ws_steps where active order by sort loop
    perform public.ws_release(s.id);
  end loop;
end $$;

-- finishing now lets everyone free look for work (including covering)
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
  else
    perform public.ws_note('good', o.ref || ' is finished and loaded. Ready for delivery.', o.id);
  end if;
  perform public.ws_release_all();
  perform public.ws_sync_source(o.source_order_id);
end $$;


-- ---------- owner: away today / back ----------
create or replace function public.ws_set_away(p_worker uuid, p_away boolean) returns void
language plpgsql security definer set search_path = public as $$
declare w public.ws_workers; o public.ws_orders; t public.ws_tasks;
begin
  perform public.ws_need_owner();
  select * into w from public.ws_workers where id = p_worker;
  if w.id is null then raise exception 'Worker not found'; end if;
  if p_away then
    if w.task_id is not null then
      select * into t from public.ws_tasks where id = w.task_id;
      update public.ws_tasks set status = 'queued', worker_id = null, assigned_at = null,
        problem_reason = null, problem_stopped = null, problem_at = null, problem_ack_at = null,
        rank = (select coalesce(min(rank), 1) - 1 from public.ws_tasks where stage = t.stage and status = 'queued')
      where id = t.id;
      select * into o from public.ws_orders where id = t.order_id;
    end if;
    update public.ws_workers set away_on = public.ws_today(), task_id = null where id = w.id;
    delete from public.ws_sessions where worker_id = w.id;
    perform public.ws_note('warn', w.name || ' is away today' || coalesce('. ' || o.ref || ' went back to the front of the line', ''), o.id);
  else
    update public.ws_workers set away_on = null, waiting_logged = false where id = w.id;
    perform public.ws_note('info', w.name || ' is here today');
  end if;
  perform public.ws_release_all();
end $$;


-- ---------- owner: give a step of an order to a specific worker ----------
create or replace function public.ws_give_task(p_task uuid, p_worker uuid) returns void
language plpgsql security definer set search_path = public as $$
declare t public.ws_tasks; w public.ws_workers; o public.ws_orders; busy text;
begin
  perform public.ws_need_owner();
  select * into t from public.ws_tasks where id = p_task for update;
  if t.id is null or t.status = 'done' then raise exception 'This step is already finished'; end if;
  if t.status = 'waiting' then raise exception 'This step is not ready yet. The step before it is not finished.'; end if;
  select * into w from public.ws_workers where id = p_worker for update;
  if w.id is null or not public.ws_is_here(w) then raise exception 'That worker is away or switched off'; end if;
  if t.worker_id = w.id then return; end if;
  if w.task_id is not null then
    select o2.ref into busy from public.ws_tasks x join public.ws_orders o2 on o2.id = x.order_id where x.id = w.task_id;
    raise exception '% is busy on %. Wait until they finish, or mark them away.', w.name, coalesce(busy, 'another job');
  end if;
  if t.worker_id is not null then
    update public.ws_workers set task_id = null where id = t.worker_id;
  end if;
  update public.ws_tasks set status = 'assigned', worker_id = w.id, assigned_at = now(), started_at = null where id = t.id;
  update public.ws_workers set task_id = t.id, waiting_logged = false where id = w.id;
  select * into o from public.ws_orders where id = t.order_id;
  perform public.ws_note('info', 'Owner gave ' || o.ref || ' · ' || public.ws_stage_name(t.stage) || ' to ' || w.name, o.id);
  perform public.ws_release_all();
end $$;


-- ---------- worker details now include "can also do" ----------
create or replace function public.ws_save_worker(p jsonb) returns void
language plpgsql security definer set search_path = public as $$
declare w public.ws_workers; v_name text := left(trim(coalesce(p->>'name','')), 60); v_stage text := p->>'stage';
        v_covers text[] := coalesce(array(select x from jsonb_array_elements_text(coalesce(p->'covers','[]'::jsonb)) x
                                          where x <> coalesce(p->>'stage','') and exists (select 1 from public.ws_steps s where s.id = x)), '{}');
begin
  perform public.ws_need_owner();
  if length(v_name) = 0 then raise exception 'Add a name'; end if;
  if not exists (select 1 from public.ws_steps where id = v_stage and active) then raise exception 'Pick a step'; end if;
  if p->>'id' is null then
    insert into public.ws_workers (name, stage, covers, pin_hash) values (v_name, v_stage, v_covers, extensions.crypt(gen_random_uuid()::text, extensions.gen_salt('bf')));
    perform public.ws_note('good', 'New worker added: ' || v_name || ', ' || public.ws_stage_name(v_stage));
  else
    select * into w from public.ws_workers where id = (p->>'id')::uuid;
    update public.ws_workers set name = v_name, stage = case when w.task_id is null then v_stage else w.stage end,
      covers = v_covers, failed_tries = 0, locked_until = null where id = w.id;
    perform public.ws_note('info', 'Worker updated: ' || v_name);
  end if;
  perform public.ws_release_all();
end $$;


-- ---------- workshop screen: people away today are not listed ----------
create or replace function public.ws_station_workers() returns table (id uuid, name text, stage text)
language plpgsql stable security definer set search_path = public as $$
begin
  if not (public.ws_is_station() or public.is_admin()) then raise exception 'This computer is not set up as the workshop PC'; end if;
  return query select w.id, w.name, w.stage from public.ws_workers w
   where w.active and (w.away_on is null or w.away_on <> public.ws_today()) order by w.name;
end $$;

revoke all on function public.ws_release_all() from public, anon, authenticated;
revoke all on function public.ws_set_away(uuid, boolean), public.ws_give_task(uuid, uuid) from public, anon;
grant execute on function public.ws_set_away(uuid, boolean) to authenticated;
grant execute on function public.ws_give_task(uuid, uuid)   to authenticated;
grant execute on function public.ws_save_worker(jsonb)      to authenticated;
grant execute on function public.ws_finish(uuid)            to authenticated;
grant execute on function public.ws_station_workers()       to authenticated;


-- #####################################################################
-- ##  FILE: update-7-checkin.sql
-- #####################################################################

-- =====================================================================
--  KARTECH UPDATE 7: morning check-in by the foreman + tools per trade
--  Paste ALL of this into Supabase → SQL Editor → New query → Run.
--  Safe to run again. Run update-6-attendance.sql first.
--
--  • Every name is on the foreman page. When a worker walks in, the foreman
--    taps their name → they are "in" for today → their trade's tools pop up
--    → he ticks the tools they take.
--  • Only workers who are in today get jobs. Nobody ticked in = not here.
--  • Each tool can be marked for the trades that use it (Cutting, Welding…),
--    so the foreman only sees the right tools for each worker.
-- =====================================================================

alter table public.ws_workers add column if not exists arrived_on date;
alter table public.ws_workers add column if not exists arrived_at timestamptz;
grant select (arrived_on, arrived_at) on public.ws_workers to authenticated;

alter table public.ws_tools add column if not exists stages text[] not null default '{}';

-- "here" now means: switched on, ticked in today, and not marked away
create or replace function public.ws_is_here(w public.ws_workers) returns boolean
language sql stable as $$
  select w.active and w.arrived_on = public.ws_today() and (w.away_on is null or w.away_on <> public.ws_today());
$$;

create or replace function public.ws_release(p_stage text) returns void
language plpgsql security definer set search_path = public as $$
declare w record; tid uuid; o public.ws_orders;
begin
  for w in select * from public.ws_workers wk
            where wk.active and wk.arrived_on = public.ws_today()
              and (wk.away_on is null or wk.away_on <> public.ws_today()) and wk.task_id is null
              and (wk.stage = p_stage or (p_stage = any(wk.covers)
                   and not exists (select 1 from public.ws_tasks q where q.stage = wk.stage and q.status = 'queued')))
            order by (wk.stage = p_stage) desc, wk.arrived_at nulls last, wk.created_at loop
    select id into tid from public.ws_tasks where stage = p_stage and status = 'queued' order by rank limit 1 for update skip locked;
    if tid is null then
      if w.stage = p_stage and not w.waiting_logged then
        perform public.ws_note('warn', w.name || ' (' || public.ws_stage_name(p_stage) || ') has no work waiting');
        update public.ws_workers set waiting_logged = true where id = w.id;
      end if;
      exit;
    end if;
    update public.ws_tasks set status = 'assigned', worker_id = w.id, assigned_at = now() where id = tid;
    update public.ws_workers set task_id = tid, waiting_logged = false where id = w.id;
    select o2.* into o from public.ws_orders o2 join public.ws_tasks t on t.order_id = o2.id where t.id = tid;
    perform public.ws_note('info', w.name || ' got the next job: ' || o.ref || ' · ' || public.ws_stage_name(p_stage)
      || case when w.stage <> p_stage then ' (covering)' else '' end, o.id);
  end loop;
end $$;

-- workshop screen lists only people who are in today
create or replace function public.ws_station_workers() returns table (id uuid, name text, stage text)
language plpgsql stable security definer set search_path = public as $$
begin
  if not (public.ws_is_station() or public.is_admin()) then raise exception 'This computer is not set up as the workshop PC'; end if;
  return query select w.id, w.name, w.stage from public.ws_workers w
   where w.active and w.arrived_on = public.ws_today() and (w.away_on is null or w.away_on <> public.ws_today()) order by w.name;
end $$;

-- the owner's "Back today" also counts as ticked in
create or replace function public.ws_set_away(p_worker uuid, p_away boolean) returns void
language plpgsql security definer set search_path = public as $$
declare w public.ws_workers; o public.ws_orders; t public.ws_tasks;
begin
  perform public.ws_need_owner();
  select * into w from public.ws_workers where id = p_worker;
  if w.id is null then raise exception 'Worker not found'; end if;
  if p_away then
    if w.task_id is not null then
      select * into t from public.ws_tasks where id = w.task_id;
      update public.ws_tasks set status = 'queued', worker_id = null, assigned_at = null,
        problem_reason = null, problem_stopped = null, problem_at = null, problem_ack_at = null,
        rank = (select coalesce(min(rank), 1) - 1 from public.ws_tasks where stage = t.stage and status = 'queued')
      where id = t.id;
      select * into o from public.ws_orders where id = t.order_id;
    end if;
    update public.ws_workers set away_on = public.ws_today(), arrived_on = null, task_id = null where id = w.id;
    delete from public.ws_sessions where worker_id = w.id;
    perform public.ws_note('warn', w.name || ' is away today' || coalesce('. ' || o.ref || ' went back to the front of the line', ''), o.id);
  else
    update public.ws_workers set away_on = null, arrived_on = public.ws_today(), arrived_at = coalesce(case when arrived_on = public.ws_today() then arrived_at end, now()),
      waiting_logged = false where id = w.id;
    perform public.ws_note('info', w.name || ' is here today');
  end if;
  perform public.ws_release_all();
end $$;


-- ---------- foreman: tick a worker in (or undo) ----------
create or replace function public.ws_foreman_arrive(p_pin text, p_worker uuid, p_in boolean) returns void
language plpgsql security definer set search_path = public as $$
declare w public.ws_workers; t public.ws_tasks;
begin
  perform public.ws_foreman_ok(p_pin);
  select * into w from public.ws_workers where id = p_worker and active;
  if w.id is null then raise exception 'Worker not found'; end if;
  if p_in then
    if w.arrived_on = public.ws_today() then return; end if;
    update public.ws_workers set arrived_on = public.ws_today(), arrived_at = now(), away_on = null, waiting_logged = false where id = w.id;
    perform public.ws_note('good', w.name || ' arrived at ' || to_char(now() at time zone 'Africa/Nairobi', 'HH24:MI'));
  else
    -- undo (ticked by mistake): give back any job they were given
    if w.task_id is not null then
      select * into t from public.ws_tasks where id = w.task_id;
      if t.status = 'assigned' then
        update public.ws_tasks set status = 'queued', worker_id = null, assigned_at = null,
          rank = (select coalesce(min(rank), 1) - 1 from public.ws_tasks where stage = t.stage and status = 'queued') where id = t.id;
        update public.ws_workers set task_id = null where id = w.id;
      end if;
    end if;
    update public.ws_workers set arrived_on = null, arrived_at = null where id = w.id and (task_id is null);
    if exists (select 1 from public.ws_workers where id = w.id and arrived_on is not null) then
      raise exception '% has already started a job, so cannot be unticked', w.name;
    end if;
    perform public.ws_note('info', w.name || ' unticked (not in)');
  end if;
  perform public.ws_release_all();
end $$;


-- ---------- tools: which trades use them ----------
create or replace function public.ws_save_tool(p jsonb) returns void
language plpgsql security definer set search_path = public as $$
declare v_name text := left(trim(coalesce(p->>'name','')), 60);
        v_stages text[] := coalesce(array(select jsonb_array_elements_text(coalesce(p->'stages','[]'::jsonb))), '{}');
begin
  perform public.ws_need_owner();
  if length(v_name) = 0 then raise exception 'Add a name, e.g. Grinder 1'; end if;
  if p->>'id' is null then
    insert into public.ws_tools (name, usual_worker, stages) values (v_name, nullif(p->>'usual_worker','')::uuid, v_stages);
    perform public.ws_note('info', 'New tool added: ' || v_name);
  else
    update public.ws_tools set name = v_name, usual_worker = nullif(p->>'usual_worker','')::uuid, stages = v_stages,
      active = coalesce((p->>'active')::boolean, active)
     where id = (p->>'id')::uuid;
  end if;
end $$;


-- ---------- foreman page data: now with who is in + tool trades ----------
create or replace function public.ws_foreman_open(p_pin text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare today timestamptz := (public.ws_today()::timestamp at time zone 'Africa/Nairobi'); st text;
begin
  st := public.ws_foreman_check(p_pin);
  if st <> 'ok' then return jsonb_build_object('error', st); end if;
  return jsonb_build_object(
    'workers', coalesce((select jsonb_agg(jsonb_build_object('id', w.id, 'name', w.name, 'stage', w.stage,
        'in', coalesce(w.arrived_on = public.ws_today() and (w.away_on is null or w.away_on <> public.ws_today()), false),
        'away', coalesce(w.away_on = public.ws_today(), false),
        'arrived_at', case when w.arrived_on = public.ws_today() then w.arrived_at end,
        'job', (select jsonb_build_object('order_id', o.id, 'ref', o.ref, 'item', o.item, 'qty', o.qty, 'status', t.status)
                  from public.ws_tasks t join public.ws_orders o on o.id = t.order_id where t.id = w.task_id),
        'today', coalesce((select jsonb_agg(jsonb_build_object('material_id', m.id, 'material', m.name, 'unit', m.unit, 'qty', x.q,
                    'last', (select -qty from public.ws_moves z where z.worker_id = w.id and z.material_id = m.id and z.kind = 'out' and z.at >= today order by z.id desc limit 1),
                    'times', x.n) order by m.name)
                  from (select material_id, -sum(qty) q, count(*) filter (where kind = 'out') n from public.ws_moves where worker_id = w.id and kind in ('out','back') and at >= today group by material_id) x
                  join public.ws_materials m on m.id = x.material_id where x.q > 0), '[]'::jsonb))
        order by w.name) from public.ws_workers w where w.active), '[]'::jsonb),
    'tools', coalesce((select jsonb_agg(jsonb_build_object('id', t.id, 'name', t.name, 'usual', t.usual_worker, 'stages', t.stages,
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

-- everyone already working right now counts as in today (so nothing stops when this runs)
update public.ws_workers set arrived_on = public.ws_today(), arrived_at = coalesce(arrived_at, now())
 where active and task_id is not null and arrived_on is null;

revoke all on function public.ws_foreman_arrive(text, uuid, boolean) from public, anon;
grant execute on function public.ws_foreman_arrive(text, uuid, boolean) to authenticated;
grant execute on function public.ws_save_tool(jsonb)            to authenticated;
grant execute on function public.ws_foreman_open(text)          to authenticated;
grant execute on function public.ws_set_away(uuid, boolean)     to authenticated;
grant execute on function public.ws_station_workers()           to authenticated;


-- #####################################################################
-- ##  FILE: update-8-history.sql
-- #####################################################################

-- =====================================================================
--  KARTECH UPDATE 8: History (owner app → History)
--  Paste ALL of this into Supabase → SQL Editor → New query → Run.
--  Safe to run again. Run update-7-checkin.sql first.
--
--  • Keeps a record of who came in each day (and what time), who was away.
--  • One function gives the owner everything that happened on any day:
--    who came, jobs finished, tools taken/returned, materials given, alarms.
-- =====================================================================

-- ---------- attendance book: one line per worker per day ----------
create table if not exists public.ws_attendance (
  day        date not null,
  worker_id  uuid not null references public.ws_workers(id) on delete cascade,
  arrived_at timestamptz,
  away       boolean not null default false,
  primary key (day, worker_id)
);
alter table public.ws_attendance enable row level security;
drop policy if exists "owner reads attendance" on public.ws_attendance;
create policy "owner reads attendance" on public.ws_attendance for select to authenticated using (public.is_admin());
grant select on public.ws_attendance to authenticated;

-- writes itself every time a worker is ticked in / unticked / marked away
create or replace function public.ws_attendance_track() returns trigger
language plpgsql security definer set search_path = public as $$
declare d date := public.ws_today();
begin
  if new.away_on = d then
    insert into public.ws_attendance (day, worker_id, arrived_at, away) values (d, new.id, null, true)
      on conflict (day, worker_id) do update set away = true, arrived_at = null;
  elsif new.arrived_on = d then
    insert into public.ws_attendance (day, worker_id, arrived_at, away) values (d, new.id, coalesce(new.arrived_at, now()), false)
      on conflict (day, worker_id) do update set away = false, arrived_at = coalesce(public.ws_attendance.arrived_at, excluded.arrived_at);
  elsif (old.arrived_on = d or old.away_on = d) then
    delete from public.ws_attendance where day = d and worker_id = new.id;   -- undo / ticked by mistake
  end if;
  return new;
end $$;

drop trigger if exists ws_attendance_track on public.ws_workers;
create trigger ws_attendance_track after update of arrived_on, arrived_at, away_on on public.ws_workers
  for each row execute function public.ws_attendance_track();

-- today so far
insert into public.ws_attendance (day, worker_id, arrived_at, away)
select public.ws_today(), id, case when away_on = public.ws_today() then null else arrived_at end, coalesce(away_on = public.ws_today(), false)
  from public.ws_workers where arrived_on = public.ws_today() or away_on = public.ws_today()
on conflict (day, worker_id) do nothing;


-- ---------- everything that happened on one day ----------
create or replace function public.ws_history(p_day date) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare a timestamptz := (p_day::timestamp at time zone 'Africa/Nairobi');
        b timestamptz := ((p_day + 1)::timestamp at time zone 'Africa/Nairobi');
begin
  perform public.ws_need_owner();
  return jsonb_build_object(
    'day', p_day,
    'attendance', coalesce((select jsonb_agg(jsonb_build_object('worker', x.worker_id, 'at', x.arrived_at, 'away', x.away))
        from public.ws_attendance x where x.day = p_day), '[]'::jsonb),
    'jobs', coalesce((select jsonb_agg(jsonb_build_object('worker', t.worker_id, 'stage', t.stage, 'ref', o.ref, 'item', o.item, 'qty', o.qty,
                'started', t.started_at, 'done', t.done_at) order by t.done_at)
        from public.ws_tasks t join public.ws_orders o on o.id = t.order_id
       where t.status = 'done' and t.done_at >= a and t.done_at < b), '[]'::jsonb),
    'tools', coalesce((select jsonb_agg(jsonb_build_object('tool', tl.name, 'worker', l.worker_id, 'out', l.out_at, 'back', l.back_at) order by l.out_at)
        from public.ws_tool_loans l join public.ws_tools tl on tl.id = l.tool_id
       where (l.out_at >= a and l.out_at < b) or (l.back_at >= a and l.back_at < b)
          or (l.out_at < a and (l.back_at is null or l.back_at >= b) and p_day <= public.ws_today())), '[]'::jsonb),
    'missing', coalesce((select jsonb_agg(jsonb_build_object('tool', tl.name, 'worker', m.worker_id, 'found', m.found_at))
        from public.ws_tool_missing m join public.ws_tools tl on tl.id = m.tool_id where m.since = p_day), '[]'::jsonb),
    'check', (select jsonb_build_object('at', c.done_at, 'missing', c.missing) from public.ws_tool_checks c where c.day = p_day),
    'materials', coalesce((select jsonb_agg(jsonb_build_object('at', mv.at, 'kind', mv.kind, 'qty', mv.qty, 'material', mt.name, 'unit', mt.unit,
                'worker', mv.worker_id, 'note', mv.note) order by mv.at)
        from public.ws_moves mv join public.ws_materials mt on mt.id = mv.material_id
       where mv.at >= a and mv.at < b), '[]'::jsonb),
    'log', coalesce((select jsonb_agg(jsonb_build_object('at', g.at, 'kind', g.kind, 'text', g.text) order by g.id)
        from public.ws_log g where g.at >= a and g.at < b), '[]'::jsonb)
  );
end $$;

revoke all on function public.ws_history(date) from public, anon;
grant execute on function public.ws_history(date) to authenticated;


-- #####################################################################
-- ##  FILE: update-9-edit-orders.sql
-- #####################################################################

-- =====================================================================
--  KARTECH UPDATE 9: pick who does each step + edit or delete an order
--  Paste ALL of this into Supabase → SQL Editor → New query → Run.
--  Safe to run again. Run update-8-history.sql first.
--
--  • New order: for each step, pick 1 or 2 workers (e.g. Cutting → Juma + Otieno).
--    When that step is ready it goes straight to them. Two people = they do it
--    together. Nobody picked = whoever is free. Picked person not in today =
--    anyone free can take it, so work never gets stuck.
--  • Fix the customer, item, how many, deadline, urgency, note, steps or people.
--  • Steps already finished or being worked on stay (they can't be removed).
--  • Delete an order added by mistake. Anyone working on it is freed and
--    gets the next job. Website orders go back to "waiting" on the dashboard.
--  • Every edit and delete is written in History.
-- =====================================================================

-- ---------- who was picked for each step ----------
alter table public.ws_tasks add column if not exists planned uuid[] not null default '{}';

-- save the picked people for an order's steps: {"cut": ["<worker id>", ...], ...}
create or replace function public.ws_set_planned(p_order uuid, p_people jsonb) returns void
language plpgsql security definer set search_path = public as $$
declare t record; ids uuid[];
begin
  if p_people is null or jsonb_typeof(p_people) <> 'object' then return; end if;
  for t in select * from public.ws_tasks where order_id = p_order and status <> 'done' loop
    select coalesce(array_agg(w.id), '{}') into ids from (
      select x::uuid id, min(n) n from jsonb_array_elements_text(coalesce(p_people->t.stage, '[]'::jsonb)) with ordinality e(x, n) group by x) z
      join public.ws_workers w on w.id = z.id and w.active
     where z.n <= 2;
    update public.ws_tasks set planned = ids where id = t.id;
  end loop;
end $$;

-- names of everyone on a task (one or two people)
create or replace function public.ws_task_names(p_task uuid) returns text
language sql stable security definer set search_path = public as $$
  select string_agg(name, ' & ' order by name) from public.ws_workers where task_id = p_task;
$$;

-- who gets the next job: the people picked for it first
create or replace function public.ws_release(p_stage text) returns void
language plpgsql security definer set search_path = public as $$
declare w record; tid uuid; o public.ws_orders; jt public.ws_tasks; mate text;
begin
  for w in select wk.* from public.ws_workers wk
            where public.ws_is_here(wk) and wk.task_id is null
              and (wk.stage = p_stage
                   or exists (select 1 from public.ws_tasks q where q.stage = p_stage and q.status in ('queued','assigned','working') and wk.id = any(q.planned))
                   or (p_stage = any(wk.covers)
                       and not exists (select 1 from public.ws_tasks q where q.stage = wk.stage and q.status = 'queued')))
            order by exists (select 1 from public.ws_tasks q where q.stage = p_stage and q.status in ('queued','assigned','working') and wk.id = any(q.planned)) desc,
                     (wk.stage = p_stage) desc, wk.arrived_at nulls last, wk.created_at loop
    -- 1. picked to help on a job someone already has → join them
    jt := null;
    select * into jt from public.ws_tasks q
     where q.stage = p_stage and q.status in ('assigned','working') and w.id = any(q.planned) and q.worker_id is distinct from w.id
     order by q.rank limit 1;
    if jt.id is not null then
      mate := public.ws_task_names(jt.id);
      update public.ws_workers set task_id = jt.id, waiting_logged = false where id = w.id;
      select * into o from public.ws_orders where id = jt.order_id;
      perform public.ws_note('info', w.name || ' joined ' || coalesce(mate, 'the job') || ' on ' || o.ref || ' · ' || public.ws_stage_name(p_stage), o.id);
      continue;
    end if;
    -- 2. next job in line: his own picked jobs first; skip jobs picked for someone else who is in today
    tid := null;
    select q.id into tid from public.ws_tasks q
     where q.stage = p_stage and q.status = 'queued'
       and (w.id = any(q.planned)
            or ((w.stage = p_stage or p_stage = any(w.covers))
                and not exists (select 1 from public.ws_workers pw where pw.id = any(q.planned) and public.ws_is_here(pw))))
     order by (w.id = any(q.planned)) desc, q.rank limit 1 for update skip locked;
    if tid is null then
      if w.stage = p_stage and not w.waiting_logged
         and not exists (select 1 from public.ws_tasks q where q.stage = p_stage and q.status = 'queued') then
        perform public.ws_note('warn', w.name || ' (' || public.ws_stage_name(p_stage) || ') has no work waiting');
        update public.ws_workers set waiting_logged = true where id = w.id;
      end if;
      continue;
    end if;
    update public.ws_tasks set status = 'assigned', worker_id = w.id, assigned_at = now() where id = tid;
    update public.ws_workers set task_id = tid, waiting_logged = false where id = w.id;
    select o2.* into o from public.ws_orders o2 join public.ws_tasks t on t.order_id = o2.id where t.id = tid;
    perform public.ws_note('info', w.name || ' got the next job: ' || o.ref || ' · ' || public.ws_stage_name(p_stage)
      || case when w.stage <> p_stage and not exists (select 1 from public.ws_tasks where id = tid and w.id = any(planned)) then ' (covering)' else '' end, o.id);
  end loop;
end $$;

-- finishing frees everyone on the job
create or replace function public.ws_finish(p_token uuid) returns void
language plpgsql security definer set search_path = public as $$
declare w public.ws_workers; t public.ws_tasks; o public.ws_orders; nt uuid; who text;
begin
  w := public.ws_me(p_token);
  select * into t from public.ws_tasks where id = w.task_id;
  if t.id is null then return; end if;
  select * into o from public.ws_orders where id = t.order_id;
  who := public.ws_task_names(t.id);
  update public.ws_tasks set status = 'done', done_at = now(),
    problem_reason = null, problem_stopped = null, problem_at = null, problem_ack_at = null where id = t.id;
  update public.ws_workers set task_id = null, waiting_logged = false where task_id = t.id;
  perform public.ws_note('good', coalesce(who, w.name) || ' finished ' || o.ref || ' · ' || public.ws_stage_name(t.stage), o.id);
  select id into nt from public.ws_tasks where order_id = o.id and step = t.step + 1;
  if nt is not null then
    perform public.ws_enqueue(nt);
  else
    perform public.ws_note('good', o.ref || ' is finished and loaded. Ready for delivery.', o.id);
  end if;
  perform public.ws_release_all();
  perform public.ws_sync_source(o.source_order_id);
end $$;

-- the job card also says who you work with
create or replace function public.ws_my_job(p_token uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare w public.ws_workers; t public.ws_tasks; o public.ws_orders; nxt record; after_stage text; mates text;
begin
  w := public.ws_me(p_token);
  if w.task_id is not null then
    select * into t from public.ws_tasks where id = w.task_id;
    select * into o from public.ws_orders where id = t.order_id;
    after_stage := o.stages[t.step + 1];
    select string_agg(name, ' & ' order by name) into mates from public.ws_workers where task_id = t.id and id <> w.id;
  end if;
  select o2.ref, o2.qty, o2.item into nxt from public.ws_tasks q join public.ws_orders o2 on o2.id = q.order_id
   where q.stage = w.stage and q.status = 'queued' order by q.rank limit 1;
  return jsonb_build_object(
    'worker', jsonb_build_object('name', w.name, 'stage', w.stage),
    'task', case when t.id is null then null else jsonb_build_object(
      'status', t.status, 'stage', t.stage, 'problem_reason', t.problem_reason, 'problem_stopped', t.problem_stopped,
      'problem_ack', t.problem_ack_at is not null, 'with', mates) end,
    'order', case when o.id is null then null else jsonb_build_object(
      'ref', o.ref, 'item', o.item, 'qty', o.qty, 'deadline', o.deadline, 'urgency', o.urgency, 'notes', o.notes) end,
    'after', after_stage,
    'next', case when nxt.ref is null then null else jsonb_build_object('ref', nxt.ref, 'qty', nxt.qty, 'item', nxt.item) end);
end $$;

-- hand a job to the partner (if there is one) instead of sending it back to the line
create or replace function public.ws_leave_task(p_worker uuid) returns text
language plpgsql security definer set search_path = public as $$
declare w public.ws_workers; t public.ws_tasks; mate uuid; o public.ws_orders;
begin
  select * into w from public.ws_workers where id = p_worker;
  if w.task_id is null then return null; end if;
  select * into t from public.ws_tasks where id = w.task_id;
  select * into o from public.ws_orders where id = t.order_id;
  update public.ws_workers set task_id = null where id = w.id;
  select id into mate from public.ws_workers where task_id = t.id limit 1;
  if mate is not null then
    update public.ws_tasks set worker_id = mate where id = t.id and worker_id = w.id;
    return null;
  end if;
  update public.ws_tasks set status = 'queued', worker_id = null, assigned_at = null,
    problem_reason = null, problem_stopped = null, problem_at = null, problem_ack_at = null,
    rank = (select coalesce(min(rank), 1) - 1 from public.ws_tasks where stage = t.stage and status = 'queued')
  where id = t.id;
  return o.ref;
end $$;

create or replace function public.ws_set_away(p_worker uuid, p_away boolean) returns void
language plpgsql security definer set search_path = public as $$
declare w public.ws_workers; back text; oid uuid;
begin
  perform public.ws_need_owner();
  select * into w from public.ws_workers where id = p_worker;
  if w.id is null then raise exception 'Worker not found'; end if;
  if p_away then
    select order_id into oid from public.ws_tasks where id = w.task_id;
    back := public.ws_leave_task(w.id);
    update public.ws_workers set away_on = public.ws_today(), arrived_on = null, task_id = null where id = w.id;
    delete from public.ws_sessions where worker_id = w.id;
    perform public.ws_note('warn', w.name || ' is away today' || coalesce('. ' || back || ' went back to the front of the line', ''), oid);
  else
    update public.ws_workers set away_on = null, arrived_on = public.ws_today(), arrived_at = coalesce(case when arrived_on = public.ws_today() then arrived_at end, now()),
      waiting_logged = false where id = w.id;
    perform public.ws_note('info', w.name || ' is here today');
  end if;
  perform public.ws_release_all();
end $$;

create or replace function public.ws_foreman_arrive(p_pin text, p_worker uuid, p_in boolean) returns void
language plpgsql security definer set search_path = public as $$
declare w public.ws_workers; t public.ws_tasks;
begin
  perform public.ws_foreman_ok(p_pin);
  select * into w from public.ws_workers where id = p_worker and active;
  if w.id is null then raise exception 'Worker not found'; end if;
  if p_in then
    if w.arrived_on = public.ws_today() then return; end if;
    update public.ws_workers set arrived_on = public.ws_today(), arrived_at = now(), away_on = null, waiting_logged = false where id = w.id;
    perform public.ws_note('good', w.name || ' arrived at ' || to_char(now() at time zone 'Africa/Nairobi', 'HH24:MI'));
  else
    if w.task_id is not null then
      select * into t from public.ws_tasks where id = w.task_id;
      if t.status = 'working' and t.worker_id = w.id and not exists (select 1 from public.ws_workers where task_id = t.id and id <> w.id) then
        raise exception '% has already started a job, so cannot be unticked', w.name;
      end if;
      perform public.ws_leave_task(w.id);
    end if;
    update public.ws_workers set arrived_on = null, arrived_at = null, task_id = null where id = w.id;
    perform public.ws_note('info', w.name || ' unticked (not in)');
  end if;
  perform public.ws_release_all();
end $$;

-- new order: steps + the people picked for them
create or replace function public.ws_create_order(p jsonb) returns text
language plpgsql security definer set search_path = public as $$
declare o_id uuid; v_ref text; st text[]; i int; first_task uuid; t_id uuid;
begin
  perform public.ws_need_owner();
  select array_agg(s.id order by s.sort) into st
    from public.ws_steps s where s.active and s.id in (select jsonb_array_elements_text(p->'stages'));
  if st is null or array_length(st, 1) is null then raise exception 'Pick at least one step'; end if;
  if length(trim(coalesce(p->>'customer',''))) = 0 or length(trim(coalesce(p->>'item',''))) = 0 then raise exception 'Customer and item are required'; end if;
  v_ref := 'KT-' || nextval('public.ws_ref_seq');
  insert into public.ws_orders (ref, customer, item, qty, deadline, urgency, notes, stages)
  values (v_ref, left(trim(p->>'customer'), 120), left(trim(p->>'item'), 120), greatest(1, (p->>'qty')::int),
          coalesce((p->>'deadline')::date, current_date + 7),
          case when p->>'urgency' in ('urgent','high','normal') then p->>'urgency' else 'normal' end,
          nullif(left(trim(coalesce(p->>'notes','')), 500), ''), st)
  returning id into o_id;
  for i in 1 .. array_length(st, 1) loop
    insert into public.ws_tasks (order_id, step, stage) values (o_id, i, st[i]) returning id into t_id;
    if i = 1 then first_task := t_id; end if;
  end loop;
  perform public.ws_set_planned(o_id, p->'people');
  perform public.ws_note(case when p->>'urgency' = 'urgent' then 'alert' else 'info' end,
    'New order ' || v_ref || ': ' || (p->>'qty') || ' × ' || trim(p->>'item') || ' for ' || trim(p->>'customer'), o_id);
  perform public.ws_enqueue(first_task);
  perform public.ws_release_all();
  return v_ref;
end $$;

create or replace function public.ws_edit_order(p jsonb) returns void
language plpgsql security definer set search_path = public as $$
declare o public.ws_orders; v_id uuid := (p->>'id')::uuid;
        new_st text[]; t record; started_sort int; i int := 0; cur public.ws_tasks;
        v_cust text := left(trim(coalesce(p->>'customer','')), 120);
        v_item text := left(trim(coalesce(p->>'item','')), 120);
        v_qty int := greatest(1, coalesce((p->>'qty')::int, 1));
        v_urg text := case when p->>'urgency' in ('urgent','high','normal') then p->>'urgency' else 'normal' end;
        changes text[] := '{}';
begin
  perform public.ws_need_owner();
  select * into o from public.ws_orders where id = v_id for update;
  if o.id is null then raise exception 'Order not found'; end if;
  if o.delivered_at is not null then raise exception 'This order is already delivered'; end if;
  if length(v_cust) = 0 or length(v_item) = 0 then raise exception 'Customer and item are required'; end if;

  -- steps: keep the order of the workshop steps
  select array_agg(s.id order by s.sort) into new_st
    from public.ws_steps s where s.id in (select jsonb_array_elements_text(coalesce(p->'stages', to_jsonb(o.stages))));
  -- steps already done or being worked on can't be removed
  select coalesce(array_agg(x order by s.sort), new_st) into new_st from (
     select unnest(coalesce(new_st, '{}')) x
     union select stage from public.ws_tasks where order_id = o.id and status in ('done','assigned','working')) u
     join public.ws_steps s on s.id = u.x;
  if new_st is null or array_length(new_st, 1) is null then raise exception 'Pick at least one step'; end if;

  -- a new step can't go before a step someone has already started
  select max(s.sort) into started_sort from public.ws_tasks tk join public.ws_steps s on s.id = tk.stage
   where tk.order_id = o.id and tk.status in ('done','assigned','working');
  if exists (select 1 from unnest(new_st) x join public.ws_steps s on s.id = x
              where s.sort < coalesce(started_sort, -1e9)
                and not exists (select 1 from public.ws_tasks tk where tk.order_id = o.id and tk.stage = x)) then
    raise exception 'You can only add steps that come after the work already done';
  end if;

  if o.customer <> v_cust then changes := changes || ('customer → ' || v_cust); end if;
  if o.item <> v_item then changes := changes || ('item → ' || v_item); end if;
  if o.qty <> v_qty then changes := changes || ('how many ' || o.qty || ' → ' || v_qty); end if;
  if p->>'deadline' is not null and o.deadline <> (p->>'deadline')::date then changes := changes || ('deadline → ' || to_char((p->>'deadline')::date, 'DD Mon YYYY')); end if;
  if o.urgency <> v_urg then changes := changes || ('urgency → ' || v_urg); end if;
  if coalesce(o.notes,'') <> coalesce(nullif(left(trim(coalesce(p->>'notes','')), 500), ''), '') then changes := changes || 'note'::text; end if;
  if o.stages <> new_st then changes := changes || 'steps'::text; end if;

  update public.ws_orders set customer = v_cust, item = v_item, qty = v_qty,
    deadline = coalesce((p->>'deadline')::date, deadline), urgency = v_urg,
    notes = nullif(left(trim(coalesce(p->>'notes','')), 500), ''), stages = new_st
   where id = o.id;

  -- remove steps that were unticked (only ones nobody started)
  delete from public.ws_tasks where order_id = o.id and status in ('waiting','queued') and not (stage = any(new_st));
  -- add new steps
  insert into public.ws_tasks (order_id, step, stage)
  select o.id, 0, x from unnest(new_st) x where not exists (select 1 from public.ws_tasks tk where tk.order_id = o.id and tk.stage = x);
  -- number them again in workshop order
  for t in select tk.id from public.ws_tasks tk join public.ws_steps s on s.id = tk.stage where tk.order_id = o.id order by s.sort loop
    i := i + 1; update public.ws_tasks set step = i where id = t.id;
  end loop;

  perform public.ws_set_planned(o.id, p->'people');

  -- the first unfinished step is the one in line (unless someone already has it)
  select * into cur from public.ws_tasks where order_id = o.id and status <> 'done' order by step limit 1;
  if cur.id is not null and cur.status not in ('assigned','working') then
    update public.ws_tasks set status = 'waiting' where order_id = o.id and status = 'queued' and id <> cur.id;
    perform public.ws_enqueue(cur.id);
  end if;
  -- new deadline/urgency: put its place in line right again
  if v_urg = 'urgent' and o.urgency <> 'urgent' then
    for t in select * from public.ws_tasks where order_id = o.id and status = 'queued' loop
      update public.ws_tasks set rank = (select coalesce(min(rank), 1) - 1 from public.ws_tasks where stage = t.stage and status = 'queued') where id = t.id;
    end loop;
  elsif o.urgency <> v_urg or o.deadline <> coalesce((p->>'deadline')::date, o.deadline) then
    for t in select id from public.ws_tasks where order_id = o.id and status = 'queued' loop perform public.ws_enqueue(t.id); end loop;
  end if;

  if array_length(changes, 1) > 0 then
    perform public.ws_note('info', o.ref || ' edited: ' || array_to_string(changes, ', '), o.id);
  end if;
  if not exists (select 1 from public.ws_tasks where order_id = o.id and status <> 'done') then
    perform public.ws_note('good', o.ref || ' is finished. Ready for delivery.', o.id);
  end if;
  perform public.ws_sync_source(o.source_order_id);
  perform public.ws_release_all();
end $$;


create or replace function public.ws_delete_order(p_order uuid) returns void
language plpgsql security definer set search_path = public as $$
declare o public.ws_orders;
begin
  perform public.ws_need_owner();
  select * into o from public.ws_orders where id = p_order for update;
  if o.id is null then raise exception 'Order not found'; end if;
  -- free anyone holding a job from this order
  update public.ws_workers set task_id = null, waiting_logged = false
   where task_id in (select id from public.ws_tasks where order_id = o.id);
  delete from public.ws_orders where id = o.id;              -- its steps go with it; materials history stays
  -- a website order goes back to "waiting" so it can be sent again
  if o.source_order_id is not null and not exists (select 1 from public.ws_orders where source_order_id = o.source_order_id) then
    update public.orders set status = 'confirmed', status_note = null where id = o.source_order_id;
  end if;
  perform public.ws_note('warn', o.ref || ' deleted (' || o.qty || ' × ' || o.item || ' for ' || o.customer || ')');
  perform public.ws_release_all();
end $$;

revoke all on function public.ws_edit_order(jsonb)  from public, anon;
revoke all on function public.ws_delete_order(uuid) from public, anon;
grant execute on function public.ws_edit_order(jsonb)  to authenticated;
grant execute on function public.ws_delete_order(uuid) to authenticated;
revoke all on function public.ws_set_planned(uuid, jsonb) from public, anon, authenticated;
revoke all on function public.ws_leave_task(uuid) from public, anon, authenticated;
grant execute on function public.ws_create_order(jsonb)               to authenticated;
grant execute on function public.ws_finish(uuid)                      to authenticated;
grant execute on function public.ws_my_job(uuid)                      to authenticated;
grant execute on function public.ws_set_away(uuid, boolean)           to authenticated;
grant execute on function public.ws_foreman_arrive(text, uuid, boolean) to authenticated;


-- #####################################################################
-- ##  FILE: update-10-kartech-items.sql
-- #####################################################################

-- =====================================================================
--  KARTECH UPDATE 10: Kartech's real tools and materials
--  Paste ALL of this into Supabase → SQL Editor → New query → Run.
--  Safe to run again (it never adds the same thing twice).
--
--  TOOLS (go out in the morning, come back in the evening):
--    Grinder 1–4 · Welding machine 1–4 · Electric drill 1–2 · Battery drill 1–2
--    Screwdriver 1–2
--  MATERIALS (used up, the app counts how much each day):
--    Welding rods · Cutting disks · Grinding disks · Drill bits (pieces)
--    Screws (boxes) · Paint · Thinner (litres)
--
--  Nobody knows how much is in the store yet, so materials start as
--  "not counted": the foreman can give them out and the app adds up what
--  is used. When the owner does a first count (Stock → Count), the app
--  starts keeping the store amount and low-stock warnings too.
-- =====================================================================

alter table public.ws_materials add column if not exists counted boolean not null default true;

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
  if k = 'out' and m.counted and q > m.in_store then raise exception 'Only % % in the store', public.ws_fmt(m.in_store), m.unit; end if;
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

create or replace function public.ws_stock_count(p_material uuid, p_counted numeric) returns numeric
language plpgsql security definer set search_path = public as $$
declare m public.ws_materials; diff numeric;
begin
  perform public.ws_need_owner();
  if p_counted is null or p_counted < 0 then raise exception 'Enter what you counted'; end if;
  select * into m from public.ws_materials where id = p_material for update;
  if m.id is null then raise exception 'Material not found'; end if;
  if not m.counted then
    -- first count ever: this is the starting amount
    insert into public.ws_moves (material_id, kind, qty, note) values (m.id, 'count', 0, 'First count: ' || public.ws_fmt(p_counted));
    update public.ws_materials set in_store = p_counted, counted = true where id = m.id;
    perform public.ws_note('good', 'First stock count: ' || public.ws_fmt(p_counted) || ' ' || m.unit || ' of ' || m.name || ' in the store');
    perform public.ws_check_low(m.id);
    return 0;
  end if;
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

create or replace function public.ws_check_low(p_mat uuid) returns void
language plpgsql security definer set search_path = public as $$
declare m public.ws_materials;
begin
  select * into m from public.ws_materials where id = p_mat;
  if m.counted and m.low_at > 0 and m.in_store <= m.low_at then
    perform public.ws_note('alert', 'Low stock: only ' || public.ws_fmt(m.in_store) || ' ' || m.unit || ' of ' || m.name || ' left in the store');
  end if;
end $$;

create or replace function public.ws_foreman_open(p_pin text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare today timestamptz := (public.ws_today()::timestamp at time zone 'Africa/Nairobi'); st text;
begin
  st := public.ws_foreman_check(p_pin);
  if st <> 'ok' then return jsonb_build_object('error', st); end if;
  return jsonb_build_object(
    'workers', coalesce((select jsonb_agg(jsonb_build_object('id', w.id, 'name', w.name, 'stage', w.stage,
        'in', coalesce(w.arrived_on = public.ws_today() and (w.away_on is null or w.away_on <> public.ws_today()), false),
        'away', coalesce(w.away_on = public.ws_today(), false),
        'arrived_at', case when w.arrived_on = public.ws_today() then w.arrived_at end,
        'job', (select jsonb_build_object('order_id', o.id, 'ref', o.ref, 'item', o.item, 'qty', o.qty, 'status', t.status)
                  from public.ws_tasks t join public.ws_orders o on o.id = t.order_id where t.id = w.task_id),
        'today', coalesce((select jsonb_agg(jsonb_build_object('material_id', m.id, 'material', m.name, 'unit', m.unit, 'qty', x.q,
                    'last', (select -qty from public.ws_moves z where z.worker_id = w.id and z.material_id = m.id and z.kind = 'out' and z.at >= today order by z.id desc limit 1),
                    'times', x.n) order by m.name)
                  from (select material_id, -sum(qty) q, count(*) filter (where kind = 'out') n from public.ws_moves where worker_id = w.id and kind in ('out','back') and at >= today group by material_id) x
                  join public.ws_materials m on m.id = x.material_id where x.q > 0), '[]'::jsonb))
        order by w.name) from public.ws_workers w where w.active), '[]'::jsonb),
    'tools', coalesce((select jsonb_agg(jsonb_build_object('id', t.id, 'name', t.name, 'usual', t.usual_worker, 'stages', t.stages,
        'with', l.worker_id, 'with_name', lw.name, 'since', l.out_at,
        'missing', exists (select 1 from public.ws_tool_missing mm where mm.tool_id = t.id and mm.found_at is null)) order by t.name)
        from public.ws_tools t
        left join lateral (select * from public.ws_tool_loans x where x.tool_id = t.id and x.back_at is null order by x.id desc limit 1) l on true
        left join public.ws_workers lw on lw.id = l.worker_id
       where t.active), '[]'::jsonb),
    'materials', coalesce((select jsonb_agg(jsonb_build_object('id', m.id, 'name', m.name, 'unit', m.unit, 'in_store', m.in_store, 'stages', m.stages,
        'counted', m.counted,
        'used_today', (select coalesce(-sum(z.qty), 0) from public.ws_moves z where z.material_id = m.id and z.kind in ('out','back') and z.at >= today)) order by m.name)
        from public.ws_materials m where m.active), '[]'::jsonb),
    'done_today', (select done_at from public.ws_tool_checks where day = public.ws_today()));
end $$;

-- ---------- the tools ----------
insert into public.ws_tools (name, stages)
select t.name, array(select x from unnest(t.stages) x where exists (select 1 from public.ws_steps s where s.id = x))
  from (values
    ('Grinder 1', '{cut,grind}'::text[]), ('Grinder 2', '{cut,grind}'), ('Grinder 3', '{cut,grind}'), ('Grinder 4', '{cut,grind}'),
    ('Welding machine 1', '{weld}'), ('Welding machine 2', '{weld}'), ('Welding machine 3', '{weld}'), ('Welding machine 4', '{weld}'),
    ('Electric drill 1', '{fold,weld,foam}'), ('Electric drill 2', '{fold,weld,foam}'),
    ('Battery drill 1', '{fold,weld,foam}'),  ('Battery drill 2', '{fold,weld,foam}'),
    ('Screwdriver 1', '{foam,finish}'), ('Screwdriver 2', '{foam,finish}')
  ) t(name, stages)
 where not exists (select 1 from public.ws_tools x where lower(x.name) = lower(t.name));

-- ---------- the materials (not counted yet) ----------
insert into public.ws_materials (name, unit, stages, counted)
select m.name, m.unit, array(select x from unnest(m.stages) x where exists (select 1 from public.ws_steps s where s.id = x)), false
  from (values
    ('Welding rods',   'pcs',    '{weld}'::text[]),
    ('Cutting disks',  'pcs',    '{cut}'),
    ('Grinding disks', 'pcs',    '{grind}'),
    ('Drill bits',     'pcs',    '{fold,weld,foam}'),
    ('Screws',         'boxes',  '{foam,finish}'),
    ('Paint',          'litres', '{paint}'),
    ('Thinner',        'litres', '{paint}')
  ) m(name, unit, stages)
 where not exists (select 1 from public.ws_materials x where lower(x.name) = lower(m.name));

grant select (counted) on public.ws_materials to authenticated;
grant execute on function public.ws_stock_count(uuid, numeric) to authenticated;
grant execute on function public.ws_foreman_open(text)         to authenticated;


-- #####################################################################
-- ##  FILE: update-11-together.sql
-- #####################################################################

-- =====================================================================
--  KARTECH UPDATE 11: steps at the same time + pick people for later steps
--  Paste ALL of this into Supabase → SQL Editor → New query → Run.
--  Safe to run again. Run update-10-kartech-items.sql first.
--
--  • A step can be marked "at the same time as the step above", e.g.
--    Foaming starts while Welding is still going. The next normal step
--    waits until both are finished.
--  • The owner can pick who does a later step straight from the order,
--    even when the first step isn't done yet.
-- =====================================================================

alter table public.ws_tasks add column if not exists with_prev boolean not null default false;

-- which steps start together with the step above: ["foam", ...]
create or replace function public.ws_set_together(p_order uuid, p_list jsonb) returns void
language plpgsql security definer set search_path = public as $$
begin
  if p_list is null or jsonb_typeof(p_list) <> 'array' then return; end if;
  update public.ws_tasks t set with_prev = (t.stage in (select jsonb_array_elements_text(p_list)) and t.step > 1)
   where t.order_id = p_order and t.status in ('waiting','queued');
  update public.ws_tasks set with_prev = false where order_id = p_order and step = 1;
end $$;

-- start every step that is ready: the first group of unfinished steps
create or replace function public.ws_advance(p_order uuid) returns void
language plpgsql security definer set search_path = public as $$
declare t record; blk int := 0; cur int := null;
begin
  for t in select * from public.ws_tasks where order_id = p_order order by step loop
    if blk = 0 or not t.with_prev then blk := blk + 1; end if;
    if cur is null and t.status <> 'done' then cur := blk; end if;
    if cur is not null and blk = cur and t.status = 'waiting' then
      perform public.ws_enqueue(t.id);
    elsif cur is not null and blk > cur and t.status = 'queued' then
      update public.ws_tasks set status = 'waiting' where id = t.id;   -- not its turn yet (after an edit)
    end if;
  end loop;
end $$;

-- owner picks 1 or 2 people for one step (any time, even before it is ready)
create or replace function public.ws_plan_step(p_task uuid, p_people jsonb) returns void
language plpgsql security definer set search_path = public as $$
declare t public.ws_tasks; o public.ws_orders; ids uuid[]; names text;
begin
  perform public.ws_need_owner();
  select * into t from public.ws_tasks where id = p_task for update;
  if t.id is null then raise exception 'Step not found'; end if;
  if t.status = 'done' then raise exception 'This step is already finished'; end if;
  select coalesce(array_agg(w.id), '{}'), string_agg(w.name, ' & ' order by w.name) into ids, names from (
    select x::uuid id, min(n) n from jsonb_array_elements_text(coalesce(p_people, '[]'::jsonb)) with ordinality e(x, n) group by x) z
    join public.ws_workers w on w.id = z.id and w.active
   where z.n <= 2;
  update public.ws_tasks set planned = ids where id = t.id;
  select * into o from public.ws_orders where id = t.order_id;
  perform public.ws_note('info', o.ref || ' · ' || public.ws_stage_name(t.stage) || ': ' || coalesce('picked ' || names, 'anyone free can do it'), o.id);
  perform public.ws_release_all();
end $$;

create or replace function public.ws_finish(p_token uuid) returns void
language plpgsql security definer set search_path = public as $$
declare w public.ws_workers; t public.ws_tasks; o public.ws_orders; nt uuid; who text;
begin
  w := public.ws_me(p_token);
  select * into t from public.ws_tasks where id = w.task_id;
  if t.id is null then return; end if;
  select * into o from public.ws_orders where id = t.order_id;
  who := public.ws_task_names(t.id);
  update public.ws_tasks set status = 'done', done_at = now(),
    problem_reason = null, problem_stopped = null, problem_at = null, problem_ack_at = null where id = t.id;
  update public.ws_workers set task_id = null, waiting_logged = false where task_id = t.id;
  perform public.ws_note('good', coalesce(who, w.name) || ' finished ' || o.ref || ' · ' || public.ws_stage_name(t.stage), o.id);
  perform public.ws_advance(o.id);
  if not exists (select 1 from public.ws_tasks where order_id = o.id and status <> 'done') then
    perform public.ws_note('good', o.ref || ' is finished and loaded. Ready for delivery.', o.id);
  end if;
  perform public.ws_release_all();
  perform public.ws_sync_source(o.source_order_id);
end $$;

create or replace function public.ws_create_order(p jsonb) returns text
language plpgsql security definer set search_path = public as $$
declare o_id uuid; v_ref text; st text[]; i int; first_task uuid; t_id uuid;
begin
  perform public.ws_need_owner();
  select array_agg(s.id order by s.sort) into st
    from public.ws_steps s where s.active and s.id in (select jsonb_array_elements_text(p->'stages'));
  if st is null or array_length(st, 1) is null then raise exception 'Pick at least one step'; end if;
  if length(trim(coalesce(p->>'customer',''))) = 0 or length(trim(coalesce(p->>'item',''))) = 0 then raise exception 'Customer and item are required'; end if;
  v_ref := 'KT-' || nextval('public.ws_ref_seq');
  insert into public.ws_orders (ref, customer, item, qty, deadline, urgency, notes, stages)
  values (v_ref, left(trim(p->>'customer'), 120), left(trim(p->>'item'), 120), greatest(1, (p->>'qty')::int),
          coalesce((p->>'deadline')::date, current_date + 7),
          case when p->>'urgency' in ('urgent','high','normal') then p->>'urgency' else 'normal' end,
          nullif(left(trim(coalesce(p->>'notes','')), 500), ''), st)
  returning id into o_id;
  for i in 1 .. array_length(st, 1) loop
    insert into public.ws_tasks (order_id, step, stage) values (o_id, i, st[i]) returning id into t_id;
    if i = 1 then first_task := t_id; end if;
  end loop;
  perform public.ws_set_planned(o_id, p->'people');
  perform public.ws_set_together(o_id, p->'together');
  perform public.ws_note(case when p->>'urgency' = 'urgent' then 'alert' else 'info' end,
    'New order ' || v_ref || ': ' || (p->>'qty') || ' × ' || trim(p->>'item') || ' for ' || trim(p->>'customer'), o_id);
  perform public.ws_advance(o_id);
  perform public.ws_release_all();
  return v_ref;
end $$;

create or replace function public.ws_edit_order(p jsonb) returns void
language plpgsql security definer set search_path = public as $$
declare o public.ws_orders; v_id uuid := (p->>'id')::uuid;
        new_st text[]; t record; started_sort int; i int := 0; cur public.ws_tasks;
        v_cust text := left(trim(coalesce(p->>'customer','')), 120);
        v_item text := left(trim(coalesce(p->>'item','')), 120);
        v_qty int := greatest(1, coalesce((p->>'qty')::int, 1));
        v_urg text := case when p->>'urgency' in ('urgent','high','normal') then p->>'urgency' else 'normal' end;
        changes text[] := '{}';
begin
  perform public.ws_need_owner();
  select * into o from public.ws_orders where id = v_id for update;
  if o.id is null then raise exception 'Order not found'; end if;
  if o.delivered_at is not null then raise exception 'This order is already delivered'; end if;
  if length(v_cust) = 0 or length(v_item) = 0 then raise exception 'Customer and item are required'; end if;

  -- steps: keep the order of the workshop steps
  select array_agg(s.id order by s.sort) into new_st
    from public.ws_steps s where s.id in (select jsonb_array_elements_text(coalesce(p->'stages', to_jsonb(o.stages))));
  -- steps already done or being worked on can't be removed
  select coalesce(array_agg(x order by s.sort), new_st) into new_st from (
     select unnest(coalesce(new_st, '{}')) x
     union select stage from public.ws_tasks where order_id = o.id and status in ('done','assigned','working')) u
     join public.ws_steps s on s.id = u.x;
  if new_st is null or array_length(new_st, 1) is null then raise exception 'Pick at least one step'; end if;

  -- a new step can't go before a step someone has already started
  select max(s.sort) into started_sort from public.ws_tasks tk join public.ws_steps s on s.id = tk.stage
   where tk.order_id = o.id and tk.status in ('done','assigned','working');
  if exists (select 1 from unnest(new_st) x join public.ws_steps s on s.id = x
              where s.sort < coalesce(started_sort, -1e9)
                and not exists (select 1 from public.ws_tasks tk where tk.order_id = o.id and tk.stage = x)) then
    raise exception 'You can only add steps that come after the work already done';
  end if;

  if o.customer <> v_cust then changes := changes || ('customer → ' || v_cust); end if;
  if o.item <> v_item then changes := changes || ('item → ' || v_item); end if;
  if o.qty <> v_qty then changes := changes || ('how many ' || o.qty || ' → ' || v_qty); end if;
  if p->>'deadline' is not null and o.deadline <> (p->>'deadline')::date then changes := changes || ('deadline → ' || to_char((p->>'deadline')::date, 'DD Mon YYYY')); end if;
  if o.urgency <> v_urg then changes := changes || ('urgency → ' || v_urg); end if;
  if coalesce(o.notes,'') <> coalesce(nullif(left(trim(coalesce(p->>'notes','')), 500), ''), '') then changes := changes || 'note'::text; end if;
  if o.stages <> new_st then changes := changes || 'steps'::text; end if;

  update public.ws_orders set customer = v_cust, item = v_item, qty = v_qty,
    deadline = coalesce((p->>'deadline')::date, deadline), urgency = v_urg,
    notes = nullif(left(trim(coalesce(p->>'notes','')), 500), ''), stages = new_st
   where id = o.id;

  -- remove steps that were unticked (only ones nobody started)
  delete from public.ws_tasks where order_id = o.id and status in ('waiting','queued') and not (stage = any(new_st));
  -- add new steps
  insert into public.ws_tasks (order_id, step, stage)
  select o.id, 0, x from unnest(new_st) x where not exists (select 1 from public.ws_tasks tk where tk.order_id = o.id and tk.stage = x);
  -- number them again in workshop order
  for t in select tk.id from public.ws_tasks tk join public.ws_steps s on s.id = tk.stage where tk.order_id = o.id order by s.sort loop
    i := i + 1; update public.ws_tasks set step = i where id = t.id;
  end loop;

  perform public.ws_set_planned(o.id, p->'people');

  -- start every step that is ready now (steps marked "same time" start together)
  perform public.ws_set_together(o.id, p->'together');
  perform public.ws_advance(o.id);
  -- new deadline/urgency: put its place in line right again
  if v_urg = 'urgent' and o.urgency <> 'urgent' then
    for t in select * from public.ws_tasks where order_id = o.id and status = 'queued' loop
      update public.ws_tasks set rank = (select coalesce(min(rank), 1) - 1 from public.ws_tasks where stage = t.stage and status = 'queued') where id = t.id;
    end loop;
  elsif o.urgency <> v_urg or o.deadline <> coalesce((p->>'deadline')::date, o.deadline) then
    for t in select id from public.ws_tasks where order_id = o.id and status = 'queued' loop perform public.ws_enqueue(t.id); end loop;
  end if;

  if array_length(changes, 1) > 0 then
    perform public.ws_note('info', o.ref || ' edited: ' || array_to_string(changes, ', '), o.id);
  end if;
  if not exists (select 1 from public.ws_tasks where order_id = o.id and status <> 'done') then
    perform public.ws_note('good', o.ref || ' is finished. Ready for delivery.', o.id);
  end if;
  perform public.ws_sync_source(o.source_order_id);
  perform public.ws_release_all();
end $$;

revoke all on function public.ws_set_together(uuid, jsonb), public.ws_advance(uuid) from public, anon, authenticated;
revoke all on function public.ws_plan_step(uuid, jsonb) from public, anon;
grant execute on function public.ws_plan_step(uuid, jsonb)  to authenticated;
grant execute on function public.ws_finish(uuid)            to authenticated;
grant execute on function public.ws_create_order(jsonb)     to authenticated;
grant execute on function public.ws_edit_order(jsonb)       to authenticated;


-- #####################################################################
-- ##  FILE: update-12-all.sql
-- #####################################################################

-- =====================================================================
--  KARTECH UPDATE 12: job alerts, deliveries, photos
--  Paste ALL of this into Supabase → SQL Editor → New query → Run.
--  Safe to run again. Run update-11-together.sql first.
--
--  • Workshop screen: each worker's job shows under their name and the
--    screen says it out loud: "Eric, new job: KT-1012, cutting."
--  • Deliveries: plan the day and place; move it (e.g. rains) and the
--    customer sees the new date on their tracking page.
--  • Photos of finished work, private to the owner.
--  • The foreman can add workers and set their trade.
-- =====================================================================

create or replace function public.ws_station_board() returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  if not (public.ws_is_station() or public.is_admin()) then raise exception 'This computer is not set up as the workshop PC'; end if;
  return coalesce((select jsonb_agg(jsonb_build_object(
      'id', w.id, 'name', w.name, 'stage', w.stage,
      'job', (select jsonb_build_object('task', t.id, 'ref', o.ref, 'stage', t.stage, 'status', t.status, 'item', o.item, 'qty', o.qty,
                       'urgency', o.urgency, 'since', coalesce(t.assigned_at, now()),
                       'with', (select string_agg(x.name, ' & ' order by x.name) from public.ws_workers x where x.task_id = t.id and x.id <> w.id))
                from public.ws_tasks t join public.ws_orders o on o.id = t.order_id where t.id = w.task_id),
      'next', (select count(*) from public.ws_tasks q where q.status in ('queued','waiting') and w.id = any(q.planned) and q.id is distinct from w.task_id))
    order by w.name)
    from public.ws_workers w where public.ws_is_here(w)), '[]'::jsonb);
end $$;

revoke all on function public.ws_station_board() from public, anon;
grant execute on function public.ws_station_board() to authenticated;


-- =====================================================================
--  DELIVERIES: plan the day, move it (e.g. rains), customer sees it
-- =====================================================================
alter table public.ws_orders add column if not exists delivery_on    date;
alter table public.ws_orders add column if not exists delivery_place text;
alter table public.ws_orders add column if not exists delivery_note  text;

create or replace function public.ws_set_delivery(p_order uuid, p_day date, p_place text, p_note text) returns void
language plpgsql security definer set search_path = public as $$
declare o public.ws_orders; moved boolean;
begin
  perform public.ws_need_owner();
  select * into o from public.ws_orders where id = p_order for update;
  if o.id is null then raise exception 'Order not found'; end if;
  if o.delivered_at is not null then raise exception 'Already delivered'; end if;
  moved := o.delivery_on is not null and p_day is distinct from o.delivery_on;
  update public.ws_orders set delivery_on = p_day, delivery_place = nullif(left(trim(coalesce(p_place, '')), 120), ''),
         delivery_note = nullif(left(trim(coalesce(p_note, '')), 120), '') where id = o.id;
  perform public.ws_note(case when moved then 'warn' else 'info' end,
    o.ref || case when p_day is null then ' delivery date cleared'
                  else case when moved then ' delivery moved to ' else ' delivery planned for ' end || trim(to_char(p_day, 'Dy')) || ' ' || to_char(p_day, 'FMDD Mon') end
    || coalesce(' · ' || nullif(trim(p_place), ''), '') || coalesce(' (' || nullif(trim(p_note), '') || ')', ''), o.id);
  perform public.ws_sync_source(o.source_order_id);
end $$;

create or replace function public.ws_sync_source(p_src uuid) returns void
language plpgsql security definer set search_path = public as $$
declare total int; open_jobs int; undelivered int; note text; dd date; dwhy text; dtxt text := '';
begin
  if p_src is null then return; end if;
  select count(*), count(*) filter (where delivered_at is null) into total, undelivered from public.ws_orders where source_order_id = p_src;
  if total = 0 then return; end if;
  select delivery_on, delivery_note into dd, dwhy from public.ws_orders
   where source_order_id = p_src and delivered_at is null and delivery_on is not null order by delivery_on limit 1;
  if dd is not null then
    dtxt := ' Delivery planned for ' || trim(to_char(dd, 'Day')) || ' ' || to_char(dd, 'FMDD Mon') || coalesce(' (' || nullif(dwhy, '') || ')', '') || '.';
  end if;
  select count(*) into open_jobs from public.ws_tasks t join public.ws_orders o on o.id = t.order_id
   where o.source_order_id = p_src and t.status <> 'done';
  if undelivered = 0 then
    update public.orders set status = 'delivered', status_note = 'Delivered. Thank you for choosing Kartech!' where id = p_src;
  elsif open_jobs = 0 then
    update public.orders set status = 'ready', status_note = 'Everything is finished and checked. Ready for delivery or collection.' || case when dtxt = '' then ' We will call you to arrange it.' else dtxt end where id = p_src;
  else
    select string_agg(
             case when total > 1 then o.item || ': ' else '' end ||
             coalesce(public.ws_step_group(cur.stage) ||
                      case when public.ws_step_group(cur.stage) <> public.ws_stage_name(cur.stage) then ' (' || lower(public.ws_stage_name(cur.stage)) || ')' else '' end,
                      'finished'),
             ' · ' order by o.created_at)
      into note
      from public.ws_orders o
      left join lateral (select t.stage from public.ws_tasks t where t.order_id = o.id and t.status <> 'done' order by t.step limit 1) cur on true
     where o.source_order_id = p_src;
    update public.orders set status = 'workshop', status_note = 'Now in the workshop: ' || note || '. This updates by itself as we work.' || dtxt where id = p_src;
  end if;
end $$;

revoke all on function public.ws_set_delivery(uuid, date, text, text) from public, anon;
grant execute on function public.ws_set_delivery(uuid, date, text, text) to authenticated;


-- =====================================================================
--  PHOTOS of finished work (private: only the owner can see them)
-- =====================================================================
create table if not exists public.ws_photos (
  id       bigserial primary key,
  order_id uuid not null references public.ws_orders(id) on delete cascade,
  path     text not null,
  at       timestamptz not null default now()
);
alter table public.ws_photos enable row level security;
drop policy if exists "owner reads photos" on public.ws_photos;
create policy "owner reads photos" on public.ws_photos for select to authenticated using (public.is_admin());
grant select on public.ws_photos to authenticated;

create or replace function public.ws_add_photo(p_order uuid, p_path text) returns void
language plpgsql security definer set search_path = public as $$
declare o public.ws_orders;
begin
  perform public.ws_need_owner();
  select * into o from public.ws_orders where id = p_order;
  if o.id is null then raise exception 'Order not found'; end if;
  if p_path is null or p_path not like o.id::text || '/%' then raise exception 'Bad photo'; end if;
  insert into public.ws_photos (order_id, path) values (o.id, p_path);
  perform public.ws_note('good', 'Photo added to ' || o.ref, o.id);
end $$;

create or replace function public.ws_remove_photo(p_id bigint) returns text
language plpgsql security definer set search_path = public as $$
declare v text;
begin
  perform public.ws_need_owner();
  delete from public.ws_photos where id = p_id returning path into v;
  return v;
end $$;

revoke all on function public.ws_add_photo(uuid, text), public.ws_remove_photo(bigint) from public, anon;
grant execute on function public.ws_add_photo(uuid, text)  to authenticated;
grant execute on function public.ws_remove_photo(bigint)  to authenticated;

-- the photo store (Supabase Storage). Private: only the owner can add, see or remove photos.
do $do$
begin
  if exists (select 1 from information_schema.schemata where schema_name = 'storage') then
    insert into storage.buckets (id, name, public) values ('kartech-photos', 'kartech-photos', false) on conflict (id) do nothing;
    drop policy if exists "kartech photos owner read"   on storage.objects;
    drop policy if exists "kartech photos owner add"    on storage.objects;
    drop policy if exists "kartech photos owner remove" on storage.objects;
    create policy "kartech photos owner read"   on storage.objects for select to authenticated using (bucket_id = 'kartech-photos' and public.is_admin());
    create policy "kartech photos owner add"    on storage.objects for insert to authenticated with check (bucket_id = 'kartech-photos' and public.is_admin());
    create policy "kartech photos owner remove" on storage.objects for delete to authenticated using (bucket_id = 'kartech-photos' and public.is_admin());
  end if;
end $do$;


-- =====================================================================
--  FOREMAN can add workers and set their trade (owner still switches off)
-- =====================================================================
create or replace function public.ws_foreman_save_worker(p_pin text, p jsonb) returns void
language plpgsql security definer set search_path = public as $$
declare w public.ws_workers; v_name text := left(trim(coalesce(p->>'name','')), 60); v_stage text := p->>'stage';
        v_covers text[] := coalesce(array(select x from jsonb_array_elements_text(coalesce(p->'covers','[]'::jsonb)) x
                                          where x <> coalesce(p->>'stage','') and exists (select 1 from public.ws_steps s where s.id = x)), '{}');
begin
  perform public.ws_foreman_ok(p_pin);
  if length(v_name) = 0 then raise exception 'Type the worker''s name'; end if;
  if not exists (select 1 from public.ws_steps where id = v_stage and active) then raise exception 'Pick their main job'; end if;
  if p->>'id' is null then
    if exists (select 1 from public.ws_workers where active and lower(name) = lower(v_name)) then raise exception '% is already on the list', v_name; end if;
    insert into public.ws_workers (name, stage, covers, pin_hash) values (v_name, v_stage, v_covers, extensions.crypt(gen_random_uuid()::text, extensions.gen_salt('bf')));
    perform public.ws_note('good', 'Manager added a new worker: ' || v_name || ', ' || public.ws_stage_name(v_stage));
  else
    select * into w from public.ws_workers where id = (p->>'id')::uuid and active;
    if w.id is null then raise exception 'Worker not found'; end if;
    update public.ws_workers set name = v_name, covers = v_covers,
      stage = case when w.task_id is null then v_stage else w.stage end where id = w.id;
    perform public.ws_note('info', 'Manager updated ' || v_name || ': ' || public.ws_stage_name(case when w.task_id is null then v_stage else w.stage end)
      || case when array_length(v_covers, 1) > 0 then ', can also do ' || (select string_agg(lower(public.ws_stage_name(x)), ', ') from unnest(v_covers) x) else '' end
      || case when w.task_id is not null and v_stage <> w.stage then ' (main job changes after the current job)' else '' end);
  end if;
  perform public.ws_release_all();
end $$;

create or replace function public.ws_foreman_open(p_pin text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare today timestamptz := (public.ws_today()::timestamp at time zone 'Africa/Nairobi'); st text;
begin
  st := public.ws_foreman_check(p_pin);
  if st <> 'ok' then return jsonb_build_object('error', st); end if;
  return jsonb_build_object(
    'workers', coalesce((select jsonb_agg(jsonb_build_object('id', w.id, 'name', w.name, 'stage', w.stage, 'covers', w.covers,
        'in', coalesce(w.arrived_on = public.ws_today() and (w.away_on is null or w.away_on <> public.ws_today()), false),
        'away', coalesce(w.away_on = public.ws_today(), false),
        'arrived_at', case when w.arrived_on = public.ws_today() then w.arrived_at end,
        'job', (select jsonb_build_object('order_id', o.id, 'ref', o.ref, 'item', o.item, 'qty', o.qty, 'status', t.status)
                  from public.ws_tasks t join public.ws_orders o on o.id = t.order_id where t.id = w.task_id),
        'today', coalesce((select jsonb_agg(jsonb_build_object('material_id', m.id, 'material', m.name, 'unit', m.unit, 'qty', x.q,
                    'last', (select -qty from public.ws_moves z where z.worker_id = w.id and z.material_id = m.id and z.kind = 'out' and z.at >= today order by z.id desc limit 1),
                    'times', x.n) order by m.name)
                  from (select material_id, -sum(qty) q, count(*) filter (where kind = 'out') n from public.ws_moves where worker_id = w.id and kind in ('out','back') and at >= today group by material_id) x
                  join public.ws_materials m on m.id = x.material_id where x.q > 0), '[]'::jsonb))
        order by w.name) from public.ws_workers w where w.active), '[]'::jsonb),
    'tools', coalesce((select jsonb_agg(jsonb_build_object('id', t.id, 'name', t.name, 'usual', t.usual_worker, 'stages', t.stages,
        'with', l.worker_id, 'with_name', lw.name, 'since', l.out_at,
        'missing', exists (select 1 from public.ws_tool_missing mm where mm.tool_id = t.id and mm.found_at is null)) order by t.name)
        from public.ws_tools t
        left join lateral (select * from public.ws_tool_loans x where x.tool_id = t.id and x.back_at is null order by x.id desc limit 1) l on true
        left join public.ws_workers lw on lw.id = l.worker_id
       where t.active), '[]'::jsonb),
    'materials', coalesce((select jsonb_agg(jsonb_build_object('id', m.id, 'name', m.name, 'unit', m.unit, 'in_store', m.in_store, 'stages', m.stages,
        'counted', m.counted,
        'used_today', (select coalesce(-sum(z.qty), 0) from public.ws_moves z where z.material_id = m.id and z.kind in ('out','back') and z.at >= today)) order by m.name)
        from public.ws_materials m where m.active), '[]'::jsonb),
    'done_today', (select done_at from public.ws_tool_checks where day = public.ws_today()));
end $$;

revoke all on function public.ws_foreman_save_worker(text, jsonb) from public, anon;
grant execute on function public.ws_foreman_save_worker(text, jsonb) to authenticated;
grant execute on function public.ws_foreman_open(text)               to authenticated;


-- #####################################################################
-- ##  FILE: update-13-manager.sql
-- #####################################################################

-- =====================================================================
--  KARTECH UPDATE 13: "Foreman" is now called "Manager"
--  Paste ALL of this into Supabase → SQL Editor → New query → Run.
--  Safe to run again. Only words change, nothing else.
-- =====================================================================

-- the messages the system writes (History, workshop news, errors)
do $$
declare f record; src text; fixed text;
begin
  for f in select p.oid from pg_proc p join pg_namespace n on n.oid = p.pronamespace
            where n.nspname = 'public' and p.prokind = 'f' loop
    src := pg_get_functiondef(f.oid);
    fixed := replace(replace(replace(replace(replace(replace(replace(src,
      'Foreman gave ', 'Manager gave '),
      'Foreman added a new worker', 'Manager added a new worker'),
      'Foreman updated ', 'Manager updated '),
      'Foreman code changed', 'Manager code changed'),
      'by foreman', 'by manager'),
      'wrong foreman code', 'wrong manager code'),
      'set a foreman code', 'set a manager code');
    if fixed <> src then execute fixed; end if;
  end loop;
end $$;

-- old entries in History read the new way too
update public.ws_log set text = replace(replace(replace(replace(replace(text,
  'Foreman gave ', 'Manager gave '), 'Foreman added a new worker', 'Manager added a new worker'),
  'Foreman updated ', 'Manager updated '), 'Foreman code changed', 'Manager code changed'),
  'wrong foreman code', 'wrong manager code')
 where text ~ '(Foreman (gave|added|updated|code changed)|wrong foreman code)';
update public.ws_moves set note = replace(note, 'by foreman', 'by manager') where note like '%by foreman%';


-- #####################################################################
-- ##  FILE: update-14-order-pictures.sql
-- #####################################################################

-- =====================================================================
--  KARTECH UPDATE 14: pictures of what to make (workers see them)
--  Paste ALL of this into Supabase → SQL Editor → New query → Run.
--  Safe to run again. Run update-12-all.sql first.
--
--  • Each order can have pictures of WHAT TO MAKE: the customer's sample,
--    a sketch, a fabric colour. Workers see them on their job card, so
--    nothing depends on word of mouth.
--  • "Finished work" photos stay private to the owner, like before.
-- =====================================================================

alter table public.ws_photos add column if not exists kind text not null default 'done';
do $$ begin
  if not exists (select 1 from pg_constraint where conname = 'ws_photos_kind_check') then
    alter table public.ws_photos add constraint ws_photos_kind_check check (kind in ('ref', 'done'));
  end if;
end $$;

-- the owner sees all photos; the workshop computer sees only "what to make" pictures
drop policy if exists "owner reads photos" on public.ws_photos;
create policy "owner reads photos" on public.ws_photos for select to authenticated
  using (public.is_admin() or (kind = 'ref' and public.ws_is_station()));

create or replace function public.ws_add_photo(p_order uuid, p_path text, p_kind text) returns void
language plpgsql security definer set search_path = public as $$
declare o public.ws_orders; k text := case when p_kind = 'ref' then 'ref' else 'done' end;
begin
  perform public.ws_need_owner();
  select * into o from public.ws_orders where id = p_order;
  if o.id is null then raise exception 'Order not found'; end if;
  if p_path is null or p_path not like o.id::text || '/%' then raise exception 'Bad photo'; end if;
  insert into public.ws_photos (order_id, path, kind) values (o.id, p_path, k);
  perform public.ws_note('good', case when k = 'ref' then 'Picture of what to make added to ' else 'Photo of finished work added to ' end || o.ref, o.id);
end $$;

-- the worker's job card: pictures for the order they are working on
create or replace function public.ws_job_pictures(p_token uuid) returns text[]
language plpgsql stable security definer set search_path = public as $$
declare w public.ws_workers;
begin
  w := public.ws_me(p_token);
  return coalesce((select array_agg(p.path order by p.id) from public.ws_photos p join public.ws_tasks t on t.order_id = p.order_id
                    where t.id = w.task_id and p.kind = 'ref'), '{}');
end $$;

revoke all on function public.ws_add_photo(uuid, text, text), public.ws_job_pictures(uuid) from public, anon;
grant execute on function public.ws_add_photo(uuid, text, text) to authenticated;
grant execute on function public.ws_job_pictures(uuid)          to authenticated;

-- the workshop computer may open "what to make" pictures (never finished-work photos)
do $do$
begin
  if exists (select 1 from information_schema.schemata where schema_name = 'storage') then
    drop policy if exists "kartech photos workshop read" on storage.objects;
    create policy "kartech photos workshop read" on storage.objects for select to authenticated
      using (bucket_id = 'kartech-photos' and public.ws_is_station()
             and exists (select 1 from public.ws_photos p where p.path = storage.objects.name and p.kind = 'ref'));
  end if;
end $do$;


-- #####################################################################
-- ##  FILE: update-15-sales.sql
-- #####################################################################

-- =====================================================================
--  KARTECH UPDATE 15: the manager takes sales + quote requests in the app
--  Paste ALL of this into Supabase → SQL Editor → New query → Run.
--  Safe to run again. Run update-14-order-pictures.sql first.
--
--  • When the owner is away, the manager adds orders on the workshop
--    screen (Manager → New order), with pictures. The owner is told.
--  • "Get a quote" requests from the website show in the owner app with
--    the customer's photos. One tap turns a request into an order and the
--    photos become "What to make" pictures for the workers.
-- =====================================================================

alter table public.ws_orders add column if not exists created_by text not null default 'owner';
alter table public.ws_orders add column if not exists request_id uuid;
alter table public.ws_photos add column if not exists bucket text not null default 'kartech-photos';

-- ---------- one place that creates orders (owner or manager) ----------
create or replace function public.ws_new_order(p jsonb, p_by text) returns text
language plpgsql security definer set search_path = public as $$
declare o_id uuid; v_ref text; st text[]; i int; t_id uuid; r public.custom_requests; f text;
begin
  select array_agg(s.id order by s.sort) into st
    from public.ws_steps s where s.active and s.id in (select jsonb_array_elements_text(p->'stages'));
  if st is null or array_length(st, 1) is null then raise exception 'Pick at least one step'; end if;
  if length(trim(coalesce(p->>'customer',''))) = 0 or length(trim(coalesce(p->>'item',''))) = 0 then raise exception 'Customer and item are required'; end if;
  v_ref := 'KT-' || nextval('public.ws_ref_seq');
  insert into public.ws_orders (ref, customer, item, qty, deadline, urgency, notes, stages, created_by, request_id)
  values (v_ref, left(trim(p->>'customer'), 120), left(trim(p->>'item'), 120), greatest(1, coalesce((p->>'qty')::int, 1)),
          coalesce((p->>'deadline')::date, current_date + 7),
          case when p->>'urgency' in ('urgent','high','normal') then p->>'urgency' else 'normal' end,
          nullif(left(trim(coalesce(p->>'notes','')), 500), ''), st, p_by, nullif(p->>'request_id', '')::uuid)
  returning id into o_id;
  for i in 1 .. array_length(st, 1) loop
    insert into public.ws_tasks (order_id, step, stage) values (o_id, i, st[i]) returning id into t_id;
  end loop;
  perform public.ws_set_planned(o_id, p->'people');
  perform public.ws_set_together(o_id, p->'together');

  -- from a website quote request: its photos become "what to make" pictures
  if nullif(p->>'request_id', '') is not null then
    select * into r from public.custom_requests where id = (p->>'request_id')::uuid;
    if r.id is not null then
      foreach f in array coalesce(r.files, '{}') loop
        if f ~* '\.(jpe?g|png|webp|gif|heic|heif)$' then
          insert into public.ws_photos (order_id, path, kind, bucket) values (o_id, f, 'ref', 'request-files');
        end if;
      end loop;
      update public.custom_requests set status = 'in_progress',
        admin_notes = concat_ws(E'\n', nullif(admin_notes, ''), 'Workshop order ' || v_ref) where id = r.id;
    end if;
  end if;

  if p_by = 'manager' then
    perform public.ws_note('alert', 'Manager took a new order ' || v_ref || ': ' || coalesce(p->>'qty', '1') || ' × ' || trim(p->>'item') || ' for ' || trim(p->>'customer'), o_id);
  else
    perform public.ws_note(case when p->>'urgency' = 'urgent' then 'alert' else 'info' end,
      'New order ' || v_ref || ': ' || coalesce(p->>'qty', '1') || ' × ' || trim(p->>'item') || ' for ' || trim(p->>'customer'), o_id);
  end if;
  perform public.ws_advance(o_id);
  perform public.ws_release_all();
  return v_ref;
end $$;

create or replace function public.ws_create_order(p jsonb) returns text
language plpgsql security definer set search_path = public as $$
begin
  perform public.ws_need_owner();
  return public.ws_new_order(p, 'owner');
end $$;

create or replace function public.ws_foreman_create_order(p_pin text, p jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_ref text;
begin
  perform public.ws_foreman_ok(p_pin);
  v_ref := public.ws_new_order(p - 'request_id', 'manager');
  return jsonb_build_object('ref', v_ref, 'id', (select id from public.ws_orders where ref = v_ref));
end $$;

-- the manager adds a picture to an order she just took
create or replace function public.ws_foreman_add_photo(p_pin text, p_order uuid, p_path text) returns void
language plpgsql security definer set search_path = public as $$
declare o public.ws_orders;
begin
  perform public.ws_foreman_ok(p_pin);
  select * into o from public.ws_orders where id = p_order;
  if o.id is null then raise exception 'Order not found'; end if;
  if p_path is null or p_path not like o.id::text || '/%' then raise exception 'Bad photo'; end if;
  insert into public.ws_photos (order_id, path, kind) values (o.id, p_path, 'ref');
  perform public.ws_note('good', 'Manager added a picture of what to make to ' || o.ref, o.id);
end $$;

-- the job card: pictures (and which store they are in)
create or replace function public.ws_job_pics(p_token uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare w public.ws_workers;
begin
  w := public.ws_me(p_token);
  return coalesce((select jsonb_agg(jsonb_build_object('b', p.bucket, 'p', p.path) order by p.id)
                     from public.ws_photos p join public.ws_tasks t on t.order_id = p.order_id
                    where t.id = w.task_id and p.kind = 'ref'), '[]'::jsonb);
end $$;

revoke all on function public.ws_new_order(jsonb, text) from public, anon, authenticated;
revoke all on function public.ws_foreman_create_order(text, jsonb), public.ws_foreman_add_photo(text, uuid, text), public.ws_job_pics(uuid) from public, anon;
grant execute on function public.ws_create_order(jsonb)                       to authenticated;
grant execute on function public.ws_foreman_create_order(text, jsonb)         to authenticated;
grant execute on function public.ws_foreman_add_photo(text, uuid, text)       to authenticated;
grant execute on function public.ws_job_pics(uuid)                            to authenticated;

-- ---------- picture store rules ----------
do $do$
begin
  if exists (select 1 from information_schema.schemata where schema_name = 'storage') then
    -- the workshop computer may upload pictures for orders (into the order's own folder)
    drop policy if exists "kartech photos workshop add" on storage.objects;
    create policy "kartech photos workshop add" on storage.objects for insert to authenticated
      with check (bucket_id = 'kartech-photos' and public.ws_is_station()
                  and exists (select 1 from public.ws_orders o where o.id::text = (storage.foldername(name))[1]));
    -- the workshop computer may open customer photos that became "what to make" pictures
    drop policy if exists "request files workshop read" on storage.objects;
    create policy "request files workshop read" on storage.objects for select to authenticated
      using (bucket_id = 'request-files' and public.ws_is_station()
             and exists (select 1 from public.ws_photos p where p.path = storage.objects.name and p.kind = 'ref' and p.bucket = 'request-files'));
  end if;
end $do$;


-- #####################################################################
-- ##  FILE: update-16-order-room.sql
-- #####################################################################

-- =====================================================================
--  KARTECH UPDATE 16: the Order Room (stage 1)
--  Paste ALL of this into Supabase → SQL Editor → New query → Run.
--  Safe to run again. Run update-15-sales.sql first.
--
--  • Every order gets a private link for its customer (and a QR code).
--  • In their Order Room the customer sees their order and its progress,
--    sends photos and messages, and taps "Yes, this is what I want".
--  • Their photos go straight onto the workers' job card; the workers see
--    "Customer approved this design". The owner gets an alert for each.
--  • No login for the customer: the link's random code is the key.
-- =====================================================================

-- a short random code nobody can guess (no 0/o/1/l, easy to read out)
create or replace function public.ws_new_code() returns text
language plpgsql volatile set search_path = public, extensions as $$
declare a text := 'abcdefghjkmnpqrstuvwxyz23456789'; b bytea := extensions.gen_random_bytes(10); r text := ''; i int;
begin
  for i in 0..9 loop r := r || substr(a, (get_byte(b, i) % length(a)) + 1, 1); end loop;
  return r;
end $$;

alter table public.ws_orders add column if not exists room_code text;
alter table public.ws_orders add column if not exists approved_at timestamptz;
update public.ws_orders set room_code = public.ws_new_code() where room_code is null;
alter table public.ws_orders alter column room_code set default public.ws_new_code();
create unique index if not exists ws_orders_room_code on public.ws_orders (room_code);

-- messages between the customer and Kartech, one thread per order
create table if not exists public.ws_room_msgs (
  id       bigserial primary key,
  order_id uuid not null references public.ws_orders(id) on delete cascade,
  at       timestamptz not null default now(),
  who      text not null check (who in ('customer', 'kartech')),
  text     text not null
);
alter table public.ws_room_msgs enable row level security;
drop policy if exists "owner reads room messages" on public.ws_room_msgs;
create policy "owner reads room messages" on public.ws_room_msgs for select to authenticated using (public.is_admin());
grant select on public.ws_room_msgs to authenticated;

-- ---------- what the customer sees ----------
create or replace function public.ws_room(p_code text) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare o public.ws_orders;
begin
  select * into o from public.ws_orders where room_code = lower(trim(p_code));
  if o.id is null then return null; end if;
  return jsonb_build_object(
    'ref', o.ref, 'item', o.item, 'qty', o.qty, 'name', split_part(trim(o.customer), ' ', 1),
    'deadline', o.deadline, 'delivered', o.delivered_at is not null, 'approved_at', o.approved_at,
    'notes', o.notes, 'delivery_on', o.delivery_on,
    'steps', (select coalesce(jsonb_agg(jsonb_build_object('name', g.grp, 'status', g.st) order by g.first_step), '[]'::jsonb)
                from (select public.ws_step_group(t.stage) grp, min(t.step) first_step,
                             case when bool_and(t.status = 'done') then 'done'
                                  when bool_or(t.status in ('working', 'assigned', 'done')) then 'working' else 'waiting' end st
                        from public.ws_tasks t where t.order_id = o.id group by 1) g),
    'photos', (select coalesce(jsonb_agg(jsonb_build_object('path', p.path, 'at', p.at) order by p.id), '[]'::jsonb)
                 from public.ws_photos p where p.order_id = o.id and p.bucket = 'room-files'),
    'msgs', (select coalesce(jsonb_agg(jsonb_build_object('who', m.who, 'text', m.text, 'at', m.at) order by m.id), '[]'::jsonb)
               from (select * from public.ws_room_msgs where order_id = o.id order by id desc limit 100) m));
end $$;

create or replace function public.ws_room_add_photo(p_code text, p_path text) returns void
language plpgsql security definer set search_path = public as $$
declare o public.ws_orders;
begin
  select * into o from public.ws_orders where room_code = lower(trim(p_code));
  if o.id is null then raise exception 'Order not found'; end if;
  if p_path is null or p_path not like 'room/' || o.room_code || '/%' then raise exception 'Bad photo'; end if;
  if (select count(*) from public.ws_photos where order_id = o.id and bucket = 'room-files') >= 40 then raise exception 'That is the most photos for one order. Send a message instead.'; end if;
  insert into public.ws_photos (order_id, path, kind, bucket) values (o.id, p_path, 'ref', 'room-files');
  perform public.ws_note('alert', split_part(trim(o.customer), ' ', 1) || ' sent a new picture for ' || o.ref, o.id);
end $$;

create or replace function public.ws_room_message(p_code text, p_text text) returns void
language plpgsql security definer set search_path = public as $$
declare o public.ws_orders; v text := left(trim(coalesce(p_text, '')), 500);
begin
  select * into o from public.ws_orders where room_code = lower(trim(p_code));
  if o.id is null then raise exception 'Order not found'; end if;
  if length(v) = 0 then raise exception 'Write a message first'; end if;
  if (select count(*) from public.ws_room_msgs where order_id = o.id and who = 'customer' and at > now() - interval '1 hour') >= 30 then raise exception 'Please wait a little before sending more.'; end if;
  insert into public.ws_room_msgs (order_id, who, text) values (o.id, 'customer', v);
  perform public.ws_note('alert', 'Message from ' || split_part(trim(o.customer), ' ', 1) || ' on ' || o.ref || ': ' || left(v, 120), o.id);
end $$;

create or replace function public.ws_room_approve(p_code text) returns void
language plpgsql security definer set search_path = public as $$
declare o public.ws_orders;
begin
  select * into o from public.ws_orders where room_code = lower(trim(p_code));
  if o.id is null then raise exception 'Order not found'; end if;
  if o.approved_at is not null then return; end if;
  update public.ws_orders set approved_at = now() where id = o.id;
  insert into public.ws_room_msgs (order_id, who, text) values (o.id, 'customer', '✓ Yes, this is what I want');
  perform public.ws_note('good', split_part(trim(o.customer), ' ', 1) || ' approved the design for ' || o.ref, o.id);
end $$;

-- the owner answers in the room
create or replace function public.ws_room_reply(p_order uuid, p_text text) returns void
language plpgsql security definer set search_path = public as $$
declare v text := left(trim(coalesce(p_text, '')), 500);
begin
  perform public.ws_need_owner();
  if length(v) = 0 then raise exception 'Write a message first'; end if;
  if not exists (select 1 from public.ws_orders where id = p_order) then raise exception 'Order not found'; end if;
  insert into public.ws_room_msgs (order_id, who, text) values (p_order, 'kartech', v);
end $$;

-- the owner can undo an approval (e.g. the design changed after talking)
create or replace function public.ws_room_unapprove(p_order uuid) returns void
language plpgsql security definer set search_path = public as $$
begin
  perform public.ws_need_owner();
  update public.ws_orders set approved_at = null where id = p_order;
end $$;

-- the manager sees the customer link of an order she just took
create or replace function public.ws_foreman_room_code(p_pin text, p_order uuid) returns text
language plpgsql security definer set search_path = public as $$
begin
  perform public.ws_foreman_ok(p_pin);
  return (select room_code from public.ws_orders where id = p_order);
end $$;

-- the worker's job card also says whether the customer approved
create or replace function public.ws_my_job(p_token uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare w public.ws_workers; t public.ws_tasks; o public.ws_orders; nxt record; after_stage text; mates text;
begin
  w := public.ws_me(p_token);
  if w.task_id is not null then
    select * into t from public.ws_tasks where id = w.task_id;
    select * into o from public.ws_orders where id = t.order_id;
    after_stage := o.stages[t.step + 1];
    select string_agg(name, ' & ' order by name) into mates from public.ws_workers where task_id = t.id and id <> w.id;
  end if;
  select o2.ref, o2.qty, o2.item into nxt from public.ws_tasks q join public.ws_orders o2 on o2.id = q.order_id
   where q.stage = w.stage and q.status = 'queued' order by q.rank limit 1;
  return jsonb_build_object(
    'worker', jsonb_build_object('name', w.name, 'stage', w.stage),
    'task', case when t.id is null then null else jsonb_build_object(
      'status', t.status, 'stage', t.stage, 'problem_reason', t.problem_reason, 'problem_stopped', t.problem_stopped,
      'problem_ack', t.problem_ack_at is not null, 'with', mates, 'approved', o.approved_at) end,
    'order', case when o.id is null then null else jsonb_build_object(
      'ref', o.ref, 'item', o.item, 'qty', o.qty, 'deadline', o.deadline, 'urgency', o.urgency, 'notes', o.notes) end,
    'after', after_stage,
    'next', case when nxt.ref is null then null else jsonb_build_object('ref', nxt.ref, 'qty', nxt.qty, 'item', nxt.item) end);
end $$;

revoke all on function public.ws_new_code() from public, anon, authenticated;
revoke all on function public.ws_room(text), public.ws_room_add_photo(text, text), public.ws_room_message(text, text), public.ws_room_approve(text) from public;
grant execute on function public.ws_room(text)                    to anon, authenticated;
grant execute on function public.ws_room_add_photo(text, text)    to anon, authenticated;
grant execute on function public.ws_room_message(text, text)      to anon, authenticated;
grant execute on function public.ws_room_approve(text)            to anon, authenticated;
revoke all on function public.ws_room_reply(uuid, text), public.ws_room_unapprove(uuid), public.ws_foreman_room_code(text, uuid) from public, anon;
grant execute on function public.ws_room_reply(uuid, text)        to authenticated;
grant execute on function public.ws_room_unapprove(uuid)          to authenticated;
grant execute on function public.ws_foreman_room_code(text, uuid) to authenticated;
grant execute on function public.ws_my_job(uuid)                  to authenticated;

create or replace function public.ws_room_ok(p_code text) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.ws_orders where room_code = lower(trim(p_code)));
$$;
grant execute on function public.ws_room_ok(text) to anon, authenticated;

-- ---------- the customers' photo store (secret addresses, no listing) ----------
do $do$
begin
  if exists (select 1 from information_schema.schemata where schema_name = 'storage') then
    insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
    values ('room-files', 'room-files', true, 10485760, array['image/jpeg','image/png','image/webp','image/gif','image/heic','image/heif'])
    on conflict (id) do update set public = true, file_size_limit = excluded.file_size_limit, allowed_mime_types = excluded.allowed_mime_types;

    drop policy if exists "room files customer add"  on storage.objects;
    drop policy if exists "room files customer read" on storage.objects;
    drop policy if exists "room files owner read"    on storage.objects;
    drop policy if exists "room files workshop read" on storage.objects;
    -- a customer may add photos only inside their own room's folder (room/<their code>/<random name>).
    -- Nobody may LIST the folders; a photo opens only with its full secret address
    -- (the room code + a random file name), which only that room knows.
    create policy "room files customer add" on storage.objects for insert to anon, authenticated
      with check (bucket_id = 'room-files' and (storage.foldername(name))[1] = 'room'
                  and public.ws_room_ok((storage.foldername(name))[2]));
    create policy "room files owner read" on storage.objects for select to authenticated
      using (bucket_id = 'room-files' and public.is_admin());
  end if;
end $do$;


-- #####################################################################
-- ##  FILE: update-17-client-links.sql
-- #####################################################################

-- =====================================================================
--  UPDATE 17: the manager can send any client their Order Room link
--  Paste ALL of this into Supabase → SQL Editor → New query → Run.
--  Safe to run again. Needs update-16 first.
-- =====================================================================

-- open orders with their client link code, newest first (no money, ever)
create or replace function public.ws_foreman_rooms(p_pin text) returns jsonb
language plpgsql security definer set search_path = public as $$
begin
  perform public.ws_foreman_ok(p_pin);
  return coalesce((
    select jsonb_agg(jsonb_build_object(
             'id', o.id, 'ref', o.ref, 'customer', o.customer, 'item', o.item, 'qty', o.qty,
             'notes', o.notes, 'room', o.room_code, 'approved', o.approved_at, 'at', o.created_at)
           order by o.created_at desc)
    from (select * from public.ws_orders
          where delivered_at is null and room_code is not null
          order by created_at desc limit 80) o
  ), '[]'::jsonb);
end $$;

revoke all on function public.ws_foreman_rooms(text) from public, anon;
grant execute on function public.ws_foreman_rooms(text) to authenticated;


-- #####################################################################
-- ##  FILE: update-18-payments.sql
-- #####################################################################

-- =====================================================================
--  UPDATE 18: invoice and payments, WITHOUT any money amounts
--  Paste ALL of this into Supabase → SQL Editor → New query → Run.
--  Safe to run again. Needs update-16 and update-17 first.
--
--  How it works:
--   • The owner makes the invoice as usual and sends it on WhatsApp.
--     The app only remembers THAT it was sent, never the amounts.
--   • New orders wait ("on hold") until the owner confirms the half
--     payment. The workshop does not get them before that.
--   • The client taps "I've paid half" in their Order Room and types the
--     M-Pesa code. The owner checks M-Pesa and taps "Half payment received".
--   • Before delivery: the same for the rest. "Delivered" stays locked
--     until the order is fully paid.
--   • Workers only ever see "Deposit confirmed".
-- =====================================================================

-- ---------- the order remembers the payment steps (no amounts) ----------
alter table public.ws_orders add column if not exists on_hold        boolean not null default false;
alter table public.ws_orders add column if not exists invoice_at     timestamptz;
alter table public.ws_orders add column if not exists dep_code       text;
alter table public.ws_orders add column if not exists dep_claimed_at timestamptz;
alter table public.ws_orders add column if not exists dep_ok_at      timestamptz;
alter table public.ws_orders add column if not exists bal_code       text;
alter table public.ws_orders add column if not exists bal_claimed_at timestamptz;
alter table public.ws_orders add column if not exists paid_at        timestamptz;
-- orders that already exist keep going; every NEW order waits for the half payment
alter table public.ws_orders alter column on_hold set default true;

create or replace function public.ws_held(p_order uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce((select on_hold from public.ws_orders where id = p_order), false);
$$;

-- ---------- where the client sends money (a phone number and a name) ----------
create or replace function public.ws_pay_settings() returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  perform public.ws_need_owner();
  return jsonb_build_object(
    'phone', (select value from public.ws_settings where key = 'pay_phone'),
    'name',  (select value from public.ws_settings where key = 'pay_name'));
end $$;

create or replace function public.ws_set_pay(p_phone text, p_name text) returns void
language plpgsql security definer set search_path = public as $$
declare ph text := regexp_replace(coalesce(p_phone, ''), '[^0-9+]', '', 'g');
begin
  perform public.ws_need_owner();
  if ph !~ '^(\+?254|0)[17][0-9]{8}$' then raise exception 'Type the M-Pesa number like 0712 345 678'; end if;
  if length(trim(coalesce(p_name, ''))) < 2 then raise exception 'Type the name M-Pesa shows for that number'; end if;
  insert into public.ws_settings (key, value) values ('pay_phone', ph) on conflict (key) do update set value = excluded.value, updated_at = now();
  insert into public.ws_settings (key, value) values ('pay_name', left(trim(p_name), 60)) on conflict (key) do update set value = excluded.value, updated_at = now();
end $$;

-- ---------- the workshop skips orders that are waiting for the half payment ----------
create or replace function public.ws_release(p_stage text) returns void
language plpgsql security definer set search_path = public as $$
declare w record; tid uuid; o public.ws_orders; jt public.ws_tasks; mate text;
begin
  for w in select wk.* from public.ws_workers wk
            where public.ws_is_here(wk) and wk.task_id is null
              and (wk.stage = p_stage
                   or exists (select 1 from public.ws_tasks q where q.stage = p_stage and q.status in ('queued','assigned','working') and wk.id = any(q.planned) and not public.ws_held(q.order_id))
                   or (p_stage = any(wk.covers)
                       and not exists (select 1 from public.ws_tasks q where q.stage = wk.stage and q.status = 'queued' and not public.ws_held(q.order_id))))
            order by exists (select 1 from public.ws_tasks q where q.stage = p_stage and q.status in ('queued','assigned','working') and wk.id = any(q.planned) and not public.ws_held(q.order_id)) desc,
                     (wk.stage = p_stage) desc, wk.arrived_at nulls last, wk.created_at loop
    -- 1. picked to help on a job someone already has → join them
    jt := null;
    select * into jt from public.ws_tasks q
     where q.stage = p_stage and q.status in ('assigned','working') and w.id = any(q.planned) and q.worker_id is distinct from w.id
     order by q.rank limit 1;
    if jt.id is not null then
      mate := public.ws_task_names(jt.id);
      update public.ws_workers set task_id = jt.id, waiting_logged = false where id = w.id;
      select * into o from public.ws_orders where id = jt.order_id;
      perform public.ws_note('info', w.name || ' joined ' || coalesce(mate, 'the job') || ' on ' || o.ref || ' · ' || public.ws_stage_name(p_stage), o.id);
      continue;
    end if;
    -- 2. next job in line (never one that is waiting for the half payment)
    tid := null;
    select q.id into tid from public.ws_tasks q
     where q.stage = p_stage and q.status = 'queued' and not public.ws_held(q.order_id)
       and (w.id = any(q.planned)
            or ((w.stage = p_stage or p_stage = any(w.covers))
                and not exists (select 1 from public.ws_workers pw where pw.id = any(q.planned) and public.ws_is_here(pw))))
     order by (w.id = any(q.planned)) desc, q.rank limit 1 for update skip locked;
    if tid is null then
      if w.stage = p_stage and not w.waiting_logged
         and not exists (select 1 from public.ws_tasks q where q.stage = p_stage and q.status = 'queued' and not public.ws_held(q.order_id)) then
        perform public.ws_note('warn', w.name || ' (' || public.ws_stage_name(p_stage) || ') has no work waiting');
        update public.ws_workers set waiting_logged = true where id = w.id;
      end if;
      continue;
    end if;
    update public.ws_tasks set status = 'assigned', worker_id = w.id, assigned_at = now() where id = tid;
    update public.ws_workers set task_id = tid, waiting_logged = false where id = w.id;
    select o2.* into o from public.ws_orders o2 join public.ws_tasks t on t.order_id = o2.id where t.id = tid;
    perform public.ws_note('info', w.name || ' got the next job: ' || o.ref || ' · ' || public.ws_stage_name(p_stage)
      || case when w.stage <> p_stage and not exists (select 1 from public.ws_tasks where id = tid and w.id = any(planned)) then ' (covering)' else '' end, o.id);
  end loop;
end $$;

-- giving a held job by hand is blocked too
create or replace function public.ws_give_task(p_task uuid, p_worker uuid) returns void
language plpgsql security definer set search_path = public as $$
declare t public.ws_tasks; w public.ws_workers; o public.ws_orders; busy text;
begin
  perform public.ws_need_owner();
  select * into t from public.ws_tasks where id = p_task for update;
  if t.id is null or t.status = 'done' then raise exception 'This step is already finished'; end if;
  if t.status = 'waiting' then raise exception 'This step is not ready yet. The step before it is not finished.'; end if;
  if public.ws_held(t.order_id) and t.status = 'queued' then
    raise exception 'This order is waiting for the half payment. Confirm the payment (or tap "Start without payment") first.';
  end if;
  select * into w from public.ws_workers where id = p_worker for update;
  if w.id is null or not public.ws_is_here(w) then raise exception 'That worker is away or switched off'; end if;
  if t.worker_id = w.id then return; end if;
  if w.task_id is not null then
    select o2.ref into busy from public.ws_tasks x join public.ws_orders o2 on o2.id = x.order_id where x.id = w.task_id;
    raise exception '% is busy on %. Wait until they finish, or mark them away.', w.name, coalesce(busy, 'another job');
  end if;
  if t.worker_id is not null then
    update public.ws_workers set task_id = null where id = t.worker_id;
  end if;
  update public.ws_tasks set status = 'assigned', worker_id = w.id, assigned_at = now(), started_at = null where id = t.id;
  update public.ws_workers set task_id = t.id, waiting_logged = false where id = w.id;
  select * into o from public.ws_orders where id = t.order_id;
  perform public.ws_note('info', 'Owner gave ' || o.ref || ' · ' || public.ws_stage_name(t.stage) || ' to ' || w.name, o.id);
  perform public.ws_release_all();
end $$;

-- "Delivered" only when fully paid
create or replace function public.ws_deliver(p_order uuid) returns void
language plpgsql security definer set search_path = public as $$
declare o public.ws_orders;
begin
  perform public.ws_need_owner();
  if exists (select 1 from public.ws_tasks where order_id = p_order and status <> 'done') then raise exception 'This order is not finished yet'; end if;
  if (select paid_at from public.ws_orders where id = p_order) is null then
    raise exception 'The balance is not paid yet. Confirm "Fully paid" first, then mark it delivered.';
  end if;
  update public.ws_orders set delivered_at = now() where id = p_order returning * into o;
  perform public.ws_note('good', o.ref || ' delivered to ' || o.customer, o.id);
  perform public.ws_sync_source(o.source_order_id);
end $$;

-- ---------- owner: the payment steps ----------
create or replace function public.ws_invoice_sent(p_order uuid) returns void
language plpgsql security definer set search_path = public as $$
declare o public.ws_orders;
begin
  perform public.ws_need_owner();
  update public.ws_orders set invoice_at = coalesce(invoice_at, now()) where id = p_order returning * into o;
  if o.id is null then raise exception 'Order not found'; end if;
  if not exists (select 1 from public.ws_room_msgs where order_id = o.id and who = 'kartech' and text like '📄%') then
    insert into public.ws_room_msgs (order_id, who, text)
    values (o.id, 'kartech', '📄 We sent your invoice on WhatsApp. To start, pay half and tap "I''ve paid half" in Payment above.');
  end if;
end $$;

create or replace function public.ws_hold(p_order uuid, p_hold boolean) returns void
language plpgsql security definer set search_path = public as $$
declare o public.ws_orders;
begin
  perform public.ws_need_owner();
  if p_hold and exists (select 1 from public.ws_tasks where order_id = p_order and status in ('assigned','working','done')) then
    raise exception 'Work on this order has already started, so it cannot wait any more.';
  end if;
  update public.ws_orders set on_hold = p_hold where id = p_order returning * into o;
  if not p_hold then
    perform public.ws_note('info', o.ref || ' can start now', o.id);
    perform public.ws_release_all();
  end if;
end $$;

-- p_part: 'half' or 'full'
create or replace function public.ws_pay_ok(p_order uuid, p_part text) returns void
language plpgsql security definer set search_path = public as $$
declare o public.ws_orders; was_held boolean;
begin
  perform public.ws_need_owner();
  select * into o from public.ws_orders where id = p_order for update;
  if o.id is null then raise exception 'Order not found'; end if;
  was_held := o.on_hold;
  if p_part = 'half' then
    if o.dep_ok_at is not null then return; end if;
    update public.ws_orders set dep_ok_at = now(), on_hold = false where id = o.id;
    insert into public.ws_room_msgs (order_id, who, text) values (o.id, 'kartech',
      case when was_held then '✓ Half payment received. Thank you! Your order is now in the workshop.' else '✓ Half payment received. Thank you!' end);
    perform public.ws_note('good', o.ref || ' · deposit confirmed' || case when was_held then ', the workshop can start' else '' end, o.id);
  elsif p_part = 'full' then
    if o.paid_at is not null then return; end if;
    update public.ws_orders set paid_at = now(), dep_ok_at = coalesce(dep_ok_at, now()), on_hold = false where id = o.id;
    insert into public.ws_room_msgs (order_id, who, text) values (o.id, 'kartech', '✓ Fully paid. Thank you! We will let you know the delivery day.');
    perform public.ws_note('good', o.ref || ' · fully paid' || case when was_held then ', the workshop can start' else '' end, o.id);
  else
    raise exception 'Unknown payment step';
  end if;
  if was_held then perform public.ws_release_all(); end if;
end $$;

-- the client's code could not be found in M-Pesa
create or replace function public.ws_pay_not_found(p_order uuid, p_part text) returns void
language plpgsql security definer set search_path = public as $$
declare o public.ws_orders; code text;
begin
  perform public.ws_need_owner();
  select * into o from public.ws_orders where id = p_order;
  if o.id is null then raise exception 'Order not found'; end if;
  code := case when p_part = 'half' then o.dep_code else o.bal_code end;
  if p_part = 'half' then update public.ws_orders set dep_code = null, dep_claimed_at = null where id = o.id;
  else update public.ws_orders set bal_code = null, bal_claimed_at = null where id = o.id; end if;
  insert into public.ws_room_msgs (order_id, who, text) values (o.id, 'kartech',
    'We could not find your payment' || coalesce(' (code ' || code || ')', '') || ' yet. Please check the M-Pesa code and tap "I''ve paid" again, or call us.');
end $$;

-- tapped "received" by mistake
create or replace function public.ws_pay_undo(p_order uuid, p_part text) returns void
language plpgsql security definer set search_path = public as $$
begin
  perform public.ws_need_owner();
  if p_part = 'half' then update public.ws_orders set dep_ok_at = null where id = p_order and paid_at is null;
  else update public.ws_orders set paid_at = null where id = p_order and delivered_at is null; end if;
end $$;

-- ---------- the client: "I've paid" + M-Pesa code ----------
create or replace function public.ws_room_paid(p_code text, p_part text, p_txn text) returns void
language plpgsql security definer set search_path = public as $$
declare o public.ws_orders; c text := upper(regexp_replace(coalesce(p_txn, ''), '[^A-Za-z0-9]', '', 'g')); first text;
begin
  select * into o from public.ws_orders where room_code = lower(trim(p_code));
  if o.id is null then raise exception 'Order not found'; end if;
  if c !~ '^[A-Z0-9]{8,12}$' then raise exception 'Type the M-Pesa code from your SMS, e.g. SJK7XQ2M4P'; end if;
  if o.invoice_at is null then raise exception 'Kartech has not sent the invoice yet.'; end if;
  if (select count(*) from public.ws_room_msgs where order_id = o.id and who = 'customer' and text like '💳%' and at > now() - interval '1 hour') >= 6 then
    raise exception 'Please wait a little before trying again.';
  end if;
  first := split_part(trim(o.customer), ' ', 1);
  if p_part = 'half' then
    if o.dep_ok_at is not null then raise exception 'Your half payment is already confirmed.'; end if;
    update public.ws_orders set dep_code = c, dep_claimed_at = now() where id = o.id;
    insert into public.ws_room_msgs (order_id, who, text) values (o.id, 'customer', '💳 I''ve paid half · M-Pesa code ' || c);
    perform public.ws_note('alert', first || ' says the half payment for ' || o.ref || ' is sent · M-Pesa code ' || c || '. Check it and confirm.', o.id);
  elsif p_part = 'full' then
    if o.paid_at is not null then raise exception 'Your order is already fully paid.'; end if;
    update public.ws_orders set bal_code = c, bal_claimed_at = now() where id = o.id;
    insert into public.ws_room_msgs (order_id, who, text) values (o.id, 'customer',
      case when o.dep_ok_at is null then '💳 I''ve paid it all · M-Pesa code ' else '💳 I''ve paid the balance · M-Pesa code ' end || c);
    perform public.ws_note('alert', first || ' says ' || case when o.dep_ok_at is null then 'the full payment' else 'the balance' end || ' for ' || o.ref || ' is sent · M-Pesa code ' || c || '. Check it and confirm.', o.id);
  else
    raise exception 'Unknown payment step';
  end if;
end $$;

-- the client's Order Room now includes the payment steps (still no amounts)
create or replace function public.ws_room(p_code text) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare o public.ws_orders;
begin
  select * into o from public.ws_orders where room_code = lower(trim(p_code));
  if o.id is null then return null; end if;
  return jsonb_build_object(
    'ref', o.ref, 'item', o.item, 'qty', o.qty, 'name', split_part(trim(o.customer), ' ', 1),
    'deadline', o.deadline, 'delivered', o.delivered_at is not null, 'approved_at', o.approved_at,
    'notes', o.notes, 'delivery_on', o.delivery_on,
    'pay', case when o.invoice_at is null and o.dep_ok_at is null and o.paid_at is null then null else jsonb_build_object(
      'invoice', o.invoice_at is not null,
      'phone', (select value from public.ws_settings where key = 'pay_phone'),
      'to',    (select value from public.ws_settings where key = 'pay_name'),
      'dep_claimed', o.dep_claimed_at is not null, 'dep_code', o.dep_code, 'dep_ok', o.dep_ok_at,
      'bal_claimed', o.bal_claimed_at is not null, 'bal_code', o.bal_code, 'paid', o.paid_at,
      'hold', o.on_hold) end,
    'steps', (select coalesce(jsonb_agg(jsonb_build_object('name', g.grp, 'status', g.st) order by g.first_step), '[]'::jsonb)
                from (select public.ws_step_group(t.stage) grp, min(t.step) first_step,
                             case when bool_and(t.status = 'done') then 'done'
                                  when bool_or(t.status in ('working', 'assigned', 'done')) then 'working' else 'waiting' end st
                        from public.ws_tasks t where t.order_id = o.id group by 1) g),
    'photos', (select coalesce(jsonb_agg(jsonb_build_object('path', p.path, 'at', p.at) order by p.id), '[]'::jsonb)
                 from public.ws_photos p where p.order_id = o.id and p.bucket = 'room-files'),
    'msgs', (select coalesce(jsonb_agg(jsonb_build_object('who', m.who, 'text', m.text, 'at', m.at) order by m.id), '[]'::jsonb)
               from (select * from public.ws_room_msgs where order_id = o.id order by id desc limit 100) m));
end $$;

-- the worker's job card: only "Deposit confirmed", never anything else about money
create or replace function public.ws_my_job(p_token uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare w public.ws_workers; t public.ws_tasks; o public.ws_orders; nxt record; after_stage text; mates text;
begin
  w := public.ws_me(p_token);
  if w.task_id is not null then
    select * into t from public.ws_tasks where id = w.task_id;
    select * into o from public.ws_orders where id = t.order_id;
    after_stage := o.stages[t.step + 1];
    select string_agg(name, ' & ' order by name) into mates from public.ws_workers where task_id = t.id and id <> w.id;
  end if;
  select o2.ref, o2.qty, o2.item into nxt from public.ws_tasks q join public.ws_orders o2 on o2.id = q.order_id
   where q.stage = w.stage and q.status = 'queued' and not o2.on_hold order by q.rank limit 1;
  return jsonb_build_object(
    'worker', jsonb_build_object('name', w.name, 'stage', w.stage),
    'task', case when t.id is null then null else jsonb_build_object(
      'status', t.status, 'stage', t.stage, 'problem_reason', t.problem_reason, 'problem_stopped', t.problem_stopped,
      'problem_ack', t.problem_ack_at is not null, 'with', mates, 'approved', o.approved_at, 'deposit', o.dep_ok_at is not null) end,
    'order', case when o.id is null then null else jsonb_build_object(
      'ref', o.ref, 'item', o.item, 'qty', o.qty, 'deadline', o.deadline, 'urgency', o.urgency, 'notes', o.notes) end,
    'after', after_stage,
    'next', case when nxt.ref is null then null else jsonb_build_object('ref', nxt.ref, 'qty', nxt.qty, 'item', nxt.item) end);
end $$;

-- the manager's client list says when an order is waiting for the deposit (nothing else)
create or replace function public.ws_foreman_rooms(p_pin text) returns jsonb
language plpgsql security definer set search_path = public as $$
begin
  perform public.ws_foreman_ok(p_pin);
  return coalesce((
    select jsonb_agg(jsonb_build_object(
             'id', o.id, 'ref', o.ref, 'customer', o.customer, 'item', o.item, 'qty', o.qty,
             'notes', o.notes, 'room', o.room_code, 'approved', o.approved_at, 'at', o.created_at,
             'hold', o.on_hold)
           order by o.created_at desc)
    from (select * from public.ws_orders
          where delivered_at is null and room_code is not null
          order by created_at desc limit 80) o
  ), '[]'::jsonb);
end $$;

-- ---------- who may use what ----------
revoke all on function public.ws_pay_settings(), public.ws_set_pay(text, text), public.ws_invoice_sent(uuid),
  public.ws_hold(uuid, boolean), public.ws_pay_ok(uuid, text), public.ws_pay_not_found(uuid, text),
  public.ws_pay_undo(uuid, text), public.ws_held(uuid) from public, anon;
grant execute on function public.ws_pay_settings(), public.ws_set_pay(text, text), public.ws_invoice_sent(uuid),
  public.ws_hold(uuid, boolean), public.ws_pay_ok(uuid, text), public.ws_pay_not_found(uuid, text),
  public.ws_pay_undo(uuid, text), public.ws_held(uuid) to authenticated;
grant execute on function public.ws_room_paid(text, text, text) to anon, authenticated;
grant execute on function public.ws_room(text) to anon, authenticated;


-- #####################################################################
-- ##  FILE: update-19-fix-client-photos.sql
-- #####################################################################

-- =====================================================================
--  UPDATE 19: fix "permission denied for table ws_orders" when a client
--  adds a photo in their Order Room.
--  Paste ALL of this into Supabase → SQL Editor → New query → Run.
--  Safe to run again.
-- =====================================================================

-- checks a room code without giving clients access to the orders table
create or replace function public.ws_room_ok(p_code text) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.ws_orders where room_code = lower(trim(p_code)));
$$;
grant execute on function public.ws_room_ok(text) to anon, authenticated;

drop policy if exists "room files customer add" on storage.objects;
create policy "room files customer add" on storage.objects for insert to anon, authenticated
  with check (bucket_id = 'room-files' and (storage.foldername(name))[1] = 'room'
              and public.ws_room_ok((storage.foldername(name))[2]));


-- #####################################################################
-- ##  FILE: update-20-find-my-order.sql
-- #####################################################################

-- =====================================================================
--  UPDATE 20: a client finds their order with their phone number
--  (no link to keep). Paste ALL into Supabase → SQL Editor → Run.
--  Safe to run again.
-- =====================================================================
create or replace function public.ws_find_rooms(p_phone text) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare d text := regexp_replace(coalesce(p_phone, ''), '\D', '', 'g');
begin
  -- the last 9 digits of a Kenyan number: 0712 345 678 / +254 712 345 678 → 712345678
  if length(d) < 9 then raise exception 'Type your full phone number, e.g. 0712 345 678'; end if;
  d := right(d, 9);
  return coalesce((
    select jsonb_agg(jsonb_build_object('ref', o.ref, 'item', o.item, 'qty', o.qty, 'code', o.room_code,
                                        'delivered', o.delivered_at is not null) order by o.created_at desc)
    from public.ws_orders o
    where o.room_code is not null
      and (o.delivered_at is null or o.delivered_at > now() - interval '60 days')
      and (regexp_replace(o.customer, '\D', '', 'g') like '%' || d || '%'
           or regexp_replace(coalesce(o.notes, ''), '\D', '', 'g') like '%' || d || '%'
           or exists (select 1 from public.orders w where w.id = o.source_order_id
                        and regexp_replace(coalesce(w.phone, ''), '\D', '', 'g') like '%' || d))
  ), '[]'::jsonb);
end $$;
grant execute on function public.ws_find_rooms(text) to anon, authenticated;


-- #####################################################################
-- ##  FILE: update-21-bin.sql
-- #####################################################################

-- =====================================================================
--  UPDATE 21: the Bin 🗑
--  Deleted orders and pictures are kept in the Bin for 30 days, so the
--  owner can bring them back. After 30 days they are gone for good.
--  Paste ALL of this into Supabase → SQL Editor → New query → Run.
--  Safe to run again.
-- =====================================================================

create table if not exists public.ws_bin (
  id     bigserial primary key,
  at     timestamptz not null default now(),
  kind   text not null check (kind in ('order','photo')),
  label  text not null,
  data   jsonb not null
);
alter table public.ws_bin enable row level security;
drop policy if exists "owner reads the bin" on public.ws_bin;
create policy "owner reads the bin" on public.ws_bin for select to authenticated using (public.is_admin());

-- deleting an order: keep a full copy in the Bin first
create or replace function public.ws_delete_order(p_order uuid) returns void
language plpgsql security definer set search_path = public as $$
declare o public.ws_orders;
begin
  perform public.ws_need_owner();
  select * into o from public.ws_orders where id = p_order for update;
  if o.id is null then raise exception 'Order not found'; end if;
  delete from public.ws_bin where at < now() - interval '30 days';
  insert into public.ws_bin (kind, label, data) values ('order',
    o.ref || ' · ' || o.qty || ' × ' || o.item || ' · ' || o.customer,
    jsonb_build_object(
      'order',  to_jsonb(o),
      'tasks',  coalesce((select jsonb_agg(to_jsonb(t)) from public.ws_tasks t where t.order_id = o.id), '[]'::jsonb),
      'photos', coalesce((select jsonb_agg(to_jsonb(p)) from public.ws_photos p where p.order_id = o.id), '[]'::jsonb),
      'msgs',   coalesce((select jsonb_agg(to_jsonb(m)) from public.ws_room_msgs m where m.order_id = o.id), '[]'::jsonb)));
  -- free anyone holding a job from this order
  update public.ws_workers set task_id = null, waiting_logged = false
   where task_id in (select id from public.ws_tasks where order_id = o.id);
  delete from public.ws_orders where id = o.id;
  -- a website order goes back to "waiting" so it can be sent again
  if o.source_order_id is not null and not exists (select 1 from public.ws_orders where source_order_id = o.source_order_id) then
    update public.orders set status = 'confirmed', status_note = null where id = o.source_order_id;
  end if;
  perform public.ws_note('warn', o.ref || ' moved to the Bin (' || o.qty || ' × ' || o.item || ' for ' || o.customer || ')');
  perform public.ws_release_all();
end $$;

-- removing a picture: keep it in the Bin (the file itself is kept too)
create or replace function public.ws_remove_photo(p_id bigint) returns text
language plpgsql security definer set search_path = public as $$
declare p public.ws_photos; o public.ws_orders;
begin
  perform public.ws_need_owner();
  select * into p from public.ws_photos where id = p_id;
  if p.id is null then return null; end if;
  select * into o from public.ws_orders where id = p.order_id;
  delete from public.ws_bin where at < now() - interval '30 days';
  insert into public.ws_bin (kind, label, data) values ('photo',
    'Picture from ' || coalesce(o.ref || ' · ' || o.item, 'an order'), jsonb_build_object('photo', to_jsonb(p)));
  delete from public.ws_photos where id = p.id;
  return null;   -- null = the app must NOT delete the file (it is in the Bin)
end $$;

-- bring something back
create or replace function public.ws_bin_restore(p_id bigint) returns text
language plpgsql security definer set search_path = public as $$
declare b public.ws_bin; oid uuid; o public.ws_orders;
begin
  perform public.ws_need_owner();
  select * into b from public.ws_bin where id = p_id for update;
  if b.id is null then raise exception 'Already gone from the Bin'; end if;

  if b.kind = 'order' then
    oid := (b.data->'order'->>'id')::uuid;
    if exists (select 1 from public.ws_orders where id = oid) then raise exception 'This order is already back'; end if;
    insert into public.ws_orders select * from jsonb_populate_record(null::public.ws_orders, b.data->'order');
    insert into public.ws_tasks  select * from jsonb_populate_recordset(null::public.ws_tasks, b.data->'tasks');
    -- jobs that were in someone's hands go back in line (nobody is holding them now)
    update public.ws_tasks set status = 'queued', worker_id = null, assigned_at = null, started_at = null
     where order_id = oid and status in ('assigned', 'working');
    insert into public.ws_photos    select * from jsonb_populate_recordset(null::public.ws_photos, b.data->'photos');
    insert into public.ws_room_msgs select * from jsonb_populate_recordset(null::public.ws_room_msgs, b.data->'msgs');
    select * into o from public.ws_orders where id = oid;
    if o.source_order_id is not null then perform public.ws_sync_source(o.source_order_id); end if;
    delete from public.ws_bin where id = b.id;
    perform public.ws_note('good', o.ref || ' is back from the Bin', o.id);
    perform public.ws_release_all();
    return o.ref;
  else
    oid := (b.data->'photo'->>'order_id')::uuid;
    if not exists (select 1 from public.ws_orders where id = oid) then
      raise exception 'The order of this picture is not there any more. Bring the order back first.';
    end if;
    insert into public.ws_photos select * from jsonb_populate_record(null::public.ws_photos, b.data->'photo')
      on conflict (id) do nothing;
    delete from public.ws_bin where id = b.id;
    return 'picture';
  end if;
end $$;

-- delete for good (returns the picture files the app should remove from storage)
create or replace function public.ws_bin_forget(p_id bigint) returns jsonb
language plpgsql security definer set search_path = public as $$
declare b public.ws_bin; files jsonb;
begin
  perform public.ws_need_owner();
  select * into b from public.ws_bin where id = p_id;
  if b.id is null then return '[]'::jsonb; end if;
  files := case when b.kind = 'order'
    then coalesce((select jsonb_agg(jsonb_build_object('b', coalesce(x->>'bucket', 'kartech-photos'), 'p', x->>'path')) from jsonb_array_elements(b.data->'photos') x), '[]'::jsonb)
    else jsonb_build_array(jsonb_build_object('b', coalesce(b.data->'photo'->>'bucket', 'kartech-photos'), 'p', b.data->'photo'->>'path')) end;
  delete from public.ws_bin where id = b.id;
  return files;
end $$;

revoke all on function public.ws_bin_restore(bigint), public.ws_bin_forget(bigint) from public, anon;
grant execute on function public.ws_bin_restore(bigint), public.ws_bin_forget(bigint) to authenticated;

-- ---------- workers can be deleted too (kept in the Bin for 30 days) ----------
alter table public.ws_bin drop constraint if exists ws_bin_kind_check;
alter table public.ws_bin add constraint ws_bin_kind_check check (kind in ('order','photo','worker'));

create or replace function public.ws_delete_worker(p_worker uuid) returns void
language plpgsql security definer set search_path = public as $$
declare w public.ws_workers;
begin
  perform public.ws_need_owner();
  select * into w from public.ws_workers where id = p_worker for update;
  if w.id is null then raise exception 'Worker not found'; end if;
  delete from public.ws_bin where at < now() - interval '30 days';
  insert into public.ws_bin (kind, label, data) values ('worker',
    w.name || ' · ' || public.ws_stage_name(w.stage),
    jsonb_build_object(
      'worker', to_jsonb(w),
      'attendance', coalesce((select jsonb_agg(to_jsonb(a)) from public.ws_attendance a where a.worker_id = w.id), '[]'::jsonb),
      'done_tasks', coalesce((select jsonb_agg(t.id) from public.ws_tasks t where t.worker_id = w.id and t.status = 'done'), '[]'::jsonb)));
  -- a job in their hands goes back in line; take them off any planned steps
  update public.ws_tasks set status = 'queued', worker_id = null, assigned_at = null, started_at = null
   where worker_id = w.id and status in ('assigned', 'working');
  update public.ws_tasks set planned = array_remove(planned, w.id) where w.id = any(planned);
  delete from public.ws_workers where id = w.id;
  perform public.ws_note('warn', w.name || ' moved to the Bin');
  perform public.ws_release_all();
end $$;

-- restore now also handles workers
create or replace function public.ws_bin_restore(p_id bigint) returns text
language plpgsql security definer set search_path = public as $$
declare b public.ws_bin; oid uuid; o public.ws_orders; wk public.ws_workers;
begin
  perform public.ws_need_owner();
  select * into b from public.ws_bin where id = p_id for update;
  if b.id is null then raise exception 'Already gone from the Bin'; end if;

  if b.kind = 'order' then
    oid := (b.data->'order'->>'id')::uuid;
    if exists (select 1 from public.ws_orders where id = oid) then raise exception 'This order is already back'; end if;
    insert into public.ws_orders select * from jsonb_populate_record(null::public.ws_orders, b.data->'order');
    insert into public.ws_tasks  select * from jsonb_populate_recordset(null::public.ws_tasks, b.data->'tasks');
    update public.ws_tasks set status = 'queued', worker_id = null, assigned_at = null, started_at = null
     where order_id = oid and status in ('assigned', 'working');
    update public.ws_tasks set worker_id = null
     where order_id = oid and worker_id is not null and not exists (select 1 from public.ws_workers x where x.id = worker_id);
    insert into public.ws_photos    select * from jsonb_populate_recordset(null::public.ws_photos, b.data->'photos');
    insert into public.ws_room_msgs select * from jsonb_populate_recordset(null::public.ws_room_msgs, b.data->'msgs');
    select * into o from public.ws_orders where id = oid;
    if o.source_order_id is not null then perform public.ws_sync_source(o.source_order_id); end if;
    delete from public.ws_bin where id = b.id;
    perform public.ws_note('good', o.ref || ' is back from the Bin', o.id);
    perform public.ws_release_all();
    return o.ref;

  elsif b.kind = 'worker' then
    wk := jsonb_populate_record(null::public.ws_workers, b.data->'worker');
    if exists (select 1 from public.ws_workers where id = wk.id) then raise exception 'This worker is already back'; end if;
    if exists (select 1 from public.ws_workers where lower(name) = lower(wk.name)) then
      raise exception 'There is already a worker called %. Rename them first, then bring this one back.', wk.name;
    end if;
    wk.task_id := null; wk.waiting_logged := false;
    insert into public.ws_workers select wk.*;
    insert into public.ws_attendance select * from jsonb_populate_recordset(null::public.ws_attendance, b.data->'attendance')
      on conflict do nothing;
    update public.ws_tasks set worker_id = wk.id
     where id in (select (x #>> '{}')::uuid from jsonb_array_elements(b.data->'done_tasks') x) and worker_id is null;
    delete from public.ws_bin where id = b.id;
    perform public.ws_note('good', wk.name || ' is back from the Bin');
    perform public.ws_release_all();
    return wk.name;

  else
    oid := (b.data->'photo'->>'order_id')::uuid;
    if not exists (select 1 from public.ws_orders where id = oid) then
      raise exception 'The order of this picture is not there any more. Bring the order back first.';
    end if;
    insert into public.ws_photos select * from jsonb_populate_record(null::public.ws_photos, b.data->'photo')
      on conflict (id) do nothing;
    delete from public.ws_bin where id = b.id;
    return 'picture';
  end if;
end $$;

revoke all on function public.ws_delete_worker(uuid) from public, anon;
grant execute on function public.ws_delete_worker(uuid) to authenticated;


-- #####################################################################
-- ##  FILE: update-22-simple-assign.sql
-- #####################################################################

-- =====================================================================
--  UPDATE 22: simple assigning — the owner can mark a step done
--  Paste ALL of this into Supabase → SQL Editor → New query → Run.
--  Safe to run again.
-- =====================================================================
create or replace function public.ws_owner_done(p_task uuid) returns void
language plpgsql security definer set search_path = public as $$
declare t public.ws_tasks; o public.ws_orders; who text;
begin
  perform public.ws_need_owner();
  select * into t from public.ws_tasks where id = p_task for update;
  if t.id is null then raise exception 'Step not found'; end if;
  if t.status = 'done' then return; end if;
  select * into o from public.ws_orders where id = t.order_id;
  who := case when t.worker_id is not null then public.ws_task_names(t.id) end;
  update public.ws_tasks set status = 'done', done_at = now(),
    problem_reason = null, problem_stopped = null, problem_at = null, problem_ack_at = null where id = t.id;
  update public.ws_workers set task_id = null, waiting_logged = false where task_id = t.id;
  perform public.ws_note('good', 'Owner marked ' || o.ref || ' · ' || public.ws_stage_name(t.stage) || ' done' || coalesce(' (' || who || ')', ''), o.id);
  perform public.ws_advance(o.id);
  if not exists (select 1 from public.ws_tasks where order_id = o.id and status <> 'done') then
    perform public.ws_note('good', o.ref || ' is finished. Ready for delivery.', o.id);
  end if;
  perform public.ws_release_all();
  perform public.ws_sync_source(o.source_order_id);
end $$;
revoke all on function public.ws_owner_done(uuid) from public, anon;
grant execute on function public.ws_owner_done(uuid) to authenticated;


-- #####################################################################
-- ##  FILE: update-23-invoices-receipts.sql
-- #####################################################################

-- =====================================================================
--  UPDATE 23: invoices and official receipts (with amounts)
--  Paste ALL of this into Supabase → SQL Editor → New query → Run.
--  Safe to run again. Needs updates 1–22 first.
--
--  • Only the OWNER can see or create invoices, payments and receipts.
--    The manager, the workshop screen and workers can never read them
--    (the database refuses, not just the screen).
--  • Any payment the owner confirms starts the workshop.
--  • When the balance reaches 0 the order counts as fully paid and
--    "Delivered" unlocks.
--  • Each invoice/receipt has a secret check code for the QR on the PDF,
--    so anyone holding the PDF can check it is genuine.
-- =====================================================================

-- ---------- numbering: INV-2026-0001, RCT-2026-0001 ----------
create table if not exists public.kt_counters (key text primary key, n int not null default 0);
alter table public.kt_counters enable row level security;

create or replace function public.kt_next_no(p_prefix text) returns text
language plpgsql security definer set search_path = public as $$
declare k text := p_prefix || '-' || to_char(now() at time zone 'Africa/Nairobi', 'YYYY'); v int;
begin
  insert into public.kt_counters (key, n) values (k, 1)
  on conflict (key) do update set n = kt_counters.n + 1 returning n into v;
  return k || '-' || lpad(v::text, 4, '0');
end $$;

-- ---------- invoices and payments ----------
create table if not exists public.kt_invoices (
  id          uuid primary key default gen_random_uuid(),
  no          text unique not null,
  order_id    uuid references public.ws_orders(id) on delete set null,
  order_ref   text,
  customer    text not null,
  phone       text,
  items       jsonb not null,                -- [{ "desc": "...", "qty": 6, "price": 4500 }]
  total       numeric(12,2) not null check (total > 0),
  due_date    date,
  check_code  text unique not null default public.ws_new_code(),
  created_at  timestamptz not null default now(),
  sent_at     timestamptz
);
create table if not exists public.kt_payments (
  id          uuid primary key default gen_random_uuid(),
  no          text unique not null,
  invoice_id  uuid not null references public.kt_invoices(id) on delete cascade,
  amount      numeric(12,2) not null check (amount > 0),
  method      text not null check (method in ('M-Pesa','Cash','Bank','Other')),
  reference   text,
  check_code  text unique not null default public.ws_new_code(),
  created_at  timestamptz not null default now(),
  sent_at     timestamptz
);
create index if not exists kt_invoices_order on public.kt_invoices(order_id);
create index if not exists kt_payments_invoice on public.kt_payments(invoice_id);

alter table public.kt_invoices enable row level security;
alter table public.kt_payments enable row level security;
drop policy if exists "owner reads invoices" on public.kt_invoices;
drop policy if exists "owner reads payments" on public.kt_payments;
create policy "owner reads invoices" on public.kt_invoices for select to authenticated using (public.is_admin());
create policy "owner reads payments" on public.kt_payments for select to authenticated using (public.is_admin());
revoke insert, update, delete on public.kt_invoices, public.kt_payments, public.kt_counters from anon, authenticated;
revoke all on public.kt_invoices, public.kt_payments, public.kt_counters from anon;

create or replace function public.kt_paid(p_invoice uuid) returns numeric
language sql stable security definer set search_path = public as $$
  select coalesce(sum(amount), 0) from public.kt_payments where invoice_id = p_invoice;
$$;

-- ---------- business details printed on the PDFs ----------
create or replace function public.kt_business() returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  perform public.ws_need_owner();
  return jsonb_build_object(
    'phone',   coalesce((select value from public.ws_settings where key = 'biz_phone'), (select value from public.ws_settings where key = 'pay_phone')),
    'address', coalesce((select value from public.ws_settings where key = 'biz_address'), 'Outer Ring Road, Umoja (Mtindwa), Nairobi'),
    'kra',     (select value from public.ws_settings where key = 'biz_kra'),
    'pay_phone', (select value from public.ws_settings where key = 'pay_phone'),
    'pay_name',  (select value from public.ws_settings where key = 'pay_name'));
end $$;

create or replace function public.kt_set_business(p_phone text, p_address text, p_kra text) returns void
language plpgsql security definer set search_path = public as $$
begin
  perform public.ws_need_owner();
  insert into public.ws_settings (key, value) values ('biz_phone', left(trim(coalesce(p_phone, '')), 30)) on conflict (key) do update set value = excluded.value, updated_at = now();
  insert into public.ws_settings (key, value) values ('biz_address', left(trim(coalesce(p_address, '')), 120)) on conflict (key) do update set value = excluded.value, updated_at = now();
  insert into public.ws_settings (key, value) values ('biz_kra', upper(left(trim(coalesce(p_kra, '')), 20))) on conflict (key) do update set value = excluded.value, updated_at = now();
end $$;

-- ---------- owner: make or change the invoice for an order ----------
create or replace function public.kt_save_invoice(p_order uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare o public.ws_orders; inv public.kt_invoices; it jsonb; tot numeric(12,2) := 0; clean jsonb := '[]'::jsonb;
        q numeric; pr numeric; d text;
begin
  perform public.ws_need_owner();
  select * into o from public.ws_orders where id = p_order;
  if o.id is null then raise exception 'Order not found'; end if;
  for it in select * from jsonb_array_elements(coalesce(p->'items', '[]'::jsonb)) loop
    d := left(trim(coalesce(it->>'desc', '')), 200);
    q := nullif(it->>'qty', '')::numeric; pr := nullif(it->>'price', '')::numeric;
    if d = '' and q is null and pr is null then continue; end if;
    if d = '' then raise exception 'Every line needs a description'; end if;
    if q is null or q <= 0 or q <> trunc(q) then raise exception 'Quantity must be a whole number, 1 or more'; end if;
    if pr is null or pr < 0 then raise exception 'Type the price for "%"', d; end if;
    clean := clean || jsonb_build_array(jsonb_build_object('desc', d, 'qty', q, 'price', round(pr, 2)));
    tot := tot + round(q * pr, 2);
  end loop;
  if jsonb_array_length(clean) = 0 then raise exception 'Add at least one line with a price'; end if;
  if tot <= 0 then raise exception 'The total must be more than 0'; end if;

  select * into inv from public.kt_invoices where order_id = o.id order by created_at desc limit 1;
  if inv.id is null then
    insert into public.kt_invoices (no, order_id, order_ref, customer, phone, items, total, due_date)
    values (public.kt_next_no('INV'), o.id, o.ref, o.customer, nullif(trim(coalesce(p->>'phone', '')), ''), clean, tot, nullif(p->>'due_date', '')::date)
    returning * into inv;
  else
    if tot < public.kt_paid(inv.id) then raise exception 'The new total is less than what is already paid'; end if;
    update public.kt_invoices set items = clean, total = tot, phone = nullif(trim(coalesce(p->>'phone', '')), ''),
      due_date = nullif(p->>'due_date', '')::date, customer = o.customer where id = inv.id returning * into inv;
    -- a bigger total can re-open "fully paid"
    if public.kt_paid(inv.id) < inv.total and o.paid_at is not null and o.delivered_at is null then
      update public.ws_orders set paid_at = null where id = o.id;
    end if;
  end if;
  return to_jsonb(inv);
end $$;

-- the invoice PDF was sent → the client's Order Room shows "pay to start" (no amounts there)
create or replace function public.kt_invoice_sent(p_invoice uuid) returns void
language plpgsql security definer set search_path = public as $$
declare inv public.kt_invoices;
begin
  perform public.ws_need_owner();
  update public.kt_invoices set sent_at = coalesce(sent_at, now()) where id = p_invoice returning * into inv;
  if inv.order_id is not null then perform public.ws_invoice_sent(inv.order_id); end if;
end $$;

-- ---------- owner: record a payment she has checked → receipt ----------
create or replace function public.kt_record_payment(p_invoice uuid, p_amount numeric, p_method text, p_reference text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare inv public.kt_invoices; o public.ws_orders; pay public.kt_payments; bal numeric; ref text := upper(trim(coalesce(p_reference, '')));
        first_pay boolean;
begin
  perform public.ws_need_owner();
  select * into inv from public.kt_invoices where id = p_invoice for update;
  if inv.id is null then raise exception 'Invoice not found'; end if;
  if p_amount is null or p_amount <= 0 then raise exception 'Type the amount received'; end if;
  bal := inv.total - public.kt_paid(inv.id);
  if bal <= 0 then raise exception 'This invoice is already fully paid'; end if;
  if round(p_amount, 2) > bal then raise exception 'That is more than the balance (KSh %)', to_char(bal, 'FM999,999,990.00'); end if;
  if p_method not in ('M-Pesa','Cash','Bank','Other') then raise exception 'Pick how it was paid'; end if;
  if p_method in ('M-Pesa','Bank') and length(ref) < 6 then raise exception 'Type the % code from the message', p_method; end if;
  if ref <> '' and exists (select 1 from public.kt_payments where upper(reference) = ref) then
    raise exception 'The code % is already on another receipt', ref;
  end if;
  first_pay := not exists (select 1 from public.kt_payments where invoice_id = inv.id);
  insert into public.kt_payments (no, invoice_id, amount, method, reference)
  values (public.kt_next_no('RCT'), inv.id, round(p_amount, 2), p_method, nullif(ref, ''))
  returning * into pay;
  bal := inv.total - public.kt_paid(inv.id);

  -- the order moves on by itself (workers only ever see "Deposit confirmed")
  if inv.order_id is not null then
    select * into o from public.ws_orders where id = inv.order_id;
    if o.invoice_at is null then update public.ws_orders set invoice_at = now() where id = o.id; end if;
    update public.ws_orders set dep_claimed_at = null, dep_code = null where id = o.id and dep_claimed_at is not null;
    if bal <= 0 then
      update public.ws_orders set bal_claimed_at = null, bal_code = null where id = o.id;
      perform public.ws_pay_ok(o.id, 'full');
    elsif o.dep_ok_at is null then
      perform public.ws_pay_ok(o.id, 'half');
    else
      update public.ws_orders set bal_claimed_at = null, bal_code = null where id = o.id;
      insert into public.ws_room_msgs (order_id, who, text) values (o.id, 'kartech', '✓ Payment received. Thank you! Your receipt is on WhatsApp.');
    end if;
  end if;
  return jsonb_build_object('payment', to_jsonb(pay), 'paid', public.kt_paid(inv.id), 'balance', bal, 'first', first_pay);
end $$;

create or replace function public.kt_receipt_sent(p_payment uuid) returns void
language plpgsql security definer set search_path = public as $$
begin
  perform public.ws_need_owner();
  update public.kt_payments set sent_at = coalesce(sent_at, now()) where id = p_payment;
end $$;

-- typed the wrong amount? remove the LAST receipt of an invoice (same day only)
create or replace function public.kt_cancel_payment(p_payment uuid) returns void
language plpgsql security definer set search_path = public as $$
declare pay public.kt_payments; inv public.kt_invoices; o public.ws_orders;
begin
  perform public.ws_need_owner();
  select * into pay from public.kt_payments where id = p_payment;
  if pay.id is null then return; end if;
  if exists (select 1 from public.kt_payments where invoice_id = pay.invoice_id and created_at > pay.created_at) then
    raise exception 'Only the latest receipt can be cancelled';
  end if;
  if (pay.created_at at time zone 'Africa/Nairobi')::date <> (now() at time zone 'Africa/Nairobi')::date then
    raise exception 'Only a receipt made today can be cancelled';
  end if;
  select * into inv from public.kt_invoices where id = pay.invoice_id;
  delete from public.kt_payments where id = pay.id;
  if inv.order_id is not null then
    select * into o from public.ws_orders where id = inv.order_id;
    if o.delivered_at is null then
      update public.ws_orders set paid_at = null where id = o.id;
      if not exists (select 1 from public.kt_payments where invoice_id = inv.id) then
        update public.ws_orders set dep_ok_at = null where id = o.id;
      end if;
    end if;
  end if;
  perform public.ws_note('warn', 'Receipt ' || pay.no || ' cancelled' || coalesce(' (' || inv.order_ref || ')', ''), inv.order_id);
end $$;

-- ---------- the QR on a PDF: anyone holding it can check it is genuine ----------
create or replace function public.kt_check(p_code text) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare inv public.kt_invoices; pay public.kt_payments;
begin
  select * into pay from public.kt_payments where check_code = lower(trim(p_code));
  if pay.id is not null then
    select * into inv from public.kt_invoices where id = pay.invoice_id;
    return jsonb_build_object('type', 'receipt', 'no', pay.no, 'at', pay.created_at, 'amount', pay.amount, 'method', pay.method,
      'customer', split_part(trim(inv.customer), ' ', 1), 'order', inv.order_ref, 'invoice', inv.no);
  end if;
  select * into inv from public.kt_invoices where check_code = lower(trim(p_code));
  if inv.id is not null then
    return jsonb_build_object('type', 'invoice', 'no', inv.no, 'at', inv.created_at, 'amount', inv.total,
      'customer', split_part(trim(inv.customer), ' ', 1), 'order', inv.order_ref);
  end if;
  return null;
end $$;

-- ---------- payment wording now that ANY payment starts the work ----------
create or replace function public.ws_pay_ok(p_order uuid, p_part text) returns void
language plpgsql security definer set search_path = public as $$
declare o public.ws_orders; was_held boolean;
begin
  perform public.ws_need_owner();
  select * into o from public.ws_orders where id = p_order for update;
  if o.id is null then raise exception 'Order not found'; end if;
  was_held := o.on_hold;
  if p_part = 'half' then
    if o.dep_ok_at is not null then return; end if;
    update public.ws_orders set dep_ok_at = now(), on_hold = false where id = o.id;
    insert into public.ws_room_msgs (order_id, who, text) values (o.id, 'kartech',
      case when was_held then '✓ Payment received. Thank you! Your order is now in the workshop.' else '✓ Payment received. Thank you!' end);
    perform public.ws_note('good', o.ref || ' · deposit confirmed' || case when was_held then ', the workshop can start' else '' end, o.id);
  elsif p_part = 'full' then
    if o.paid_at is not null then return; end if;
    update public.ws_orders set paid_at = now(), dep_ok_at = coalesce(dep_ok_at, now()), on_hold = false where id = o.id;
    insert into public.ws_room_msgs (order_id, who, text) values (o.id, 'kartech', '✓ Fully paid. Thank you! We will let you know the delivery day.');
    perform public.ws_note('good', o.ref || ' · fully paid' || case when was_held then ', the workshop can start' else '' end, o.id);
  else
    raise exception 'Unknown payment step';
  end if;
  if was_held then perform public.ws_release_all(); end if;
end $$;

-- the Order Room note when the invoice goes out (no amounts there)
create or replace function public.ws_invoice_sent(p_order uuid) returns void
language plpgsql security definer set search_path = public as $$
declare o public.ws_orders;
begin
  perform public.ws_need_owner();
  update public.ws_orders set invoice_at = coalesce(invoice_at, now()) where id = p_order returning * into o;
  if o.id is null then raise exception 'Order not found'; end if;
  if not exists (select 1 from public.ws_room_msgs where order_id = o.id and who = 'kartech' and text like '📄%') then
    insert into public.ws_room_msgs (order_id, who, text)
    values (o.id, 'kartech', '📄 We sent your invoice on WhatsApp. When you have paid, tap "I''ve paid" at the top of this page.');
  end if;
end $$;

-- the client's "I've paid" button: same as before, new words (any payment starts the work)
create or replace function public.ws_room_paid(p_code text, p_part text, p_txn text) returns void
language plpgsql security definer set search_path = public as $$
declare o public.ws_orders; c text := upper(regexp_replace(coalesce(p_txn, ''), '[^A-Za-z0-9]', '', 'g')); first text;
begin
  select * into o from public.ws_orders where room_code = lower(trim(p_code));
  if o.id is null then raise exception 'Order not found'; end if;
  if c !~ '^[A-Z0-9]{8,12}$' then raise exception 'Type the M-Pesa code from your SMS, e.g. SJK7XQ2M4P'; end if;
  if o.invoice_at is null then raise exception 'Kartech has not sent the invoice yet.'; end if;
  if (select count(*) from public.ws_room_msgs where order_id = o.id and who = 'customer' and text like '💳%' and at > now() - interval '1 hour') >= 6 then
    raise exception 'Please wait a little before trying again.';
  end if;
  first := split_part(trim(o.customer), ' ', 1);
  if p_part = 'half' then
    if o.dep_ok_at is not null then raise exception 'Your deposit is already confirmed.'; end if;
    update public.ws_orders set dep_code = c, dep_claimed_at = now() where id = o.id;
    insert into public.ws_room_msgs (order_id, who, text) values (o.id, 'customer', '💳 I''ve paid the deposit · M-Pesa code ' || c);
    perform public.ws_note('alert', first || ' says the deposit for ' || o.ref || ' is sent · M-Pesa code ' || c || '. Check it and confirm.', o.id);
  elsif p_part = 'full' then
    if o.paid_at is not null then raise exception 'Your order is already fully paid.'; end if;
    update public.ws_orders set bal_code = c, bal_claimed_at = now() where id = o.id;
    insert into public.ws_room_msgs (order_id, who, text) values (o.id, 'customer',
      case when o.dep_ok_at is null then '💳 I''ve paid it all · M-Pesa code ' else '💳 I''ve paid the balance · M-Pesa code ' end || c);
    perform public.ws_note('alert', first || ' says ' || case when o.dep_ok_at is null then 'the full payment' else 'the balance' end || ' for ' || o.ref || ' is sent · M-Pesa code ' || c || '. Check it and confirm.', o.id);
  else
    raise exception 'Unknown payment step';
  end if;
end $$;

-- ---------- who may use what ----------
revoke all on function public.kt_next_no(text), public.kt_paid(uuid) from public, anon, authenticated;
revoke all on function public.kt_business(), public.kt_set_business(text, text, text), public.kt_save_invoice(uuid, jsonb),
  public.kt_invoice_sent(uuid), public.kt_record_payment(uuid, numeric, text, text), public.kt_receipt_sent(uuid),
  public.kt_cancel_payment(uuid) from public, anon;
grant execute on function public.kt_business(), public.kt_set_business(text, text, text), public.kt_save_invoice(uuid, jsonb),
  public.kt_invoice_sent(uuid), public.kt_record_payment(uuid, numeric, text, text), public.kt_receipt_sent(uuid),
  public.kt_cancel_payment(uuid) to authenticated;
grant execute on function public.kt_check(text) to anon, authenticated;
grant select on public.kt_invoices, public.kt_payments to authenticated;


-- #####################################################################
-- ##  FILE: update-24-manager-done.sql
-- #####################################################################

-- =====================================================================
--  UPDATE 24: the manager can mark a worker's job done
--  (on the workshop screen: Manager → tap the worker → "Mark job done")
--  Paste ALL of this into Supabase → SQL Editor → New query → Run.
--  Safe to run again.
-- =====================================================================
create or replace function public.ws_foreman_done(p_pin text, p_worker uuid) returns text
language plpgsql security definer set search_path = public as $$
declare w public.ws_workers; t public.ws_tasks; o public.ws_orders; who text;
begin
  perform public.ws_foreman_ok(p_pin);
  select * into w from public.ws_workers where id = p_worker and active;
  if w.id is null then raise exception 'Worker not found'; end if;
  if w.task_id is null then raise exception '% has no job right now', w.name; end if;
  select * into t from public.ws_tasks where id = w.task_id for update;
  if t.id is null or t.status = 'done' then return 'done'; end if;
  select * into o from public.ws_orders where id = t.order_id;
  update public.ws_tasks set status = 'done', done_at = now(),
    worker_id = coalesce(worker_id, w.id),
    problem_reason = null, problem_stopped = null, problem_at = null, problem_ack_at = null where id = t.id;
  who := public.ws_task_names(t.id);
  update public.ws_workers set task_id = null, waiting_logged = false where task_id = t.id;
  perform public.ws_note('good', 'Manager marked ' || o.ref || ' · ' || public.ws_stage_name(t.stage) || ' done' || coalesce(' (' || who || ')', ''), o.id);
  perform public.ws_advance(o.id);
  if not exists (select 1 from public.ws_tasks where order_id = o.id and status <> 'done') then
    perform public.ws_note('good', o.ref || ' is finished. Ready for delivery.', o.id);
  end if;
  perform public.ws_release_all();
  perform public.ws_sync_source(o.source_order_id);
  return o.ref;
end $$;
revoke all on function public.ws_foreman_done(text, uuid) from public, anon;
grant execute on function public.ws_foreman_done(text, uuid) to authenticated;


-- #####################################################################
-- ##  FILE: update-25-lock-helpers.sql
-- #####################################################################

-- =====================================================================
--  UPDATE 25: close three small side doors (found by check-security.sql)
--  A few behind-the-scenes helper functions could be called by anyone on
--  the internet (not signed in). They only showed worker names for a
--  job id, so nothing serious, but strangers should not reach them.
--  This file closes every function to strangers EXCEPT the ones the
--  client pages need (Order Room, find my order, receipt check, website).
--  Paste ALL of this into Supabase → SQL Editor → New query → Run.
--  Safe to run again, and safe to run after any future update.
-- =====================================================================
do $$
declare f record;
  public_ok text[] := array['is_admin','kt_check','track_order','place_order','submit_custom_request',
                            'ws_find_rooms','ws_room','ws_room_add_photo','ws_room_approve',
                            'ws_room_message','ws_room_ok','ws_room_paid','touch_updated_at'];
begin
  for f in select p.oid::regprocedure as sig, p.proname
             from pg_proc p join pg_namespace n on n.oid = p.pronamespace
            where n.nspname = 'public' and (p.proname like 'ws\_%' or p.proname like 'kt\_%')
              and not (p.proname = any (public_ok))
              and has_function_privilege('anon', p.oid, 'execute') loop
    -- keep signed-in access exactly as it was, only shut out strangers
    if has_function_privilege('authenticated', f.sig::oid, 'execute') then
      execute format('grant execute on function %s to authenticated', f.sig);
    end if;
    execute format('revoke execute on function %s from public, anon', f.sig);
    raise notice 'closed to strangers: %', f.proname;
  end loop;
end $$;


-- #####################################################################
-- ##  FILE: update-26-shop-products.sql
-- #####################################################################

-- =====================================================================
--  UPDATE 26: the owner runs the website shop from her app
--  • A list of shop products (name, price, photos, category…) that the
--    owner adds and edits in the app (Stock → Shop products).
--  • The website shop reads this list, so a new product or photo shows
--    for customers straight away.
--  • A public photo folder "shop-photos": anyone can see the pictures
--    (they are on the website), only the owner can add or remove them.
--  Prices here are the public shop prices that customers see.
--  Paste ALL of this into Supabase → SQL Editor → New query → Run.
--  Safe to run again.
-- =====================================================================
create table if not exists public.kt_products (
  id          text primary key,
  name        text not null,
  price       numeric check (price is null or price >= 0),   -- empty = "Price on request"
  images      text[] not null default '{}',                    -- first one is the main photo
  tags        text[] not null default '{}',                    -- shop tabs: Furniture, Waiting seats, Catering equipment, Outdoor
  space       text,                                            -- small label under the name, e.g. "Bars & cafés"
  material    text,
  finishes    jsonb not null default '[]',                      -- colour choices: [{"name":"Black","color":"#2b2820"}]
  availability text,
  about       text, dimensions text, materials text, care text, delivery text,
  sort        int not null default 0,                          -- smaller shows first
  active      boolean not null default true,                    -- false = hidden from the website
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);
alter table public.kt_products enable row level security;
drop policy if exists "shop products visible" on public.kt_products;
create policy "shop products visible" on public.kt_products for select to anon, authenticated
  using (active or public.is_admin());
grant select on public.kt_products to anon, authenticated;
revoke insert, update, delete on public.kt_products from anon, authenticated;

-- add or change a product (owner only). p = {id?, name, price, images[], tags[], space, material, about, availability, active, …}
create or replace function public.kt_save_product(p jsonb) returns text
language plpgsql security definer set search_path = public as $$
declare v_id text := nullif(trim(coalesce(p->>'id', '')), ''); v_name text := left(trim(coalesce(p->>'name', '')), 120);
        v_price numeric; base text; n int := 1;
begin
  perform public.ws_need_owner();
  if v_name = '' then raise exception 'Give the product a name'; end if;
  if nullif(trim(coalesce(p->>'price', '')), '') is not null then
    begin v_price := (p->>'price')::numeric; exception when others then raise exception 'The price must be a number'; end;
    if v_price < 0 then raise exception 'The price cannot be below 0'; end if;
  end if;
  if jsonb_array_length(coalesce(p->'images', '[]')) > 8 then raise exception 'Up to 8 photos per product'; end if;
  if v_id is null or not exists (select 1 from public.kt_products where id = v_id) then
    if v_id is null then
      base := trim(both '-' from regexp_replace(lower(v_name), '[^a-z0-9]+', '-', 'g'));
      if base = '' then base := 'product'; end if;
      v_id := base;
      while exists (select 1 from public.kt_products where id = v_id) loop n := n + 1; v_id := base || '-' || n; end loop;
    end if;
    insert into public.kt_products (id, name, sort) values (v_id, v_name, coalesce((select min(sort) from public.kt_products), 0) - 1);
  end if;
  update public.kt_products set
    name = v_name, price = v_price,
    images = coalesce((select array_agg(x) from jsonb_array_elements_text(coalesce(p->'images', '[]')) x where trim(x) <> ''), '{}'),
    tags = coalesce((select array_agg(x) from jsonb_array_elements_text(coalesce(p->'tags', '[]')) x where trim(x) <> ''), '{}'),
    space = nullif(left(trim(coalesce(p->>'space', '')), 80), ''),
    material = nullif(left(trim(coalesce(p->>'material', '')), 160), ''),
    finishes = case when p ? 'finishes' then coalesce(p->'finishes', '[]') else finishes end,
    availability = nullif(left(trim(coalesce(p->>'availability', '')), 60), ''),
    about = nullif(left(trim(coalesce(p->>'about', '')), 1500), ''),
    dimensions = case when p ? 'dimensions' then nullif(left(trim(p->>'dimensions'), 400), '') else dimensions end,
    materials = case when p ? 'materials' then nullif(left(trim(p->>'materials'), 400), '') else materials end,
    care = case when p ? 'care' then nullif(left(trim(p->>'care'), 400), '') else care end,
    delivery = case when p ? 'delivery' then nullif(left(trim(p->>'delivery'), 400), '') else delivery end,
    active = coalesce((p->>'active')::boolean, active),
    updated_at = now()
  where id = v_id;
  return v_id;
end $$;

-- delete a product for good (owner only). Returns its uploaded photo paths so the app can tidy the photo folder.
create or replace function public.kt_delete_product(p_id text) returns text[]
language plpgsql security definer set search_path = public as $$
declare imgs text[];
begin
  perform public.ws_need_owner();
  delete from public.kt_products where id = p_id returning images into imgs;
  return coalesce(imgs, '{}');
end $$;

-- move a product to the top or bottom of the shop (owner only)
create or replace function public.kt_move_product(p_id text, p_to text) returns void
language plpgsql security definer set search_path = public as $$
begin
  perform public.ws_need_owner();
  update public.kt_products set sort = case when p_to = 'bottom' then coalesce((select max(sort) from public.kt_products), 0) + 1
                                             else coalesce((select min(sort) from public.kt_products), 0) - 1 end,
         updated_at = now() where id = p_id;
end $$;

revoke all on function public.kt_save_product(jsonb), public.kt_delete_product(text), public.kt_move_product(text, text) from public, anon;
grant execute on function public.kt_save_product(jsonb), public.kt_delete_product(text), public.kt_move_product(text, text) to authenticated;

-- the public photo folder for shop products
do $do$
begin
  if exists (select 1 from information_schema.schemata where schema_name = 'storage') then
    insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
    values ('shop-photos', 'shop-photos', true, 10485760, array['image/jpeg','image/png','image/webp'])
    on conflict (id) do update set public = true, file_size_limit = excluded.file_size_limit, allowed_mime_types = excluded.allowed_mime_types;
    drop policy if exists "shop photos owner add"    on storage.objects;
    drop policy if exists "shop photos owner remove" on storage.objects;
    create policy "shop photos owner add" on storage.objects for insert to authenticated
      with check (bucket_id = 'shop-photos' and public.is_admin());
    create policy "shop photos owner remove" on storage.objects for delete to authenticated
      using (bucket_id = 'shop-photos' and public.is_admin());
  end if;
end $do$;

-- the products already on the website (added once; the owner edits them from now on)
insert into public.kt_products (id,name,price,images,tags,space,material,finishes,availability,about,dimensions,materials,care,delivery,sort) values
('tube-arm-chair-brown','Tube-Arm Dining Chair',null,array['photos/tube-arm-chair-brown.jpg']::text[],array['Furniture']::text[],'Restaurants & cafés','Bent steel tube frame · brown leatherette','[]'::jsonb,'In stock','Made in the Kartech workshop. Ask us about colours, quantities and custom sizes.','Ask us for the exact sizes.','Bent steel tube frame · brown leatherette.','Wipe with a damp cloth. Avoid harsh chemicals on the seat.','Delivery across Kenya. Cost and timing confirmed with your order.',0),
('visitor-armchair-blue','Padded Visitor Armchair',null,array['photos/visitor-armchair-blue.jpg']::text[],array['Waiting seats']::text[],'Offices & waiting areas','Steel frame · blue fabric','[]'::jsonb,'In stock','Made in the Kartech workshop. Ask us about colours, quantities and custom sizes.','Ask us for the exact sizes.','Steel frame · blue fabric.','Wipe with a damp cloth. Avoid harsh chemicals on the seat.','Delivery across Kenya. Cost and timing confirmed with your order.',1),
('cross-back-cafe-chair','Cross-Back Café Chair',null,array['photos/cross-back-cafe-chair.jpg']::text[],array['Furniture']::text[],'Restaurants & cafés','Bronze-finish steel · padded round seat','[]'::jsonb,'In stock','Made in the Kartech workshop. Ask us about colours, quantities and custom sizes.','Ask us for the exact sizes.','Bronze-finish steel · padded round seat.','Wipe with a damp cloth. Avoid harsh chemicals on the seat.','Delivery across Kenya. Cost and timing confirmed with your order.',2),
('studded-dining-chair-tan','Studded-Frame Dining Chair',null,array['photos/studded-dining-chair-tan.jpg']::text[],array['Furniture']::text[],'Restaurants & hotels','Hammered-finish steel · tan leatherette','[]'::jsonb,'In stock','Made in the Kartech workshop. Ask us about colours, quantities and custom sizes.','Ask us for the exact sizes.','Hammered-finish steel · tan leatherette.','Wipe with a damp cloth. Avoid harsh chemicals on the seat.','Delivery across Kenya. Cost and timing confirmed with your order.',3),
('two-tone-high-back-chair','Two-Tone High-Back Chair',null,array['photos/two-tone-high-back-chair.jpg']::text[],array['Furniture']::text[],'Restaurants & bars','Steel frame · two-colour leatherette','[]'::jsonb,'In stock','Made in the Kartech workshop. Ask us about colours, quantities and custom sizes.','Ask us for the exact sizes.','Steel frame · two-colour leatherette.','Wipe with a damp cloth. Avoid harsh chemicals on the seat.','Delivery across Kenya. Cost and timing confirmed with your order.',4),
('round-back-cafe-chair','Round-Back Café Chair',null,array['photos/round-back-cafe-chair.jpg']::text[],array['Furniture']::text[],'Restaurants & cafés','Bronze-finish steel · brown leatherette','[]'::jsonb,'In stock','Made in the Kartech workshop. Ask us about colours, quantities and custom sizes.','Ask us for the exact sizes.','Bronze-finish steel · brown leatherette.','Wipe with a damp cloth. Avoid harsh chemicals on the seat.','Delivery across Kenya. Cost and timing confirmed with your order.',5),
('rope-bar-chair-zebra','Rope-Back Bar Chair, Zebra Seat',null,array['photos/rope-bar-chair-zebra.jpg']::text[],array['Furniture']::text[],'Bars & lounges','Steel frame · woven rope · zebra-print seat','[]'::jsonb,'In stock','Made in the Kartech workshop. Ask us about colours, quantities and custom sizes.','Ask us for the exact sizes.','Steel frame · woven rope · zebra-print seat.','Wipe with a damp cloth. Avoid harsh chemicals on the seat.','Delivery across Kenya. Cost and timing confirmed with your order.',6),
('rope-lounge-zebra-cushions','Rope Lounge Chair with Zebra Cushions',null,array['photos/rope-lounge-zebra-cushions.jpg']::text[],array['Outdoor']::text[],'Lounges & terraces','Steel frame · woven rope · zebra-print cushions','[]'::jsonb,'In stock','Made in the Kartech workshop. Ask us about colours, quantities and custom sizes.','Ask us for the exact sizes.','Steel frame · woven rope · zebra-print cushions.','Wipe with a damp cloth. Avoid harsh chemicals on the seat.','Delivery across Kenya. Cost and timing confirmed with your order.',7),
('rope-back-bar-stool','Rope-Back Bar Stool',null,array['photos/rope-back-bar-stool.jpg']::text[],array['Furniture']::text[],'Bars & cafés','Hammered-finish steel · rope back · leatherette seat','[]'::jsonb,'In stock','Made in the Kartech workshop. Ask us about colours, quantities and custom sizes.','Ask us for the exact sizes.','Hammered-finish steel · rope back · leatherette seat.','Wipe with a damp cloth. Avoid harsh chemicals on the seat.','Delivery across Kenya. Cost and timing confirmed with your order.',8),
('red-bar-stool','Round-Seat Bar Stool, Red',null,array['photos/red-bar-stool.jpg']::text[],array['Furniture']::text[],'Bars & cafés','Hammered-finish steel · red leatherette','[]'::jsonb,'In stock','Made in the Kartech workshop. Ask us about colours, quantities and custom sizes.','Ask us for the exact sizes.','Hammered-finish steel · red leatherette.','Wipe with a damp cloth. Avoid harsh chemicals on the seat.','Delivery across Kenya. Cost and timing confirmed with your order.',9),
('classic-dining-chair-cream','Classic Dining Chair, Cream',null,array['photos/classic-dining-chair-cream.jpg']::text[],array['Furniture']::text[],'Restaurants & hotels','Hammered-finish steel · cream leatherette','[]'::jsonb,'In stock','Made in the Kartech workshop. Ask us about colours, quantities and custom sizes.','Ask us for the exact sizes.','Hammered-finish steel · cream leatherette.','Wipe with a damp cloth. Avoid harsh chemicals on the seat.','Delivery across Kenya. Cost and timing confirmed with your order.',10),
('padded-dining-chair-black','Padded Dining Chair, Black',null,array['photos/padded-dining-chair-black.jpg']::text[],array['Furniture']::text[],'Restaurants & cafés','Silver-finish steel · black leatherette','[]'::jsonb,'In stock','Made in the Kartech workshop. Ask us about colours, quantities and custom sizes.','Ask us for the exact sizes.','Silver-finish steel · black leatherette.','Wipe with a damp cloth. Avoid harsh chemicals on the seat.','Delivery across Kenya. Cost and timing confirmed with your order.',11),
('laser-cut-armchair','Laser-Cut Back Armchair',null,array['photos/laser-cut-armchair.jpg']::text[],array['Furniture']::text[],'Restaurants & terraces','Cut-steel back · padded seat','[]'::jsonb,'In stock','Made in the Kartech workshop. Ask us about colours, quantities and custom sizes.','Ask us for the exact sizes.','Cut-steel back · padded seat.','Wipe with a damp cloth. Avoid harsh chemicals on the seat.','Delivery across Kenya. Cost and timing confirmed with your order.',12),
('rope-lounge-armchair-beige','Rope Lounge Armchair, Beige',null,array['photos/rope-lounge-armchair-beige.jpg']::text[],array['Outdoor']::text[],'Lounges & terraces','Steel frame · woven rope · beige cushions','[]'::jsonb,'In stock','Made in the Kartech workshop. Ask us about colours, quantities and custom sizes.','Ask us for the exact sizes.','Steel frame · woven rope · beige cushions.','Wipe with a damp cloth. Avoid harsh chemicals on the seat.','Delivery across Kenya. Cost and timing confirmed with your order.',13),
('curved-arm-chair-tan','Curved-Arm Lounge Chair, Tan',null,array['photos/curved-arm-chair-tan.jpg']::text[],array['Furniture']::text[],'Lounges & offices','Steel frame · tan leatherette','[]'::jsonb,'In stock','Made in the Kartech workshop. Ask us about colours, quantities and custom sizes.','Ask us for the exact sizes.','Steel frame · tan leatherette.','Wipe with a damp cloth. Avoid harsh chemicals on the seat.','Delivery across Kenya. Cost and timing confirmed with your order.',14),
('striped-high-back-chair','Striped High-Back Chair',null,array['photos/striped-high-back-chair.jpg']::text[],array['Furniture']::text[],'Restaurants & bars','Steel frame · red and white leatherette','[]'::jsonb,'In stock','Made in the Kartech workshop. Ask us about colours, quantities and custom sizes.','Ask us for the exact sizes.','Steel frame · red and white leatherette.','Wipe with a damp cloth. Avoid harsh chemicals on the seat.','Delivery across Kenya. Cost and timing confirmed with your order.',15),
('branded-church-chair','Church Chair with Printed Logo',null,array['photos/branded-church-chair.jpg','photos/branded-church-chair-2.jpg']::text[],array['Waiting seats']::text[],'Churches & halls','Steel frame · fabric · your logo printed on the back','[]'::jsonb,'In stock','Made in the Kartech workshop. Ask us about colours, quantities and custom sizes.','Ask us for the exact sizes.','Steel frame · fabric · your logo printed on the back.','Wipe with a damp cloth. Avoid harsh chemicals on the seat.','Delivery across Kenya. Cost and timing confirmed with your order.',16),
('grey-dining-chair','Grey Dining Chair',null,array['photos/grey-dining-chair.jpg']::text[],array['Furniture']::text[],'Restaurants & canteens','Steel frame · grey leatherette','[]'::jsonb,'In stock','Made in the Kartech workshop. Ask us about colours, quantities and custom sizes.','Ask us for the exact sizes.','Steel frame · grey leatherette.','Wipe with a damp cloth. Avoid harsh chemicals on the seat.','Delivery across Kenya. Cost and timing confirmed with your order.',17),
('high-back-bar-chair-rust','High-Back Bar Chair, Rust',null,array['photos/high-back-bar-chair-rust.jpg']::text[],array['Furniture']::text[],'Bars & lounges','Steel frame · rust leatherette','[]'::jsonb,'In stock','Made in the Kartech workshop. Ask us about colours, quantities and custom sizes.','Ask us for the exact sizes.','Steel frame · rust leatherette.','Wipe with a damp cloth. Avoid harsh chemicals on the seat.','Delivery across Kenya. Cost and timing confirmed with your order.',18),
('banquet-chair-gold','Banquet Chair, Gold Frame',null,array['photos/banquet-chair-gold.jpg']::text[],array['Furniture']::text[],'Weddings, events & halls','Gold-finish steel · patterned fabric','[]'::jsonb,'In stock','Made in the Kartech workshop. Ask us about colours, quantities and custom sizes.','Ask us for the exact sizes.','Gold-finish steel · patterned fabric.','Wipe with a damp cloth. Avoid harsh chemicals on the seat.','Delivery across Kenya. Cost and timing confirmed with your order.',19),
('rope-armchair-brown','Rope Armchair, Brown Seat',null,array['photos/rope-armchair-brown.jpg']::text[],array['Outdoor']::text[],'Restaurants & terraces','Hammered-finish steel · woven rope · brown leatherette','[]'::jsonb,'In stock','Made in the Kartech workshop. Ask us about colours, quantities and custom sizes.','Ask us for the exact sizes.','Hammered-finish steel · woven rope · brown leatherette.','Wipe with a damp cloth. Avoid harsh chemicals on the seat.','Delivery across Kenya. Cost and timing confirmed with your order.',20),
('oval-back-cafe-chair-cream','Oval-Back Café Chair, Cream',null,array['photos/oval-back-cafe-chair-cream.jpg']::text[],array['Furniture']::text[],'Restaurants & cafés','Bronze-finish steel · cream leatherette','[]'::jsonb,'In stock','Made in the Kartech workshop. Ask us about colours, quantities and custom sizes.','Ask us for the exact sizes.','Bronze-finish steel · cream leatherette.','Wipe with a damp cloth. Avoid harsh chemicals on the seat.','Delivery across Kenya. Cost and timing confirmed with your order.',21),
('dining-set','Restaurant Dining Set',null,array[]::text[],array['Furniture']::text[],'Restaurants','Steel frame · [top material — to confirm]','[{"name":"Black","color":"#2b2820"},{"name":"Grey","color":"#8B8D89"},{"name":"White","color":"#EDEBE6"},{"name":"Green","color":"#3F5A3D"}]'::jsonb,null,'A table with matching chairs for restaurants and cafés. Ordered in the quantity your space needs. [Real description — to confirm]','[Table and chair sizes — to confirm]','[Frame, top and seat details — to confirm]','[Care instructions — to confirm with Kartech]','Delivery across Kenya. Cost and timing confirmed with your order.',22),
('bar-stool','Bar Stool',null,array[]::text[],array['Furniture']::text[],'Bars & cafés','Steel frame · [seat — to confirm]','[{"name":"Black","color":"#2b2820"},{"name":"Grey","color":"#8B8D89"},{"name":"White","color":"#EDEBE6"},{"name":"Green","color":"#3F5A3D"}]'::jsonb,null,'A high stool for bar counters and high tables. [Real description — to confirm]','[Seat height — to confirm]','[Frame and seat details — to confirm]','[Care instructions — to confirm with Kartech]','Delivery across Kenya. Cost and timing confirmed with your order.',23),
('high-table-set','High Table Set',null,array[]::text[],array['Furniture']::text[],'Bars & cafés','Steel frame · [top — to confirm]','[{"name":"Black","color":"#2b2820"},{"name":"Grey","color":"#8B8D89"},{"name":"White","color":"#EDEBE6"},{"name":"Green","color":"#3F5A3D"}]'::jsonb,null,'A high table with matching bar stools. [Real description — to confirm]','[Table height and top size — to confirm]','[Frame and top details — to confirm]','[Care instructions — to confirm with Kartech]','Delivery across Kenya. Cost and timing confirmed with your order.',24),
('church-chair','Church Chair',null,array[]::text[],array['Furniture']::text[],'Churches & halls','Steel frame · padded seat','[{"name":"Black","color":"#2b2820"},{"name":"Grey","color":"#8B8D89"},{"name":"Blue","color":"#2F4A7A"},{"name":"Red","color":"#8E2A22"}]'::jsonb,null,'Seating for churches, halls and events, made in large quantities. [Real description — to confirm]','[Seat size — to confirm]','[Frame, foam and fabric — to confirm]','[Care instructions — to confirm with Kartech]','Delivery across Kenya. Cost and timing confirmed with your order.',25),
('school-desk','School Desk and Chair',null,array[]::text[],array['Furniture']::text[],'Schools','Steel frame · [top — to confirm]','[{"name":"Black","color":"#2b2820"},{"name":"Grey","color":"#8B8D89"},{"name":"White","color":"#EDEBE6"},{"name":"Green","color":"#3F5A3D"}]'::jsonb,null,'Strong desks and chairs for classrooms. [Real description — to confirm]','[Sizes by age — to confirm]','[Frame and top details — to confirm]','[Care instructions — to confirm with Kartech]','Delivery across Kenya. Cost and timing confirmed with your order.',26),
('outdoor-lounge-set','Outdoor Lounge Set',null,array[]::text[],array['Furniture','Outdoor']::text[],'Outdoor','Steel frame · outdoor cushions','[{"name":"Black","color":"#2b2820"},{"name":"Grey","color":"#8B8D89"},{"name":"White","color":"#EDEBE6"},{"name":"Green","color":"#3F5A3D"}]'::jsonb,null,'Sofas and a table for terraces, gardens and hotels. [Real description — to confirm]','[Sizes — to confirm]','[Frame and cushion details — to confirm]','[Care instructions — to confirm with Kartech]','Delivery across Kenya. Cost and timing confirmed with your order.',27),
('waiting-bench-3','3-Seater Waiting Bench',null,array[]::text[],array['Waiting seats']::text[],'Hospitals, banks & offices','Steel beam · [seat type — to confirm]','[{"name":"Black","color":"#2b2820"},{"name":"Grey","color":"#8B8D89"},{"name":"Blue","color":"#2F4A7A"},{"name":"Red","color":"#8E2A22"}]'::jsonb,null,'Linked metal seating for reception and waiting areas. [Real description — to confirm]','[Length and seat height — to confirm]','[Beam, legs and seats — to confirm]','[Care instructions — to confirm with Kartech]','Delivery across Kenya. Cost and timing confirmed with your order.',28),
('waiting-bench-4','4-Seater Waiting Bench',null,array[]::text[],array['Waiting seats']::text[],'Hospitals, banks & offices','Steel beam · [seat type — to confirm]','[{"name":"Black","color":"#2b2820"},{"name":"Grey","color":"#8B8D89"},{"name":"Blue","color":"#2F4A7A"},{"name":"Red","color":"#8E2A22"}]'::jsonb,null,'Linked metal seating for reception and waiting areas. [Real description — to confirm]','[Length and seat height — to confirm]','[Beam, legs and seats — to confirm]','[Care instructions — to confirm with Kartech]','Delivery across Kenya. Cost and timing confirmed with your order.',29),
('waiting-bench-5','5-Seater Waiting Bench',null,array[]::text[],array['Waiting seats']::text[],'Hospitals, banks & offices','Steel beam · [seat type — to confirm]','[{"name":"Black","color":"#2b2820"},{"name":"Grey","color":"#8B8D89"},{"name":"Blue","color":"#2F4A7A"},{"name":"Red","color":"#8E2A22"}]'::jsonb,null,'Linked metal seating for larger waiting halls. [Real description — to confirm]','[Length and seat height — to confirm]','[Beam, legs and seats — to confirm]','[Care instructions — to confirm with Kartech]','Delivery across Kenya. Cost and timing confirmed with your order.',30),
('gas-cooker-2','Two-Burner Gas Cooker',null,array[]::text[],array['Catering equipment']::text[],'Commercial kitchens','Stainless steel','[{"name":"Stainless steel","color":"#C9CBC8"}]'::jsonb,null,'A high-pressure gas cooker for restaurant, hotel and school kitchens. [Real description — to confirm]','[Width × depth × height — to confirm]','[Steel grade and burner type — to confirm]','[Care instructions — to confirm with Kartech]','Delivery across Kenya. Cost and timing confirmed with your order.',31),
('gas-cooker-3','Three-Burner Gas Cooker',null,array[]::text[],array['Catering equipment']::text[],'Commercial kitchens','Stainless steel','[{"name":"Stainless steel","color":"#C9CBC8"}]'::jsonb,null,'A larger high-pressure gas cooker for busy kitchens. [Real description — to confirm]','[Width × depth × height — to confirm]','[Steel grade and burner type — to confirm]','[Care instructions — to confirm with Kartech]','Delivery across Kenya. Cost and timing confirmed with your order.',32),
('cooker-griddle','Gas Cooker with Griddle',null,array[]::text[],array['Catering equipment']::text[],'Commercial kitchens','Stainless steel','[{"name":"Stainless steel","color":"#C9CBC8"}]'::jsonb,null,'Burners and a flat griddle in one unit. [Real description — to confirm]','[Width × depth × height — to confirm]','[Steel grade and burner type — to confirm]','[Care instructions — to confirm with Kartech]','Delivery across Kenya. Cost and timing confirmed with your order.',33),
('stockpot-burner','Single Stock Pot Burner',null,array[]::text[],array['Catering equipment']::text[],'Commercial kitchens','Stainless steel','[{"name":"Stainless steel","color":"#C9CBC8"}]'::jsonb,null,'A low, heavy burner for large cooking pots. [Real description — to confirm]','[Width × depth × height — to confirm]','[Steel grade and burner type — to confirm]','[Care instructions — to confirm with Kartech]','Delivery across Kenya. Cost and timing confirmed with your order.',34)
on conflict (id) do nothing;
