-- =====================================================================
--  KARTECH UPDATE 8: History (owner app → History)
--  Paste ALL of this into Supabase → SQL Editor → New query → Run.
--  Safe to run again. Run update-7-checkin.sql first.
--
--  • Keeps a record of who came in each day (and what time), who was away.
--  • One function gives the owner everything that happened on any day:
--    who came, jobs finished, tools taken/returned, materials given, alarms.
-- =====================================================================

-- ---------- attendance book: one line per worker per day ----------
create table if not exists public.ws_attendance (
  day        date not null,
  worker_id  uuid not null references public.ws_workers(id) on delete cascade,
  arrived_at timestamptz,
  away       boolean not null default false,
  primary key (day, worker_id)
);
alter table public.ws_attendance enable row level security;
drop policy if exists "owner reads attendance" on public.ws_attendance;
create policy "owner reads attendance" on public.ws_attendance for select to authenticated using (public.is_admin());
grant select on public.ws_attendance to authenticated;

-- writes itself every time a worker is ticked in / unticked / marked away
create or replace function public.ws_attendance_track() returns trigger
language plpgsql security definer set search_path = public as $$
declare d date := public.ws_today();
begin
  if new.away_on = d then
    insert into public.ws_attendance (day, worker_id, arrived_at, away) values (d, new.id, null, true)
      on conflict (day, worker_id) do update set away = true, arrived_at = null;
  elsif new.arrived_on = d then
    insert into public.ws_attendance (day, worker_id, arrived_at, away) values (d, new.id, coalesce(new.arrived_at, now()), false)
      on conflict (day, worker_id) do update set away = false, arrived_at = coalesce(public.ws_attendance.arrived_at, excluded.arrived_at);
  elsif (old.arrived_on = d or old.away_on = d) then
    delete from public.ws_attendance where day = d and worker_id = new.id;   -- undo / ticked by mistake
  end if;
  return new;
end $$;

drop trigger if exists ws_attendance_track on public.ws_workers;
create trigger ws_attendance_track after update of arrived_on, arrived_at, away_on on public.ws_workers
  for each row execute function public.ws_attendance_track();

-- today so far
insert into public.ws_attendance (day, worker_id, arrived_at, away)
select public.ws_today(), id, case when away_on = public.ws_today() then null else arrived_at end, coalesce(away_on = public.ws_today(), false)
  from public.ws_workers where arrived_on = public.ws_today() or away_on = public.ws_today()
on conflict (day, worker_id) do nothing;


-- ---------- everything that happened on one day ----------
create or replace function public.ws_history(p_day date) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare a timestamptz := (p_day::timestamp at time zone 'Africa/Nairobi');
        b timestamptz := ((p_day + 1)::timestamp at time zone 'Africa/Nairobi');
begin
  perform public.ws_need_owner();
  return jsonb_build_object(
    'day', p_day,
    'attendance', coalesce((select jsonb_agg(jsonb_build_object('worker', x.worker_id, 'at', x.arrived_at, 'away', x.away))
        from public.ws_attendance x where x.day = p_day), '[]'::jsonb),
    'jobs', coalesce((select jsonb_agg(jsonb_build_object('worker', t.worker_id, 'stage', t.stage, 'ref', o.ref, 'item', o.item, 'qty', o.qty,
                'started', t.started_at, 'done', t.done_at) order by t.done_at)
        from public.ws_tasks t join public.ws_orders o on o.id = t.order_id
       where t.status = 'done' and t.done_at >= a and t.done_at < b), '[]'::jsonb),
    'tools', coalesce((select jsonb_agg(jsonb_build_object('tool', tl.name, 'worker', l.worker_id, 'out', l.out_at, 'back', l.back_at) order by l.out_at)
        from public.ws_tool_loans l join public.ws_tools tl on tl.id = l.tool_id
       where (l.out_at >= a and l.out_at < b) or (l.back_at >= a and l.back_at < b)
          or (l.out_at < a and (l.back_at is null or l.back_at >= b) and p_day <= public.ws_today())), '[]'::jsonb),
    'missing', coalesce((select jsonb_agg(jsonb_build_object('tool', tl.name, 'worker', m.worker_id, 'found', m.found_at))
        from public.ws_tool_missing m join public.ws_tools tl on tl.id = m.tool_id where m.since = p_day), '[]'::jsonb),
    'check', (select jsonb_build_object('at', c.done_at, 'missing', c.missing) from public.ws_tool_checks c where c.day = p_day),
    'materials', coalesce((select jsonb_agg(jsonb_build_object('at', mv.at, 'kind', mv.kind, 'qty', mv.qty, 'material', mt.name, 'unit', mt.unit,
                'worker', mv.worker_id, 'note', mv.note) order by mv.at)
        from public.ws_moves mv join public.ws_materials mt on mt.id = mv.material_id
       where mv.at >= a and mv.at < b), '[]'::jsonb),
    'log', coalesce((select jsonb_agg(jsonb_build_object('at', g.at, 'kind', g.kind, 'text', g.text) order by g.id)
        from public.ws_log g where g.at >= a and g.at < b), '[]'::jsonb)
  );
end $$;

revoke all on function public.ws_history(date) from public, anon;
grant execute on function public.ws_history(date) to authenticated;
