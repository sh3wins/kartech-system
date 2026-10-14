-- =====================================================================
--  KARTECH UPDATE 4: the foreman page on the workshop screen
--  Paste ALL of this into Supabase → SQL Editor → New query → Run.
--  Safe to run again. Run updates 1, 2 and 3 first.
--
--  • The foreman opens "Foreman" on the workshop screen with his 4-digit code.
--  • He taps a worker → ticks the tools they take (and ticks them back when returned)
--    and taps the materials they take (amount with big number buttons).
--  • Materials are linked by themselves to that worker and the job they are on.
--  • The evening tool check is also behind the foreman code, and shows who has what.
-- =====================================================================

-- which steps use a material (empty = all steps)
alter table public.ws_materials add column if not exists stages text[] not null default '{}';

create table if not exists public.ws_settings (key text primary key, value text, updated_at timestamptz not null default now());
alter table public.ws_settings enable row level security;
revoke all on public.ws_settings from anon, authenticated;

create table if not exists public.ws_tool_loans (
  id        bigserial primary key,
  tool_id   uuid not null references public.ws_tools(id) on delete cascade,
  worker_id uuid references public.ws_workers(id) on delete set null,
  out_at    timestamptz not null default now(),
  back_at   timestamptz
);
create index if not exists ws_tool_loans_open on public.ws_tool_loans (tool_id) where back_at is null;
alter table public.ws_tool_loans enable row level security;
drop policy if exists "owner reads loans" on public.ws_tool_loans;
create policy "owner reads loans" on public.ws_tool_loans for select to authenticated using (public.is_admin());
revoke all on public.ws_tool_loans from anon, authenticated;
grant select on public.ws_tool_loans to authenticated;


-- ---------- foreman code ----------
create or replace function public.ws_set_foreman_pin(p_pin text) returns void
language plpgsql security definer set search_path = public as $$
begin
  perform public.ws_need_owner();
  if coalesce(p_pin,'') !~ '^[0-9]{4}$' then raise exception 'The code must be exactly 4 numbers'; end if;
  insert into public.ws_settings (key, value) values ('foreman_pin', extensions.crypt(p_pin, extensions.gen_salt('bf')))
  on conflict (key) do update set value = excluded.value, updated_at = now();
  delete from public.ws_settings where key in ('foreman_fails','foreman_locked');
  perform public.ws_note('info', 'Foreman code changed');
end $$;

create or replace function public.ws_has_foreman_pin() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.ws_settings where key = 'foreman_pin');
$$;

-- checks the code; 5 wrong tries locks it for 5 minutes. Returns 'ok', 'wrong', 'locked' or 'nocode'
-- (does not raise, so wrong tries are remembered)
create or replace function public.ws_foreman_check(p_pin text) returns text
language plpgsql security definer set search_path = public as $$
declare h text; fails int; lk timestamptz;
begin
  if not (public.ws_is_station() or public.is_admin()) then raise exception 'This computer is not set up as the workshop screen'; end if;
  select value into h from public.ws_settings where key = 'foreman_pin';
  if h is null then return 'nocode'; end if;
  select value::timestamptz into lk from public.ws_settings where key = 'foreman_locked';
  if lk is not null and lk > now() then return 'locked'; end if;
  if h <> extensions.crypt(coalesce(p_pin,''), h) then
    select value::int + 1 into fails from public.ws_settings where key = 'foreman_fails';
    fails := coalesce(fails, 1);
    insert into public.ws_settings (key, value) values ('foreman_fails', fails::text) on conflict (key) do update set value = excluded.value;
    if fails >= 5 then
      insert into public.ws_settings (key, value) values ('foreman_locked', (now() + interval '5 minutes')::text) on conflict (key) do update set value = excluded.value;
      delete from public.ws_settings where key = 'foreman_fails';
      perform public.ws_note('alert', 'Someone typed a wrong foreman code 5 times on the workshop screen');
      return 'locked';
    end if;
    return 'wrong';
  end if;
  delete from public.ws_settings where key in ('foreman_fails','foreman_locked');
  return 'ok';
end $$;

create or replace function public.ws_foreman_ok(p_pin text) returns void
language plpgsql security definer set search_path = public as $$
declare st text := public.ws_foreman_check(p_pin);
begin
  if st = 'nocode' then raise exception 'The owner has not set a foreman code yet'; end if;
  if st = 'locked' then raise exception 'Too many wrong codes. Try again in a few minutes.'; end if;
  if st <> 'ok' then raise exception 'Wrong code'; end if;
end $$;


