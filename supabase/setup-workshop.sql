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
