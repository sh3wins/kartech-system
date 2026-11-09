-- =====================================================================
--  UPDATE 22: simple assigning — the owner can mark a step done
--  Paste ALL of this into Supabase → SQL Editor → New query → Run.
--  Safe to run again.
-- =====================================================================
create or replace function public.ws_owner_done(p_task uuid) returns void
language plpgsql security definer set search_path = public as $$
declare t public.ws_tasks; o public.ws_orders; who text;
begin
  perform public.ws_need_owner();
  select * into t from public.ws_tasks where id = p_task for update;
  if t.id is null then raise exception 'Step not found'; end if;
  if t.status = 'done' then return; end if;
  select * into o from public.ws_orders where id = t.order_id;
  who := case when t.worker_id is not null then public.ws_task_names(t.id) end;
  update public.ws_tasks set status = 'done', done_at = now(),
    problem_reason = null, problem_stopped = null, problem_at = null, problem_ack_at = null where id = t.id;
  update public.ws_workers set task_id = null, waiting_logged = false where task_id = t.id;
  perform public.ws_note('good', 'Owner marked ' || o.ref || ' · ' || public.ws_stage_name(t.stage) || ' done' || coalesce(' (' || who || ')', ''), o.id);
  perform public.ws_advance(o.id);
  if not exists (select 1 from public.ws_tasks where order_id = o.id and status <> 'done') then
    perform public.ws_note('good', o.ref || ' is finished. Ready for delivery.', o.id);
  end if;
  perform public.ws_release_all();
  perform public.ws_sync_source(o.source_order_id);
end $$;
revoke all on function public.ws_owner_done(uuid) from public, anon;
grant execute on function public.ws_owner_done(uuid) to authenticated;
