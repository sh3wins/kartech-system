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
