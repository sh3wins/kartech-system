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