-- ---------- materials: one place that moves stock (owner or foreman) ----------
create or replace function public.ws_do_move(p jsonb, p_by text) returns void
language plpgsql security definer set search_path = public as $$
declare m public.ws_materials; k text := p->>'kind'; q numeric := (p->>'qty')::numeric;
        v_order uuid := nullif(p->>'order_id','')::uuid; v_worker uuid := nullif(p->>'worker_id','')::uuid;
        o public.ws_orders; wname text; given numeric; expected numeric;
begin
  if k not in ('in','out','back') then raise exception 'Unknown action'; end if;
  if q is null or q <= 0 then raise exception 'Enter how much'; end if;
  select * into m from public.ws_materials where id = (p->>'material_id')::uuid for update;
  if m.id is null then raise exception 'Material not found'; end if;
  if k = 'out' and q > m.in_store then raise exception 'Only % % in the store', public.ws_fmt(m.in_store), m.unit; end if;
  if k = 'out' and v_worker is null then raise exception 'Pick who is taking it'; end if;

  insert into public.ws_moves (material_id, kind, qty, order_id, worker_id, note)
  values (m.id, k, case when k = 'out' then -q else q end, v_order, v_worker,
          nullif(trim(concat_ws(' · ', nullif(left(trim(coalesce(p->>'note','')), 200), ''), case when p_by = 'foreman' then 'by foreman' end)), ''));
  update public.ws_materials set in_store = in_store + case when k = 'out' then -q else q end where id = m.id;

  select * into o from public.ws_orders where id = v_order;
  select name into wname from public.ws_workers where id = v_worker;
  perform public.ws_note(case when k = 'out' then 'info' else 'good' end,
    case k when 'in' then 'Received ' || public.ws_fmt(q) || ' ' || m.unit || ' of ' || m.name
           when 'out' then case when p_by = 'foreman' then 'Foreman gave ' else 'Gave ' end || public.ws_fmt(q) || ' ' || m.unit || ' of ' || m.name || ' to ' || coalesce(wname, 'a worker') || coalesce(' for ' || o.ref, '')
           else coalesce(wname, 'A worker') || ' returned ' || public.ws_fmt(q) || ' ' || m.unit || ' of ' || m.name end, v_order);

  if k = 'out' and o.id is not null then
    select -coalesce(sum(qty), 0) into given from public.ws_moves where order_id = o.id and material_id = m.id and kind in ('out','back');
    select s.per_piece * o.qty into expected from public.ws_usage_std s where s.product = public.ws_product_key(o.item) and s.material_id = m.id;
    if expected is not null and given > expected * 1.1 then
      perform public.ws_note('alert', o.ref || ' has been given ' || public.ws_fmt(given) || ' ' || m.unit || ' of ' || m.name
        || '. Normal for ' || o.qty || ' × ' || o.item || ' is ' || public.ws_fmt(expected) || ' ' || m.unit
        || ' (' || round(100 * (given - expected) / expected) || '% more)', o.id);
    end if;
  end if;
  perform public.ws_check_low(m.id);
end $$;

create or replace function public.ws_stock_move(p jsonb) returns void
language plpgsql security definer set search_path = public as $$
begin
  perform public.ws_need_owner();
  perform public.ws_do_move(p, 'owner');
end $$;

-- owner: add/edit a material, now with the steps that use it
create or replace function public.ws_save_material(p jsonb) returns void
language plpgsql security definer set search_path = public as $$
declare v_name text := left(trim(coalesce(p->>'name','')), 80); v_unit text := left(trim(coalesce(nullif(p->>'unit',''),'pcs')), 20);
        v_stages text[] := coalesce(array(select jsonb_array_elements_text(coalesce(p->'stages','[]'::jsonb))), '{}');
begin
  perform public.ws_need_owner();
  if length(v_name) = 0 then raise exception 'Add a name'; end if;
  if p->>'id' is null then
    insert into public.ws_materials (name, unit, low_at, stages) values (v_name, v_unit, greatest(coalesce((p->>'low_at')::numeric, 0), 0), v_stages);
    perform public.ws_note('info', 'New material added: ' || v_name);
  else
    update public.ws_materials set name = v_name, unit = v_unit, low_at = greatest(coalesce((p->>'low_at')::numeric, 0), 0), stages = v_stages
     where id = (p->>'id')::uuid;
  end if;
end $$;


