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
