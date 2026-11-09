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
