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
