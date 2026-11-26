-- =====================================================================
--  UPDATE 31: several items in one order
--  • One order (one order number) can hold several lines, each with its
--    own item, quantity and fabric. e.g. 10 bar stools in red
--    leatherette + 6 bar stools in black.
--  • The lines live inside the order, so the Bin keeps and brings them
--    back with the order.
--  • The order's "What" and "How many" become a summary of the lines,
--    so every screen that shows an order keeps working.
--  • The worker's job card lists every line.
--  Needs update 29 (fabrics) and update 30 (fabric photos) first.
--  Paste ALL of this into Supabase → SQL Editor → New query → Run.
--  Safe to run again.
-- =====================================================================
alter table public.ws_orders add column if not exists lines jsonb;

-- tidy the lines someone typed: [{ item, qty, fabric_id }] → checked lines with fabric names
create or replace function public.kt_clean_lines(p jsonb) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare it jsonb; out jsonb := '[]'::jsonb; nm text; q int; f public.kt_fabrics;
begin
  if p is null or jsonb_typeof(p) <> 'array' then raise exception 'No items given'; end if;
  if jsonb_array_length(p) > 30 then raise exception 'At most 30 items in one order'; end if;
  for it in select * from jsonb_array_elements(p) loop
    nm := left(trim(coalesce(it->>'item', '')), 120);
    q  := coalesce(nullif(trim(coalesce(it->>'qty', '')), '')::int, 0);
    if nm = '' then raise exception 'Each item needs a name'; end if;
    if q < 1 or q > 100000 then raise exception 'How many for "%" must be 1 or more', nm; end if;
    f := null;
    if nullif(it->>'fabric_id', '') is not null then
      select * into f from public.kt_fabrics where id = (it->>'fabric_id')::uuid;
    end if;
    out := out || jsonb_build_array(jsonb_build_object('item', nm, 'qty', q,
      'fabric_id', f.id, 'fabric', case when f.id is null then null else f.kind || ' · ' || f.colour end, 'hex', f.hex));
  end loop;
  if jsonb_array_length(out) = 0 then raise exception 'No items given'; end if;
  return out;
end $$;

-- put the lines on an order and update its summary ("What", "How many", fabric)
create or replace function public.kt_apply_lines(p_order uuid, p_lines jsonb) returns void
language plpgsql security definer set search_path = public as $$
declare l jsonb := public.kt_clean_lines(p_lines); n int := jsonb_array_length(l); names text; total int;
begin
  select sum((x->>'qty')::int) into total from jsonb_array_elements(l) x;
  select string_agg(nm, ' + ' order by first) into names
    from (select x->>'item' nm, min(i) first from jsonb_array_elements(l) with ordinality t(x, i) group by 1) g;
  if n = 1 then
    update public.ws_orders set lines = null, item = l->0->>'item', qty = total,
           fabric_id = (l->0->>'fabric_id')::uuid, fabric = l->0->>'fabric', fabric_hex = l->0->>'hex'
     where id = p_order;
  else
    update public.ws_orders set lines = l, item = left(names, 120), qty = total,
           fabric_id = null, fabric = null, fabric_hex = null
     where id = p_order;
  end if;
  if not found then raise exception 'Order not found'; end if;
end $$;

-- OWNER: set the items of an order
create or replace function public.kt_set_order_lines(p_order uuid, p_lines jsonb) returns void
language plpgsql security definer set search_path = public as $$
begin
  perform public.ws_need_owner();
  perform public.kt_apply_lines(p_order, p_lines);
end $$;

-- MANAGER (with the manager code): set the items of an order that isn't delivered yet
create or replace function public.ws_foreman_set_lines(p_pin text, p_order uuid, p_lines jsonb) returns void
language plpgsql security definer set search_path = public as $$
begin
  perform public.ws_foreman_ok(p_pin);
  if not exists (select 1 from public.ws_orders where id = p_order and delivered_at is null) then raise exception 'Order not found'; end if;
  perform public.kt_apply_lines(p_order, p_lines);
end $$;

-- WORKER (signed in): the fabric(s) and items for my current job, with photos
create or replace function public.ws_job_fabric(p_token uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare w public.ws_workers; o public.ws_orders; r jsonb;
begin
  w := public.ws_me(p_token);
  select o2.* into o from public.ws_tasks t join public.ws_orders o2 on o2.id = t.order_id where t.id = w.task_id;
  if o.id is null then return null; end if;
  if o.lines is not null then
    return jsonb_build_object('lines', (select jsonb_agg(jsonb_build_object('item', x->>'item', 'qty', (x->>'qty')::int,
              'fabric', x->>'fabric', 'hex', x->>'hex', 'photo', f.photo) order by i)
         from jsonb_array_elements(o.lines) with ordinality t(x, i)
         left join public.kt_fabrics f on f.id = nullif(x->>'fabric_id', '')::uuid));
  end if;
  if o.fabric is null then return null; end if;
  select jsonb_build_object('name', o.fabric, 'hex', o.fabric_hex, 'photo', f.photo) into r
    from (select 1) one left join public.kt_fabrics f on f.id = o.fabric_id;
  return r;
end $$;

revoke all on function public.kt_clean_lines(jsonb), public.kt_apply_lines(uuid, jsonb) from public, anon, authenticated;
revoke all on function public.kt_set_order_lines(uuid, jsonb), public.ws_foreman_set_lines(text, uuid, jsonb), public.ws_job_fabric(uuid) from public, anon;
grant execute on function public.kt_set_order_lines(uuid, jsonb), public.ws_foreman_set_lines(text, uuid, jsonb), public.ws_job_fabric(uuid) to authenticated;
