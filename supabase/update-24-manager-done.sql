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
