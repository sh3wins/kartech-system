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
