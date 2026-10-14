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
