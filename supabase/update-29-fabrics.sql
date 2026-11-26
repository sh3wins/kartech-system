-- =====================================================================
--  UPDATE 29: fabrics and colours
--  One list of fabrics (e.g. "Leatherette · Red") with metres in the store.
--  • Stock → Fabrics: the owner adds fabrics and keeps the metres up to date.
--  • Orders: the owner (or manager) picks the fabric and colour, and the
--    worker sees it on the job card.
--  • Shop products: the owner ticks which fabric colours customers can choose.
--  Paste ALL of this into Supabase → SQL Editor → New query → Run.
--  Safe to run again.
-- =====================================================================
create table if not exists public.kt_fabrics (
  id         uuid primary key default gen_random_uuid(),
  kind       text not null,                       -- Leatherette, Velvet, Woven fabric…
  colour     text not null,                       -- Red, Black, Tan…
  hex        text not null default '#888888' check (hex ~ '^#[0-9A-Fa-f]{6}$'),
  metres     numeric not null default 0 check (metres >= 0),
  low_at     numeric not null default 5 check (low_at >= 0),   -- warn when fewer metres than this
  active     boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create unique index if not exists kt_fabrics_name on public.kt_fabrics (lower(kind), lower(colour)) where active;
alter table public.kt_fabrics enable row level security;
drop policy if exists "fabrics visible to owner and workshop" on public.kt_fabrics;
create policy "fabrics visible to owner and workshop" on public.kt_fabrics for select to authenticated
  using (public.is_admin() or public.ws_is_station());
grant select on public.kt_fabrics to authenticated;
revoke insert, update, delete on public.kt_fabrics from anon, authenticated;

-- a starting list (only if empty): common Kartech fabrics, 0 metres. The owner edits it.
insert into public.kt_fabrics (kind, colour, hex)
select * from (values
  ('Leatherette','Black','#1F1F1F'), ('Leatherette','Brown','#5A3A28'), ('Leatherette','Tan','#B87A4B'),
  ('Leatherette','Red','#C0262D'), ('Leatherette','Cream','#EDE3CC'), ('Leatherette','Grey','#9A9C9A'),
  ('Woven fabric','Blue','#1F4FB5'), ('Woven fabric','Maroon','#7A1F2B'), ('Woven fabric','Beige','#C8B08A'),
  ('Velvet','Red','#9E1830'), ('Zebra print','Black & white','#3A3A3A')) v(kind, colour, hex)
where not exists (select 1 from public.kt_fabrics);

-- orders remember the fabric (a copy of the name, so renaming a fabric later doesn't change old orders)
alter table public.ws_orders add column if not exists fabric_id  uuid references public.kt_fabrics(id) on delete set null;
alter table public.ws_orders add column if not exists fabric     text;
alter table public.ws_orders add column if not exists fabric_hex text;

-- OWNER: add or change a fabric. p = {id?, kind, colour, hex, metres, low_at, active}
create or replace function public.kt_save_fabric(p jsonb) returns uuid
language plpgsql security definer set search_path = public as $$
declare v_id uuid := nullif(p->>'id', '')::uuid; k text := left(trim(coalesce(p->>'kind', '')), 60); c text := left(trim(coalesce(p->>'colour', '')), 60);
        h text := coalesce(nullif(trim(p->>'hex'), ''), '#888888');
begin
  perform public.ws_need_owner();
  if k = '' or c = '' then raise exception 'Give the fabric a type and a colour'; end if;
  if h !~ '^#[0-9A-Fa-f]{6}$' then h := '#888888'; end if;
  if exists (select 1 from public.kt_fabrics where active and lower(kind) = lower(k) and lower(colour) = lower(c) and id is distinct from v_id) then
    raise exception '% · % is already on the list', k, c; end if;
  if v_id is null then
    insert into public.kt_fabrics (kind, colour, hex, metres, low_at) values (k, c, h, greatest(coalesce((p->>'metres')::numeric, 0), 0), greatest(coalesce((p->>'low_at')::numeric, 5), 0)) returning id into v_id;
  else
    update public.kt_fabrics set kind = k, colour = c, hex = h,
      metres = case when p ? 'metres' then greatest((p->>'metres')::numeric, 0) else metres end,
      low_at = case when p ? 'low_at' then greatest((p->>'low_at')::numeric, 0) else low_at end,
      active = coalesce((p->>'active')::boolean, active), updated_at = now()
    where id = v_id;
  end if;
  return v_id;
end $$;

-- OWNER: metres used (negative) or bought (positive)
create or replace function public.kt_fabric_metres(p_id uuid, p_change numeric) returns numeric
language plpgsql security definer set search_path = public as $$
declare m numeric;
begin
  perform public.ws_need_owner();
  update public.kt_fabrics set metres = greatest(metres + p_change, 0), updated_at = now() where id = p_id returning metres into m;
  if m is null then raise exception 'Fabric not found'; end if;
  return m;
end $$;

-- set the fabric on an order (owner)
create or replace function public.kt_set_order_fabric(p_order uuid, p_fabric uuid) returns void
language plpgsql security definer set search_path = public as $$
declare f public.kt_fabrics;
begin
  perform public.ws_need_owner();
  select * into f from public.kt_fabrics where id = p_fabric;
  update public.ws_orders set fabric_id = f.id, fabric = case when f.id is null then null else f.kind || ' · ' || f.colour end,
         fabric_hex = f.hex where id = p_order;
end $$;

-- set the fabric on an order (manager, with the manager code)
create or replace function public.ws_foreman_set_fabric(p_pin text, p_order uuid, p_fabric uuid) returns void
language plpgsql security definer set search_path = public as $$
declare f public.kt_fabrics;
begin
  perform public.ws_foreman_ok(p_pin);
  select * into f from public.kt_fabrics where id = p_fabric;
  update public.ws_orders set fabric_id = f.id, fabric = case when f.id is null then null else f.kind || ' · ' || f.colour end,
         fabric_hex = f.hex where id = p_order and delivered_at is null;
end $$;

-- WORKER (signed in): the fabric for my current job
create or replace function public.ws_job_fabric(p_token uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare w public.ws_workers; r jsonb;
begin
  w := public.ws_me(p_token);
  select jsonb_build_object('name', o.fabric, 'hex', o.fabric_hex) into r
    from public.ws_tasks t join public.ws_orders o on o.id = t.order_id where t.id = w.task_id and o.fabric is not null;
  return r;
end $$;

revoke all on function public.kt_save_fabric(jsonb), public.kt_fabric_metres(uuid, numeric), public.kt_set_order_fabric(uuid, uuid),
  public.ws_foreman_set_fabric(text, uuid, uuid), public.ws_job_fabric(uuid) from public, anon;
grant execute on function public.kt_save_fabric(jsonb), public.kt_fabric_metres(uuid, numeric), public.kt_set_order_fabric(uuid, uuid),
  public.ws_foreman_set_fabric(text, uuid, uuid), public.ws_job_fabric(uuid) to authenticated;
