-- =====================================================================
--  KARTECH UPDATE 2: raw materials (store, giving out, theft checks)
--  Paste ALL of this into Supabase → SQL Editor → New query → Run.
--  Safe to run again. Run update-1 first.
--
--  How it works:
--   • Only the owner changes stock. Workers can never change it.
--   • Delivery arrives  → owner taps "Received"  → store goes up.
--   • Worker needs some → owner taps "Give out" (to a worker, for an order) → store goes down.
--   • Leftovers come back → "Returned" → store goes up.
--   • Every so often she counts the store → "Count" → anything missing is flagged.
--   • Each product can have a "normal amount" per piece (e.g. 1 bar stool = 2 m steel tube).
--     If an order is given more than normal, she gets an alert.
-- =====================================================================

create table if not exists public.ws_materials (
  id         uuid primary key default gen_random_uuid(),
  name       text not null,
  unit       text not null default 'pcs',
  in_store   numeric not null default 0,
  low_at     numeric not null default 0,
  active     boolean not null default true,
  created_at timestamptz not null default now()
);

create table if not exists public.ws_moves (
  id          bigserial primary key,
  at          timestamptz not null default now(),
  material_id uuid not null references public.ws_materials(id) on delete cascade,
  kind        text not null check (kind in ('in','out','back','count')),
  qty         numeric not null,            -- change to the store: + for in/back, - for out, +/- for count
  order_id    uuid references public.ws_orders(id) on delete set null,
  worker_id   uuid references public.ws_workers(id) on delete set null,
  note        text
);
create index if not exists ws_moves_order on public.ws_moves (order_id);
create index if not exists ws_moves_mat on public.ws_moves (material_id, at desc);

-- normal amount per piece of a product (product name matched without the colour in brackets)
create table if not exists public.ws_usage_std (
  product     text not null,
  material_id uuid not null references public.ws_materials(id) on delete cascade,
  per_piece   numeric not null check (per_piece > 0),
  primary key (product, material_id)
);

alter table public.ws_materials enable row level security;
alter table public.ws_moves     enable row level security;
alter table public.ws_usage_std enable row level security;
drop policy if exists "owner reads materials" on public.ws_materials;
drop policy if exists "owner reads moves"     on public.ws_moves;
drop policy if exists "owner reads std"       on public.ws_usage_std;
create policy "owner reads materials" on public.ws_materials for select to authenticated using (public.is_admin());
create policy "owner reads moves"     on public.ws_moves     for select to authenticated using (public.is_admin());
create policy "owner reads std"       on public.ws_usage_std for select to authenticated using (public.is_admin());
revoke all on public.ws_materials, public.ws_moves, public.ws_usage_std from anon, authenticated;
grant select on public.ws_materials, public.ws_moves, public.ws_usage_std to authenticated;


-- ---------- helpers ----------
create or replace function public.ws_product_key(p text) returns text
language sql immutable as $$ select lower(trim(regexp_replace(coalesce(p,''), '\s*\(.*\)\s*$', ''))); $$;

create or replace function public.ws_fmt(n numeric) returns text
language sql immutable as $$ select trim(trailing '.' from trim(trailing '0' from round(n, 2)::text)); $$;

-- after any stock change: warn when low
create or replace function public.ws_check_low(p_mat uuid) returns void
language plpgsql security definer set search_path = public as $$
declare m public.ws_materials;
begin
  select * into m from public.ws_materials where id = p_mat;
  if m.low_at > 0 and m.in_store <= m.low_at then
    perform public.ws_note('alert', 'Low stock: only ' || public.ws_fmt(m.in_store) || ' ' || m.unit || ' of ' || m.name || ' left in the store');
  end if;
end $$;


-- ---------- owner actions ----------
create or replace function public.ws_save_material(p jsonb) returns void
language plpgsql security definer set search_path = public as $$
declare v_name text := left(trim(coalesce(p->>'name','')), 80); v_unit text := left(trim(coalesce(nullif(p->>'unit',''),'pcs')), 20);
begin
  perform public.ws_need_owner();
  if length(v_name) = 0 then raise exception 'Add a name'; end if;
  if p->>'id' is null then
    insert into public.ws_materials (name, unit, low_at) values (v_name, v_unit, greatest(coalesce((p->>'low_at')::numeric, 0), 0));
    perform public.ws_note('info', 'New material added: ' || v_name);
  else
    update public.ws_materials set name = v_name, unit = v_unit, low_at = greatest(coalesce((p->>'low_at')::numeric, 0), 0)
     where id = (p->>'id')::uuid;
  end if;
end $$;

