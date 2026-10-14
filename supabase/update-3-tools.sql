-- =====================================================================
--  KARTECH UPDATE 3: tools (grinders, welders, drills…) evening check
--  Paste ALL of this into Supabase → SQL Editor → New query → Run.
--  Safe to run again. Run update-1 and update-2 first.
--
--  How it works:
--   • The owner lists each tool once, with who normally uses it.
--   • Nothing is recorded in the morning.
--   • At closing time the foreman opens "Tool check" on the workshop screen.
--     Everything is ticked as back; he taps only what is missing → Done.
--   • Missing tools go to the owner's phone as an alert, with who normally uses it.
--     They stay on her list until the tool is back.
-- =====================================================================

create table if not exists public.ws_tools (
  id           uuid primary key default gen_random_uuid(),
  name         text not null,
  usual_worker uuid references public.ws_workers(id) on delete set null,
  active       boolean not null default true,
  created_at   timestamptz not null default now()
);

create table if not exists public.ws_tool_checks (
  day        date primary key,                -- one check per day (Nairobi date)
  done_at    timestamptz not null default now(),
  missing    int not null default 0
);

create table if not exists public.ws_tool_missing (
  id        bigserial primary key,
  tool_id   uuid not null references public.ws_tools(id) on delete cascade,
  worker_id uuid references public.ws_workers(id) on delete set null,   -- who normally uses it (on that day)
  since     date not null,
  found_at  timestamptz
);
create index if not exists ws_tool_missing_open on public.ws_tool_missing (tool_id) where found_at is null;

alter table public.ws_tools        enable row level security;
alter table public.ws_tool_checks  enable row level security;
alter table public.ws_tool_missing enable row level security;
drop policy if exists "owner reads tools"   on public.ws_tools;
drop policy if exists "owner reads checks"  on public.ws_tool_checks;
drop policy if exists "owner reads missing" on public.ws_tool_missing;
create policy "owner reads tools"   on public.ws_tools        for select to authenticated using (public.is_admin());
create policy "owner reads checks"  on public.ws_tool_checks  for select to authenticated using (public.is_admin());
create policy "owner reads missing" on public.ws_tool_missing for select to authenticated using (public.is_admin());
revoke all on public.ws_tools, public.ws_tool_checks, public.ws_tool_missing from anon, authenticated;
grant select on public.ws_tools, public.ws_tool_checks, public.ws_tool_missing to authenticated;

create or replace function public.ws_today() returns date
language sql stable as $$ select (now() at time zone 'Africa/Nairobi')::date; $$;


-- ---------- owner ----------
create or replace function public.ws_save_tool(p jsonb) returns void
language plpgsql security definer set search_path = public as $$
declare v_name text := left(trim(coalesce(p->>'name','')), 60);
begin
  perform public.ws_need_owner();
  if length(v_name) = 0 then raise exception 'Add a name, e.g. Grinder 1'; end if;
  if p->>'id' is null then
    insert into public.ws_tools (name, usual_worker) values (v_name, nullif(p->>'usual_worker','')::uuid);
    perform public.ws_note('info', 'New tool added: ' || v_name);
  else
    update public.ws_tools set name = v_name, usual_worker = nullif(p->>'usual_worker','')::uuid,
      active = coalesce((p->>'active')::boolean, active)
     where id = (p->>'id')::uuid;
  end if;
end $$;

-- owner marks a missing tool as found
create or replace function public.ws_tool_found(p_tool uuid) returns void
language plpgsql security definer set search_path = public as $$
declare n text;
begin
  perform public.ws_need_owner();
  update public.ws_tool_missing set found_at = now() where tool_id = p_tool and found_at is null;
  select name into n from public.ws_tools where id = p_tool;
  perform public.ws_note('good', 'Tool back: ' || n);
end $$;


-- ---------- workshop screen (foreman) ----------
create or replace function public.ws_tool_list() returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  if not (public.ws_is_station() or public.is_admin()) then raise exception 'Not allowed'; end if;
  return jsonb_build_object(
    'done_today', (select done_at from public.ws_tool_checks where day = public.ws_today()),
    'tools', coalesce((select jsonb_agg(jsonb_build_object(
        'id', t.id, 'name', t.name, 'worker', w.name,
        'missing_since', (select min(since) from public.ws_tool_missing m where m.tool_id = t.id and m.found_at is null))
        order by w.name nulls last, t.name)
      from public.ws_tools t left join public.ws_workers w on w.id = t.usual_worker where t.active), '[]'::jsonb));
end $$;

-- p_list = the tools NOT on the rack tonight (a list of tool ids)
drop function if exists public.ws_tool_check(uuid[]);
create or replace function public.ws_tool_check(p_list jsonb) returns int
language plpgsql security definer set search_path = public as $$
declare t record; n int := 0; names text := ''; p_missing uuid[];
begin
  if not (public.ws_is_station() or public.is_admin()) then raise exception 'Not allowed'; end if;
  p_missing := array(select jsonb_array_elements_text(coalesce(p_list, '[]'::jsonb))::uuid);
  -- tools that were missing and are back now
  for t in select distinct m.tool_id, tl.name from public.ws_tool_missing m join public.ws_tools tl on tl.id = m.tool_id
            where m.found_at is null and not (m.tool_id = any(p_missing)) loop
    update public.ws_tool_missing set found_at = now() where tool_id = t.tool_id and found_at is null;
    perform public.ws_note('good', 'Tool back: ' || t.name);
  end loop;
  -- newly missing tonight
  for t in select tl.id, tl.name, tl.usual_worker, w.name wname from public.ws_tools tl left join public.ws_workers w on w.id = tl.usual_worker
            where tl.id = any(p_missing) and tl.active loop
    n := n + 1;
    if not exists (select 1 from public.ws_tool_missing where tool_id = t.id and found_at is null) then
      insert into public.ws_tool_missing (tool_id, worker_id, since) values (t.id, t.usual_worker, public.ws_today());
    end if;
    names := names || case when names = '' then '' else ', ' end || t.name || coalesce(' (normally ' || t.wname || ')', '');
  end loop;
  insert into public.ws_tool_checks (day, done_at, missing) values (public.ws_today(), now(), n)
  on conflict (day) do update set done_at = now(), missing = excluded.missing;
  if n = 0 then
    perform public.ws_note('good', 'Tool check done: all tools are back');
  else
    perform public.ws_note('alert', 'Tool check: ' || n || ' missing. ' || names);
  end if;
  return n;
end $$;

revoke all on function public.ws_today() from public, anon;
revoke all on function public.ws_save_tool(jsonb), public.ws_tool_found(uuid), public.ws_tool_list(), public.ws_tool_check(jsonb) from public, anon;
grant execute on function public.ws_save_tool(jsonb)    to authenticated;
grant execute on function public.ws_tool_found(uuid)    to authenticated;
grant execute on function public.ws_tool_list()         to authenticated;
grant execute on function public.ws_tool_check(jsonb)   to authenticated;