-- ---------- foreman page ----------
create or replace function public.ws_foreman_open(p_pin text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare today timestamptz := (public.ws_today()::timestamp at time zone 'Africa/Nairobi'); st text;
begin
  st := public.ws_foreman_check(p_pin);
  if st <> 'ok' then return jsonb_build_object('error', st); end if;
  return jsonb_build_object(
    'workers', coalesce((select jsonb_agg(jsonb_build_object('id', w.id, 'name', w.name, 'stage', w.stage,
        'job', (select jsonb_build_object('order_id', o.id, 'ref', o.ref, 'item', o.item, 'qty', o.qty)
                  from public.ws_tasks t join public.ws_orders o on o.id = t.order_id where t.id = w.task_id),
        'today', coalesce((select jsonb_agg(jsonb_build_object('material_id', m.id, 'material', m.name, 'unit', m.unit, 'qty', x.q,
                    'last', (select -qty from public.ws_moves z where z.worker_id = w.id and z.material_id = m.id and z.kind = 'out' and z.at >= today order by z.id desc limit 1),
                    'times', x.n) order by m.name)
                  from (select material_id, -sum(qty) q, count(*) filter (where kind = 'out') n from public.ws_moves where worker_id = w.id and kind in ('out','back') and at >= today group by material_id) x
                  join public.ws_materials m on m.id = x.material_id where x.q > 0), '[]'::jsonb))
        order by w.stage, w.name) from public.ws_workers w where w.active), '[]'::jsonb),
    'tools', coalesce((select jsonb_agg(jsonb_build_object('id', t.id, 'name', t.name, 'usual', t.usual_worker,
        'with', l.worker_id, 'with_name', lw.name, 'since', l.out_at,
        'missing', exists (select 1 from public.ws_tool_missing mm where mm.tool_id = t.id and mm.found_at is null)) order by t.name)
        from public.ws_tools t
        left join lateral (select * from public.ws_tool_loans x where x.tool_id = t.id and x.back_at is null order by x.id desc limit 1) l on true
        left join public.ws_workers lw on lw.id = l.worker_id
       where t.active), '[]'::jsonb),
    'materials', coalesce((select jsonb_agg(jsonb_build_object('id', m.id, 'name', m.name, 'unit', m.unit, 'in_store', m.in_store, 'stages', m.stages) order by m.name)
        from public.ws_materials m where m.active), '[]'::jsonb),
    'done_today', (select done_at from public.ws_tool_checks where day = public.ws_today()));
end $$;

-- tap a tool on a worker's page: takes it, or returns it if they have it
create or replace function public.ws_foreman_tool(p_pin text, p_tool uuid, p_worker uuid) returns text
language plpgsql security definer set search_path = public as $$
declare l public.ws_tool_loans; tname text; wname text; oname text;
begin
  perform public.ws_foreman_ok(p_pin);
  select name into tname from public.ws_tools where id = p_tool and active;
  select name into wname from public.ws_workers where id = p_worker and active;
  if tname is null or wname is null then raise exception 'Not found'; end if;
  select * into l from public.ws_tool_loans where tool_id = p_tool and back_at is null order by id desc limit 1;
  if l.id is not null and l.worker_id = p_worker then
    update public.ws_tool_loans set back_at = now() where id = l.id;
    update public.ws_tool_missing set found_at = now() where tool_id = p_tool and found_at is null;
    return 'back';
  end if;
  if l.id is not null then
    update public.ws_tool_loans set back_at = now() where id = l.id;
    select name into oname from public.ws_workers where id = l.worker_id;
    perform public.ws_note('info', tname || ' moved from ' || coalesce(oname, 'someone') || ' to ' || wname);
  end if;
  insert into public.ws_tool_loans (tool_id, worker_id) values (p_tool, p_worker);
  return 'out';
end $$;

-- tap a material on a worker's page: linked to the job they are on
create or replace function public.ws_foreman_give(p_pin text, p_material uuid, p_worker uuid, p_qty numeric) returns void
language plpgsql security definer set search_path = public as $$
declare v_order uuid;
begin
  perform public.ws_foreman_ok(p_pin);
  select t.order_id into v_order from public.ws_workers w join public.ws_tasks t on t.id = w.task_id where w.id = p_worker;
  perform public.ws_do_move(jsonb_build_object('kind','out','qty',p_qty,'material_id',p_material,'worker_id',p_worker,'order_id',v_order), 'foreman');
end $$;

create or replace function public.ws_foreman_return(p_pin text, p_material uuid, p_worker uuid, p_qty numeric) returns void
language plpgsql security definer set search_path = public as $$
declare v_order uuid;
begin
  perform public.ws_foreman_ok(p_pin);
  select t.order_id into v_order from public.ws_workers w join public.ws_tasks t on t.id = w.task_id where w.id = p_worker;
  perform public.ws_do_move(jsonb_build_object('kind','back','qty',p_qty,'material_id',p_material,'worker_id',p_worker,'order_id',v_order), 'foreman');
end $$;

-- evening check, now behind the foreman code; knows who had each tool
drop function if exists public.ws_tool_check(uuid[]);
drop function if exists public.ws_tool_check(jsonb);
create or replace function public.ws_tool_check(p_pin text, p_list jsonb) returns int
language plpgsql security definer set search_path = public as $$
declare t record; n int := 0; names text := ''; p_missing uuid[];
begin
  perform public.ws_foreman_ok(p_pin);
  p_missing := array(select jsonb_array_elements_text(coalesce(p_list, '[]'::jsonb))::uuid);
  -- everything ticked as back: close loans, clear old "missing"
  for t in select tl.id, tl.name from public.ws_tools tl where tl.active and not (tl.id = any(p_missing)) loop
    update public.ws_tool_loans set back_at = now() where tool_id = t.id and back_at is null;
    if exists (select 1 from public.ws_tool_missing where tool_id = t.id and found_at is null) then
      update public.ws_tool_missing set found_at = now() where tool_id = t.id and found_at is null;
      perform public.ws_note('good', 'Tool back: ' || t.name);
    end if;
  end loop;
  -- missing tonight: blame whoever had it, otherwise who normally uses it
  for t in select tl.id, tl.name, coalesce(l.worker_id, tl.usual_worker) wid, w.name wname, l.worker_id is not null had
             from public.ws_tools tl
             left join lateral (select worker_id from public.ws_tool_loans x where x.tool_id = tl.id and x.back_at is null order by x.id desc limit 1) l on true
             left join public.ws_workers w on w.id = coalesce(l.worker_id, tl.usual_worker)
            where tl.id = any(p_missing) and tl.active loop
    n := n + 1;
    if not exists (select 1 from public.ws_tool_missing where tool_id = t.id and found_at is null) then
      insert into public.ws_tool_missing (tool_id, worker_id, since) values (t.id, t.wid, public.ws_today());
    end if;
    names := names || case when names = '' then '' else ', ' end || t.name
             || coalesce(case when t.had then ' (taken by ' else ' (normally ' end || t.wname || ')', '');
  end loop;
  insert into public.ws_tool_checks (day, done_at, missing) values (public.ws_today(), now(), n)
  on conflict (day) do update set done_at = now(), missing = excluded.missing;
  if n = 0 then perform public.ws_note('good', 'Tool check done: all tools are back');
  else perform public.ws_note('alert', 'Tool check: ' || n || ' missing. ' || names); end if;
  return n;
end $$;

-- the screen only needs to know if a check is due (no tool details without the code)
create or replace function public.ws_tool_list() returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  if not (public.ws_is_station() or public.is_admin()) then raise exception 'Not allowed'; end if;
  return jsonb_build_object(
    'done_today', (select done_at from public.ws_tool_checks where day = public.ws_today()),
    'has_tools', exists (select 1 from public.ws_tools where active),
    'has_code', public.ws_has_foreman_pin(),
    'tools', '[]'::jsonb);
end $$;

revoke all on function public.ws_foreman_ok(text), public.ws_foreman_check(text), public.ws_do_move(jsonb, text) from public, anon, authenticated;
revoke all on function public.ws_set_foreman_pin(text), public.ws_has_foreman_pin(), public.ws_foreman_open(text),
  public.ws_foreman_tool(text, uuid, uuid), public.ws_foreman_give(text, uuid, uuid, numeric), public.ws_foreman_return(text, uuid, uuid, numeric),
  public.ws_tool_check(text, jsonb), public.ws_stock_move(jsonb), public.ws_save_material(jsonb), public.ws_tool_list() from public, anon;
grant execute on function public.ws_set_foreman_pin(text)                        to authenticated;
grant execute on function public.ws_has_foreman_pin()                            to authenticated;
grant execute on function public.ws_foreman_open(text)                           to authenticated;
grant execute on function public.ws_foreman_tool(text, uuid, uuid)               to authenticated;
grant execute on function public.ws_foreman_give(text, uuid, uuid, numeric)      to authenticated;
grant execute on function public.ws_foreman_return(text, uuid, uuid, numeric)    to authenticated;
grant execute on function public.ws_tool_check(text, jsonb)                      to authenticated;
grant execute on function public.ws_stock_move(jsonb)                            to authenticated;
grant execute on function public.ws_save_material(jsonb)                         to authenticated;
grant execute on function public.ws_tool_list()                                  to authenticated;