-- kind: 'in' (received), 'out' (give out), 'back' (returned)
create or replace function public.ws_stock_move(p jsonb) returns void
language plpgsql security definer set search_path = public as $$
declare m public.ws_materials; k text := p->>'kind'; q numeric := (p->>'qty')::numeric;
        v_order uuid := nullif(p->>'order_id','')::uuid; v_worker uuid := nullif(p->>'worker_id','')::uuid;
        o public.ws_orders; wname text; given numeric; expected numeric;
begin
  perform public.ws_need_owner();
  if k not in ('in','out','back') then raise exception 'Unknown action'; end if;
  if q is null or q <= 0 then raise exception 'Enter how much'; end if;
  select * into m from public.ws_materials where id = (p->>'material_id')::uuid for update;
  if m.id is null then raise exception 'Material not found'; end if;
  if k = 'out' and q > m.in_store then raise exception 'Only % % in the store', public.ws_fmt(m.in_store), m.unit; end if;
  if k = 'out' and v_worker is null then raise exception 'Pick who is taking it'; end if;

  insert into public.ws_moves (material_id, kind, qty, order_id, worker_id, note)
  values (m.id, k, case when k = 'out' then -q else q end, v_order, v_worker, nullif(left(trim(coalesce(p->>'note','')), 200), ''));
  update public.ws_materials set in_store = in_store + case when k = 'out' then -q else q end where id = m.id;

  select * into o from public.ws_orders where id = v_order;
  select name into wname from public.ws_workers where id = v_worker;
  perform public.ws_note(case when k = 'out' then 'info' else 'good' end,
    case k when 'in' then 'Received ' || public.ws_fmt(q) || ' ' || m.unit || ' of ' || m.name
           when 'out' then 'Gave ' || public.ws_fmt(q) || ' ' || m.unit || ' of ' || m.name || ' to ' || coalesce(wname, 'a worker') || coalesce(' for ' || o.ref, '')
           else coalesce(wname, 'A worker') || ' returned ' || public.ws_fmt(q) || ' ' || m.unit || ' of ' || m.name end, v_order);

  -- more than normal for this order?
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

-- she counts what is really in the store
create or replace function public.ws_stock_count(p_material uuid, p_counted numeric) returns numeric
language plpgsql security definer set search_path = public as $$
declare m public.ws_materials; diff numeric;
begin
  perform public.ws_need_owner();
  if p_counted is null or p_counted < 0 then raise exception 'Enter what you counted'; end if;
  select * into m from public.ws_materials where id = p_material for update;
  if m.id is null then raise exception 'Material not found'; end if;
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

-- normal amount per piece; per_piece 0 or empty removes it
create or replace function public.ws_save_std(p_product text, p_material uuid, p_per_piece numeric) returns void
language plpgsql security definer set search_path = public as $$
begin
  perform public.ws_need_owner();
  if public.ws_product_key(p_product) = '' then raise exception 'Add the product name'; end if;
  if coalesce(p_per_piece, 0) <= 0 then
    delete from public.ws_usage_std where product = public.ws_product_key(p_product) and material_id = p_material;
  else
    insert into public.ws_usage_std (product, material_id, per_piece) values (public.ws_product_key(p_product), p_material, p_per_piece)
    on conflict (product, material_id) do update set per_piece = excluded.per_piece;
  end if;
end $$;


-- ---------- workshop screen: what was given to me for this job (read only) ----------
create or replace function public.ws_my_materials(p_token uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare w public.ws_workers; t public.ws_tasks;
begin
  w := public.ws_me(p_token);
  select * into t from public.ws_tasks where id = w.task_id;
  if t.id is null then return '[]'::jsonb; end if;
  return coalesce((select jsonb_agg(jsonb_build_object('name', m.name, 'unit', m.unit, 'qty', x.q) order by m.name)
    from (select material_id, -sum(qty) q from public.ws_moves where order_id = t.order_id and worker_id = w.id and kind in ('out','back') group by material_id) x
    join public.ws_materials m on m.id = x.material_id where x.q > 0), '[]'::jsonb);
end $$;


revoke all on function public.ws_product_key(text), public.ws_fmt(numeric) from public, anon;
revoke all on function public.ws_check_low(uuid) from public, anon, authenticated;
revoke all on function public.ws_save_material(jsonb), public.ws_stock_move(jsonb), public.ws_stock_count(uuid, numeric),
                       public.ws_save_std(text, uuid, numeric), public.ws_my_materials(uuid) from public, anon;
grant execute on function public.ws_save_material(jsonb)                to authenticated;
grant execute on function public.ws_stock_move(jsonb)                   to authenticated;
grant execute on function public.ws_stock_count(uuid, numeric)          to authenticated;
grant execute on function public.ws_save_std(text, uuid, numeric)       to authenticated;
grant execute on function public.ws_my_materials(uuid)                  to authenticated;
