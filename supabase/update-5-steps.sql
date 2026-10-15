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
