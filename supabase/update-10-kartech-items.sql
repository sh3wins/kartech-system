-- =====================================================================
--  KARTECH UPDATE 10: Kartech's real tools and materials
--  Paste ALL of this into Supabase → SQL Editor → New query → Run.
--  Safe to run again (it never adds the same thing twice).
--
--  TOOLS (go out in the morning, come back in the evening):
--    Grinder 1–4 · Welding machine 1–4 · Electric drill 1–2 · Battery drill 1–2
--    Screwdriver 1–2
--  MATERIALS (used up, the app counts how much each day):
--    Welding rods · Cutting disks · Grinding disks · Drill bits (pieces)
--    Screws (boxes) · Paint · Thinner (litres)
--
--  Nobody knows how much is in the store yet, so materials start as
--  "not counted": the foreman can give them out and the app adds up what
--  is used. When the owner does a first count (Stock → Count), the app
--  starts keeping the store amount and low-stock warnings too.
-- =====================================================================

alter table public.ws_materials add column if not exists counted boolean not null default true;

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
  if k = 'out' and m.counted and q > m.in_store then raise exception 'Only % % in the store', public.ws_fmt(m.in_store), m.unit; end if;
  if k = 'out' and v_worker is null then raise exception 'Pick who is taking it'; end if;

  insert into public.ws_moves (material_id, kind, qty, order_id, worker_id, note)
  values (m.id, k, case when k = 'out' then -q else q end, v_order, v_worker,
          nullif(trim(concat_ws(' · ', nullif(left(trim(coalesce(p->>'note','')), 200), ''), case when p_by = 'foreman' then 'by manager' end)), ''));
  update public.ws_materials set in_store = in_store + case when k = 'out' then -q else q end where id = m.id;

  select * into o from public.ws_orders where id = v_order;
  select name into wname from public.ws_workers where id = v_worker;
  perform public.ws_note(case when k = 'out' then 'info' else 'good' end,
    case k when 'in' then 'Received ' || public.ws_fmt(q) || ' ' || m.unit || ' of ' || m.name
           when 'out' then case when p_by = 'foreman' then 'Manager gave ' else 'Gave ' end || public.ws_fmt(q) || ' ' || m.unit || ' of ' || m.name || ' to ' || coalesce(wname, 'a worker') || coalesce(' for ' || o.ref, '')
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

create or replace function public.ws_stock_count(p_material uuid, p_counted numeric) returns numeric
language plpgsql security definer set search_path = public as $$
declare m public.ws_materials; diff numeric;
begin
  perform public.ws_need_owner();
  if p_counted is null or p_counted < 0 then raise exception 'Enter what you counted'; end if;
  select * into m from public.ws_materials where id = p_material for update;
  if m.id is null then raise exception 'Material not found'; end if;
  if not m.counted then
    -- first count ever: this is the starting amount
    insert into public.ws_moves (material_id, kind, qty, note) values (m.id, 'count', 0, 'First count: ' || public.ws_fmt(p_counted));
    update public.ws_materials set in_store = p_counted, counted = true where id = m.id;
    perform public.ws_note('good', 'First stock count: ' || public.ws_fmt(p_counted) || ' ' || m.unit || ' of ' || m.name || ' in the store');
    perform public.ws_check_low(m.id);
    return 0;
  end if;
  diff := p_counted - m.in_store;
  insert into public.ws_moves (material_id, kind, qty, note) values (m.id, 'count', diff, 'Counted ' || public.ws_fmt(p_counted) || ', system said ' || public.ws_fmt(m.in_store));
  update public.ws_materials set in_store = p_counted where id = m.id;
  if diff < 0 then
    perform public.ws_note('alert', 'Stock count: ' || public.ws_fmt(-diff) || ' ' || m.unit || ' of ' || m.name || ' is MISSING from the store');
  elsif diff > 0 then
    perform public.ws_note('info', 'Stock count: ' || public.ws_fmt(diff) || ' ' || m.unit || ' more ' || m.name || ' than expected');
  else
    perform public.ws_note('good', 'Stock count: ' || m.name || ' is correct');
  end if;
  perform public.ws_check_low(m.id);
  return diff;
end $$;

create or replace function public.ws_check_low(p_mat uuid) returns void
language plpgsql security definer set search_path = public as $$
declare m public.ws_materials;
begin
  select * into m from public.ws_materials where id = p_mat;
  if m.counted and m.low_at > 0 and m.in_store <= m.low_at then
    perform public.ws_note('alert', 'Low stock: only ' || public.ws_fmt(m.in_store) || ' ' || m.unit || ' of ' || m.name || ' left in the store');
  end if;
end $$;

create or replace function public.ws_foreman_open(p_pin text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare today timestamptz := (public.ws_today()::timestamp at time zone 'Africa/Nairobi'); st text;
begin
  st := public.ws_foreman_check(p_pin);
  if st <> 'ok' then return jsonb_build_object('error', st); end if;
  return jsonb_build_object(
    'workers', coalesce((select jsonb_agg(jsonb_build_object('id', w.id, 'name', w.name, 'stage', w.stage,
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

-- ---------- the tools ----------
insert into public.ws_tools (name, stages)
select t.name, array(select x from unnest(t.stages) x where exists (select 1 from public.ws_steps s where s.id = x))
  from (values
    ('Grinder 1', '{cut,grind}'::text[]), ('Grinder 2', '{cut,grind}'), ('Grinder 3', '{cut,grind}'), ('Grinder 4', '{cut,grind}'),
    ('Welding machine 1', '{weld}'), ('Welding machine 2', '{weld}'), ('Welding machine 3', '{weld}'), ('Welding machine 4', '{weld}'),
    ('Electric drill 1', '{fold,weld,foam}'), ('Electric drill 2', '{fold,weld,foam}'),
    ('Battery drill 1', '{fold,weld,foam}'),  ('Battery drill 2', '{fold,weld,foam}'),
    ('Screwdriver 1', '{foam,finish}'), ('Screwdriver 2', '{foam,finish}')
  ) t(name, stages)
 where not exists (select 1 from public.ws_tools x where lower(x.name) = lower(t.name));

-- ---------- the materials (not counted yet) ----------
insert into public.ws_materials (name, unit, stages, counted)
select m.name, m.unit, array(select x from unnest(m.stages) x where exists (select 1 from public.ws_steps s where s.id = x)), false
  from (values
    ('Welding rods',   'pcs',    '{weld}'::text[]),
    ('Cutting disks',  'pcs',    '{cut}'),
    ('Grinding disks', 'pcs',    '{grind}'),
    ('Drill bits',     'pcs',    '{fold,weld,foam}'),
    ('Screws',         'boxes',  '{foam,finish}'),
    ('Paint',          'litres', '{paint}'),
    ('Thinner',        'litres', '{paint}')
  ) m(name, unit, stages)
 where not exists (select 1 from public.ws_materials x where lower(x.name) = lower(m.name));

grant select (counted) on public.ws_materials to authenticated;
grant execute on function public.ws_stock_count(uuid, numeric) to authenticated;
grant execute on function public.ws_foreman_open(text)         to authenticated;
